"""Dataset de entrenamiento a partir de planos vectoriales abiertos (caché de vector_sources).

Planos vectoriales → render con estilo al azar + máscara exacta → tiles (mismo
``tile_plan`` que los planos anotados) → validación → splits por ``project_id``.

En Swiss Dwellings el ``project_id`` es el SITIO (``sd_site_<id>``): todas las plantas y
variantes de estilo de un mismo conjunto quedan en el mismo split, sin fuga.

Uso::

    python -m tools.build_vector_dataset --cache ../data/vector_cache/swiss \
        --output ../data/dataset_vector --limit 1500 --workers 8 --overwrite
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import sys
import time
from collections import Counter
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .common import DATASET_DIRS, TOOL_VERSION, DatasetError, load_class_schema, write_json, write_png
from .make_dataset_tiles import DEFAULT_OVERLAP, DEFAULT_TILE, tile_plan
from .make_splits import make_splits
from .render_vector_plans import DOOR_LABELS, RenderSkipped, render_plan
from .validate_dataset import validate_dataset_root
from .vector_sources import list_cache, load_cached_plan

UNAPPROVED_SOURCES = {"resplan"}  # licencia en conflicto (D-29): requiere --allow-source resplan


def _seed_for(seed: int, plan_id: str, variant: int) -> int:
    h = hashlib.sha256(f"{seed}:{plan_id}:{variant}".encode()).digest()
    return int.from_bytes(h[:8], "little")


def _render_and_tile(job: dict[str, Any]) -> dict[str, Any]:
    plan = load_cached_plan(job["cache_file"])
    out_id = f"{plan.plan_id}_v{job['variant']}"
    try:
        r = render_plan(plan, _seed_for(job["seed"], plan.plan_id, job["variant"]), door_label=job["door_label"],
                        max_side=job["max_side"])
    except RenderSkipped as e:
        return {"skipped": str(e), "plan_id": out_id}
    work = Path(job["work"])
    img_path, mask_path = work / "images" / f"{out_id}.png", work / "masks" / f"{out_id}.png"
    write_png(img_path, r.image)
    write_png(mask_path, r.mask)
    info = {"source_plan_id": out_id, "project_id": plan.project_id, "source_type": "rendered",
            "units": "m", "scale_verified": "true", "scale_px_per_unit": round(r.px_per_m, 4)}
    man = tile_plan(img_path, mask_path, job["output"], info, tile=job["tile"], overlap=job["overlap"],
                    overwrite=True, verify=False)
    if not job["keep_renders"]:
        img_path.unlink(missing_ok=True)
        mask_path.unlink(missing_ok=True)
    return {"plan_id": out_id, "vector_plan_id": plan.plan_id, "project_id": plan.project_id,
            "source": plan.source, "license": plan.license, "attribution": plan.attribution,
            "origin": plan.origin, "tiles": len(man["tiles"]), "px_per_m": r.px_per_m,
            "size": [int(r.mask.shape[1]), int(r.mask.shape[0])], "counts": r.counts,
            "style": {k: r.style[k] for k in ("wall", "door", "window", "column", "font", "room_text", "dimensions")},
            "class_pixels": man["class_pixel_counts"]}


def build_vector_dataset(caches: list[Path], output: Path, *, work: Path | None = None, limit: int = 0,
                         variants: int = 1, seed: int = 42, workers: int = 0, door_label: str = "vano",
                         tile: int = DEFAULT_TILE, overlap: int = DEFAULT_OVERLAP, max_side: int = 4096,
                         train: float = 0.70, validation: float = 0.15, test: float = 0.15,
                         allow_sources: set[str] | None = None, keep_renders: bool = False,
                         overwrite: bool = False) -> dict[str, Any]:
    if door_label not in DOOR_LABELS:
        raise DatasetError(f"--door-label debe ser uno de {DOOR_LABELS}")
    schema = load_class_schema()
    files = [f for c in caches for f in list_cache(c)]
    if not files:
        raise DatasetError(f"No hay planos en {', '.join(map(str, caches))}")
    allowed = allow_sources or set()
    blocked = [f for f in files if any(f.name.startswith(_prefix(s)) for s in UNAPPROVED_SOURCES - allowed)]
    if blocked:
        raise DatasetError(f"{len(blocked)} planos de fuentes sin aprobar ({', '.join(sorted(UNAPPROVED_SOURCES - allowed))}). "
                           "Ver docs/DATASETS.md (D-29) o usar --allow-source explícitamente.")
    if limit:
        files = files[:limit]

    existing = [output / d for d in DATASET_DIRS if (output / d).exists()]
    if existing:
        if not overwrite:
            raise DatasetError(f"{output} ya contiene un dataset; usar --overwrite")
        for d in existing:
            shutil.rmtree(d)
    work = work or output.parent / (output.name + "_renders")
    for sub in ("images", "masks"):
        (work / sub).mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)

    jobs = [{"cache_file": str(f), "variant": v, "seed": seed, "door_label": door_label, "work": str(work),
             "output": str(output), "tile": tile, "overlap": overlap, "max_side": max_side,
             "keep_renders": keep_renders} for f in files for v in range(variants)]
    t0 = time.perf_counter()
    results, skipped = [], []
    workers = workers or max(1, (os.cpu_count() or 2) - 2)
    if workers == 1:
        it = map(_render_and_tile, jobs)
        for i, r in enumerate(it, 1):
            (skipped if "skipped" in r else results).append(r)
    else:
        with ProcessPoolExecutor(max_workers=workers) as ex:
            futs = [ex.submit(_render_and_tile, j) for j in jobs]
            for i, fut in enumerate(as_completed(futs), 1):
                r = fut.result()
                (skipped if "skipped" in r else results).append(r)
                if i % 100 == 0:
                    print(f"  {i}/{len(jobs)} planos ({time.perf_counter() - t0:.0f} s)", flush=True)
    if not results:
        raise DatasetError("Ningún plano se pudo renderizar")
    total_tiles = sum(r["tiles"] for r in results)
    print(f"[1/3] Render + tiles: {len(results)} planos, {total_tiles} tiles, {len(skipped)} omitidos "
          f"({time.perf_counter() - t0:.0f} s)")

    # make_splits verifica la coherencia de los metadatos; la validación completa
    # (decodifica cada imagen y máscara) se hace una sola vez, con los splits.
    split_manifest = make_splits(output / "metadata", output / "splits", train=train, validation=validation,
                                 test=test, group_by="project_id", seed=seed)
    final = validate_dataset_root(output, with_splits=True, schema=schema)
    write_json(output / "validation_report.json", final.to_dict())
    if not final.ok:
        final.print_summary()
        raise DatasetError("La validación final (con splits) falló")
    print(f"[2/3] Validación OK · splits: " + ", ".join(f"{s}={n}" for s, n in split_manifest["tiles_assigned"].items()))

    sources = Counter(r["source"] for r in results)
    attributions = sorted({(r["source"], r["license"], r["attribution"]) for r in results})
    class_pixels = [sum(r["class_pixels"][i] for r in results) for i in range(schema.num_classes)]
    manifest = {
        "tool": "build_vector_dataset", "tool_version": TOOL_VERSION,
        "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "kind": "rendered_from_vector",
        "note": "Planos dibujados a partir de geometría vectorial real con estilos aleatorios. "
                "Mide generalización entre estilos y edificios, NO el desempeño con fotos de planos reales.",
        "door_label": door_label,
        "params": {"tile": tile, "overlap": overlap, "variants": variants, "seed": seed, "max_side": max_side,
                   "group_by": "project_id", "ratios": {"train": train, "validation": validation, "test": test}},
        "sources": dict(sources),
        "attribution": [{"source": s, "license": lic, "text": txt} for s, lic, txt in attributions],
        "plans": len(results), "plans_skipped": skipped, "tiles": total_tiles,
        "class_names": list(schema.names), "class_pixels": class_pixels,
        "class_fraction": [round(c / max(1, sum(class_pixels)), 6) for c in class_pixels],
        "splits": split_manifest["tiles_assigned"], "split_warnings": split_manifest["warnings"],
        "validation_warnings": len(final.warnings),
        "plans_detail": sorted(results, key=lambda r: r["plan_id"]),
    }
    write_json(output / "dataset_manifest.json", manifest)
    _write_attribution(output, attributions, sources)
    print(f"[3/3] Manifiesto y atribución en {output}")
    return manifest


def _prefix(source: str) -> str:
    return {"resplan": "rp_", "swiss_dwellings": "sd_"}.get(source, source)


def _write_attribution(output: Path, attributions: list[tuple[str, str, str]], sources: Counter) -> None:
    lines = ["# Atribución de los datos de este dataset", "",
             "Las imágenes son dibujos generados por STRUCTURA a partir de geometrías de terceros.", ""]
    for s, lic, txt in attributions:
        lines += [f"- **{s}** ({sources[s]} planos) — {lic}", f"  {txt}"]
    lines += ["", "Cambios: geometría alineada, re-escalada y dibujada con estilos aleatorios; "
              "máscaras rasterizadas desde los polígonos originales."]
    (output / "ATTRIBUTION.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Dataset desde planos vectoriales abiertos (render + tiles + splits).")
    ap.add_argument("--cache", action="append", required=True, help="Carpeta de caché (repetible)")
    ap.add_argument("--output", required=True)
    ap.add_argument("--work", help="Carpeta para los renders completos (por defecto <output>_renders)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--variants", type=int, default=1, help="Estilos distintos por plano")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--workers", type=int, default=0)
    ap.add_argument("--door-label", choices=DOOR_LABELS, default="vano",
                    help="Convención de puertas (PENDIENTE D-17; 'vano' por defecto)")
    ap.add_argument("--tile", type=int, default=DEFAULT_TILE)
    ap.add_argument("--overlap", type=int, default=DEFAULT_OVERLAP)
    ap.add_argument("--max-side", type=int, default=4096)
    ap.add_argument("--allow-source", action="append", default=[], help="Habilita una fuente sin aprobar (p. ej. resplan)")
    ap.add_argument("--keep-renders", action="store_true", help="Conserva los planos completos para revisión")
    ap.add_argument("--overwrite", action="store_true")
    a = ap.parse_args(argv)
    try:
        build_vector_dataset([Path(c) for c in a.cache], Path(a.output), work=Path(a.work) if a.work else None,
                             limit=a.limit, variants=a.variants, seed=a.seed, workers=a.workers,
                             door_label=a.door_label, tile=a.tile, overlap=a.overlap, max_side=a.max_side,
                             allow_sources=set(a.allow_source), keep_renders=a.keep_renders, overwrite=a.overwrite)
    except DatasetError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
