"""Pipeline completo: plans.csv + LabelMe JSON → máscaras → tiles → validación → splits.

Se detiene ante el primer tipo de error y NO produce splits si la validación
falla (regla: no entrenar con datos sin validar). Reconstruye el dataset desde
cero en cada ejecución para que no queden tiles obsoletos.

Planos omitidos (con aviso, no error): sin JSON de anotación todavía, o con la
bandera LabelMe ``needs_review`` activa (salvo ``--allow-needs-review``).

Uso (Windows):
    python -m tools.build_dataset --registry .\\work\\plans.csv --annotations .\\annotations ^
        --work .\\work --output .\\dataset --overwrite
"""
from __future__ import annotations

import argparse
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .common import (
    DATASET_DIRS, TOOL_VERSION, DatasetError, load_class_schema, normalize_plan_info,
    read_registry, resolve_relative, write_json,
)
from .labelme_to_mask import convert_labelme, write_mask
from .make_dataset_tiles import DEFAULT_OVERLAP, DEFAULT_TILE, tile_plan
from .make_splits import make_splits
from .validate_dataset import validate_dataset_root


def _prepare_output(output: Path, overwrite: bool) -> None:
    existing = [output / d for d in DATASET_DIRS if (output / d).exists()]
    if existing:
        if not overwrite:
            raise DatasetError(f"{output} ya contiene un dataset; usar --overwrite para regenerarlo")
        for d in existing:
            shutil.rmtree(d)
    output.mkdir(parents=True, exist_ok=True)


