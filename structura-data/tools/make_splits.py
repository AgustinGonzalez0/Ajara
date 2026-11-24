"""Divide el dataset en train/validation/test por grupo de origen, nunca por tile.

Grupo = ``project_id`` (por defecto) o ``source_plan_id``. Un grupo completo va a
un único split. Algoritmo determinista:

1. Se mezclan los grupos con ``--seed`` y se ordenan por nº de tiles
   (descendente, orden estable → la semilla solo desempata).
2. Cada grupo se asigna al split con mayor déficit absoluto respecto de su
   objetivo (``total_tiles * ratio``): heurística LPT, equilibra mejor que
   asignar en orden aleatorio cuando los grupos tienen tamaños dispares.
3. Si un split con ratio > 0 queda vacío y hay grupos suficientes, recibe el
   grupo más pequeño del split con mayor excedente.

Antes de dividir se verifica la coherencia de metadatos (un plano en varios
proyectos o la misma imagen con IDs distintos provocarían fuga) y después se
comprueba que ningún grupo, plano o proyecto aparezca en más de un split.

``split_manifest.json`` registra proporciones logradas y píxeles por clase en
cada split; se advierte si una clase existente falta en validation o test.

Uso (Windows):
    python -m tools.make_splits --metadata .\\dataset\\metadata --output .\\dataset\\splits ^
        --group-by project_id --train 0.70 --validation 0.15 --test 0.15 --seed 42
"""
from __future__ import annotations

import argparse
import random
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

from .common import (
    SPLIT_NAMES, TOOL_VERSION, DatasetError, consistency_errors, load_tile_metadata, write_json,
)


def assign_groups(group_sizes: dict[str, int], ratios: dict[str, float], seed: int) -> dict[str, list[str]]:
    keys = sorted(group_sizes)
    random.Random(seed).shuffle(keys)
    keys.sort(key=lambda g: -group_sizes[g])
    active = [s for s in SPLIT_NAMES if ratios[s] > 0]
    total = sum(group_sizes.values())
    targets = {s: total * ratios[s] for s in SPLIT_NAMES}
    totals = {s: 0 for s in SPLIT_NAMES}
    assigned: dict[str, list[str]] = {s: [] for s in SPLIT_NAMES}
    for g in keys:
        chosen = max(active, key=lambda s: (targets[s] - totals[s], -SPLIT_NAMES.index(s)))
        assigned[chosen].append(g)
        totals[chosen] += group_sizes[g]
    for s in active:
        if assigned[s]:
            continue
        donors = [d for d in active if len(assigned[d]) > 1]
        if not donors:
            break
        donor = max(donors, key=lambda d: (totals[d] - targets[d], -SPLIT_NAMES.index(d)))
        g = min(assigned[donor], key=lambda k: (group_sizes[k], k))
        assigned[donor].remove(g)
        assigned[s].append(g)
        totals[donor] -= group_sizes[g]
        totals[s] += group_sizes[g]
    return {s: sorted(v) for s, v in assigned.items()}


def make_splits(metadata_dir: str | Path, output_dir: str | Path, *, train: float = 0.70,
                validation: float = 0.15, test: float = 0.15, group_by: str = "project_id",
                seed: int = 42) -> dict[str, Any]:
    ratios = {"train": train, "validation": validation, "test": test}
    if any(v < 0 for v in ratios.values()) or abs(sum(ratios.values()) - 1.0) > 1e-6:
        raise DatasetError("Las proporciones deben ser >= 0 y sumar 1")
    if group_by not in ("project_id", "source_plan_id"):
        raise DatasetError(f"group_by inválido {group_by!r}")
    records = load_tile_metadata(metadata_dir)
    if not records:
        raise DatasetError(f"No hay metadatos en {metadata_dir}")
    problems = consistency_errors(records)
    if problems:
        raise DatasetError("Metadatos incoherentes; no se puede dividir sin fuga:\n  " + "\n  ".join(problems))

    warnings: list[str] = []
    groups: dict[str, list[str]] = defaultdict(list)
    for name, rec in records.items():
        tid = rec.get("tile_id", name)
        if tid != name:
            raise DatasetError(f"{name}.json: tile_id={tid!r} no coincide con el nombre de archivo")
        group = rec.get(group_by)
        if not group:
            raise DatasetError(f"{name}.json: falta {group_by}")
        groups[str(group)].append(tid)
    if group_by == "source_plan_id":
        plans_per_project: dict[str, set] = defaultdict(set)
        for rec in records.values():
            plans_per_project[rec["project_id"]].add(rec["source_plan_id"])
        shared = sorted(p for p, plans in plans_per_project.items() if len(plans) > 1)
        if shared:
            warnings.append(f"group_by=source_plan_id con proyectos de varios planos {shared[:5]}: "
                            "planos del mismo proyecto pueden quedar en splits distintos")

    active = [s for s in SPLIT_NAMES if ratios[s] > 0]
    if len(groups) < len(active):
        warnings.append(f"solo {len(groups)} grupos para {len(active)} splits: algunos quedarán vacíos")
    assignment = assign_groups({g: len(t) for g, t in groups.items()}, ratios, seed)

    splits = {s: sorted(t for g in assignment[s] for t in groups[g]) for s in SPLIT_NAMES}
    for field in ("source_plan_id", "project_id"):
        owner: dict[str, set] = defaultdict(set)
        for s, tids in splits.items():
            for tid in tids:
                owner[records[tid][field]].add(s)
        leaked = [k for k, v in owner.items() if len(v) > 1]
        if leaked and (field == "source_plan_id" or group_by == "project_id"):
            raise DatasetError(f"fuga interna: {field} en varios splits {leaked[:5]}")

    total_tiles = sum(len(v) for v in splits.values())
    num_classes = max(len(r.get("class_pixel_counts") or []) for r in records.values())
    class_pixels = {s: [0] * num_classes for s in SPLIT_NAMES}
    for s, tids in splits.items():
        for tid in tids:
            for i, c in enumerate(records[tid].get("class_pixel_counts") or []):
                class_pixels[s][i] += c
    present = [i for i in range(1, num_classes) if any(class_pixels[s][i] for s in SPLIT_NAMES)]
    for s in ("validation", "test"):
        if ratios[s] > 0 and splits[s]:
            absent = [i for i in present if class_pixels[s][i] == 0]
            if absent:
                warnings.append(f"{s} no contiene las clases {absent}: sus métricas no serán evaluables")

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    for s, tids in splits.items():
        (out / f"{s}.txt").write_text("".join(t + "\n" for t in tids), encoding="utf-8")
    manifest = {
        "tool": "make_splits", "tool_version": TOOL_VERSION, "group_by": group_by, "seed": seed,
        "ratios_requested": ratios,
        "ratios_achieved": {s: round(len(splits[s]) / total_tiles, 4) for s in SPLIT_NAMES},
        "tiles_assigned": {s: len(splits[s]) for s in SPLIT_NAMES},
        "groups_by_split": assignment,
        "plans_by_split": {s: sorted({records[t]["source_plan_id"] for t in splits[s]}) for s in SPLIT_NAMES},
        "class_pixels_by_split": class_pixels,
        "warnings": warnings,
    }
    write_json(out / "split_manifest.json", manifest)
    return manifest


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Divide por proyecto/plano, nunca por tile individual.")
    ap.add_argument("--metadata", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--train", type=float, default=0.70)
    ap.add_argument("--validation", type=float, default=0.15)
    ap.add_argument("--test", type=float, default=0.15)
    ap.add_argument("--group-by", choices=["project_id", "source_plan_id"], default="project_id")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args(argv)
    try:
        m = make_splits(args.metadata, args.output, train=args.train, validation=args.validation,
                        test=args.test, group_by=args.group_by, seed=args.seed)
    except DatasetError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print("Splits creados:")
    for s in SPLIT_NAMES:
        print(f"  {s}: {m['tiles_assigned'][s]} tiles ({m['ratios_achieved'][s]:.1%}) / "
              f"{len(m['groups_by_split'][s])} grupos")
    for w in m["warnings"]:
        print(f"ADVERTENCIA: {w}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