def build_dataset(registry: Path, annotations: Path, work: Path, output: Path, *,
                  tile: int = DEFAULT_TILE, overlap: int = DEFAULT_OVERLAP,
                  min_foreground_ratio: float = 0.0, overlap_policy: str = "priority",
                  line_width: int | None = None, point_radius: int | None = None,
                  train: float = 0.70, validation: float = 0.15, test: float = 0.15,
                  group_by: str = "project_id", seed: int = 42, overwrite: bool = False,
                  allow_needs_review: bool = False, classes: str | None = None) -> dict[str, Any]:
    schema = load_class_schema(classes)
    rows, _ = read_registry(registry)
    if not rows:
        raise DatasetError(f"{registry} no contiene planos")

    # 1. Registro
    errors, seen = [], set()
    plans = []
    for row in rows:
        try:
            info = normalize_plan_info(row)
            if info["source_plan_id"] in seen:
                raise DatasetError(f"source_plan_id duplicado {info['source_plan_id']}")
            seen.add(info["source_plan_id"])
            image = resolve_relative(registry.parent, row["image"])
            if not image.is_file():
                raise DatasetError(f"{info['source_plan_id']}: no existe la imagen {image}")
            ann = resolve_relative(registry.parent, row["annotation"]) if row.get("annotation") \
                else annotations / f"{info['source_plan_id']}.json"
            plans.append((row, info, image, ann))
        except DatasetError as exc:
            errors.append(str(exc))
    if errors:
        raise DatasetError("Registro inválido:\n  " + "\n  ".join(errors))

    # 2. Máscaras
    masks_dir = work / "masks"
    masks_dir.mkdir(parents=True, exist_ok=True)
    included, pending, review = [], [], []
    for row, info, image, ann in plans:
        pid = info["source_plan_id"]
        if not ann.is_file():
            pending.append(pid)
            continue
        try:
            mask, report = convert_labelme(ann, image_path=image, schema=schema,
                                           overlap_policy=overlap_policy, line_width=line_width,
                                           point_radius=point_radius)
            if row.get("image_sha256") and report["image_sha256"] != row["image_sha256"]:
                raise DatasetError("la imagen cambió desde su importación (sha256 distinto)")
            if report["needs_review"] and not allow_needs_review:
                review.append(pid)
                continue
            write_mask(mask, report, masks_dir, pid, overwrite=True)
            included.append((row, info, image))
            for w in report["warnings"]:
                print(f"   aviso {pid}: {w}")
        except (DatasetError, OSError) as exc:
            errors.append(f"{pid}: {exc}")
    if errors:
        raise DatasetError("Errores de conversión LabelMe:\n  " + "\n  ".join(errors))
    if not included:
        raise DatasetError("Ningún plano anotado y aprobado para incluir en el dataset")
    print(f"[1/4] Máscaras: {len(included)} planos; sin anotar: {len(pending)}; needs_review: {len(review)}")

    # 3. Tiles
    _prepare_output(output, overwrite)
    total_tiles = 0
    for row, info, image in included:
        man = tile_plan(image, masks_dir / f"{info['source_plan_id']}.png", output, row, tile=tile,
                        overlap=overlap, min_foreground_ratio=min_foreground_ratio, schema=schema,
                        expected_image_sha256=row.get("image_sha256") or None)
        total_tiles += len(man["tiles"])
    print(f"[2/4] Tiles: {total_tiles}")

    # 4. Validación previa a splits
    pre = validate_dataset_root(output, with_splits=False, schema=schema)
    if not pre.ok:
        write_json(output / "validation_report.json", pre.to_dict())
        pre.print_summary()
        raise DatasetError("La validación falló; no se generaron splits (ver validation_report.json)")
    print(f"[3/4] Validación estructural OK ({len(pre.warnings)} advertencias)")

    # 5. Splits + validación final
    split_manifest = make_splits(output / "metadata", output / "splits", train=train,
                                 validation=validation, test=test, group_by=group_by, seed=seed)
    final = validate_dataset_root(output, with_splits=True, schema=schema)
    write_json(output / "validation_report.json", final.to_dict())
    if not final.ok:
        final.print_summary()
        raise DatasetError("La validación final (con splits) falló")
    print("[4/4] Splits: " + ", ".join(f"{s}={n}" for s, n in split_manifest["tiles_assigned"].items()))
    for w in split_manifest["warnings"]:
        print(f"ADVERTENCIA: {w}")

    manifest = {
        "tool": "build_dataset", "tool_version": TOOL_VERSION,
        "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "registry": str(registry), "class_names": list(schema.names),
        "params": {"tile": tile, "overlap": overlap, "min_foreground_ratio": min_foreground_ratio,
                   "overlap_policy": overlap_policy, "line_width": line_width,
                   "point_radius": point_radius, "group_by": group_by, "seed": seed,
                   "ratios": {"train": train, "validation": validation, "test": test}},
        "plans_included": [i["source_plan_id"] for _, i, _ in included],
        "plans_pending_annotation": pending, "plans_needs_review": review,
        "tiles": total_tiles, "validation_warnings": len(final.warnings),
        "splits": split_manifest["tiles_assigned"],
    }
    write_json(output / "dataset_manifest.json", manifest)
    return manifest


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Construye el dataset completo y validado.")
    ap.add_argument("--registry", required=True, help="plans.csv")
    ap.add_argument("--annotations", required=True, help="Carpeta con <source_plan_id>.json de LabelMe")
    ap.add_argument("--work", required=True, help="Carpeta de trabajo (máscaras de plano completo)")
    ap.add_argument("--output", required=True, help="Raíz del dataset final")
    ap.add_argument("--tile", type=int, default=DEFAULT_TILE)
    ap.add_argument("--overlap", type=int, default=DEFAULT_OVERLAP)
    ap.add_argument("--min-foreground-ratio", type=float, default=0.0)
    ap.add_argument("--overlap-policy", choices=["priority", "order"], default="priority")
    ap.add_argument("--line-width", type=int)
    ap.add_argument("--point-radius", type=int)
    ap.add_argument("--train", type=float, default=0.70)
    ap.add_argument("--validation", type=float, default=0.15)
    ap.add_argument("--test", type=float, default=0.15)
    ap.add_argument("--group-by", choices=["project_id", "source_plan_id"], default="project_id")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--allow-needs-review", action="store_true")
    ap.add_argument("--classes")
    ap.add_argument("--overwrite", action="store_true")
    args = ap.parse_args(argv)
    try:
        m = build_dataset(Path(args.registry), Path(args.annotations), Path(args.work), Path(args.output),
                          tile=args.tile, overlap=args.overlap,
                          min_foreground_ratio=args.min_foreground_ratio,
                          overlap_policy=args.overlap_policy, line_width=args.line_width,
                          point_radius=args.point_radius, train=args.train,
                          validation=args.validation, test=args.test, group_by=args.group_by,
                          seed=args.seed, overwrite=args.overwrite,
                          allow_needs_review=args.allow_needs_review, classes=args.classes)
    except DatasetError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(f"\nDATASET LISTO: {args.output} ({m['tiles']} tiles, {len(m['plans_included'])} planos)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
