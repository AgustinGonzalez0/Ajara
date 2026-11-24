"""Genera tiles sincronizados de imagen y máscara con metadatos de procedencia.

Garantías:
* Imagen y máscara se recortan con las MISMAS coordenadas (x, y, ancho, alto).
* Relleno a la derecha/abajo: imagen blanca (255,255,255), máscara clase 0.
* Rejilla con paso ``tile - overlap``; el último tile de cada eje se alinea al
  borde (su solape real puede ser mayor que ``overlap``). Ningún píxel queda sin
  cubrir salvo tiles descartados explícitamente por ``--min-foreground-ratio``,
  que quedan registrados en ``plans/<id>.json``.
* Tras escribir, cada tile se relee y se compara byte a byte con el recorte.
* Re-ejecutar sobre un plano existente exige ``--overwrite`` y elimina antes
  sus tiles anteriores (no quedan tiles obsoletos mezclados).

Salida en ``--output``: images/, masks/, metadata/ (un JSON por tile) y
plans/ (un manifiesto por plano con la rejilla completa).

Uso (Windows), un plano:
    python -m tools.make_dataset_tiles --image .\\work\\raw\\plan_001.png --mask .\\work\\masks\\plan_001.png ^
        --output .\\dataset --source-plan-id plan_001 --project-id proj_a --source-type digital
Batch desde el registro:
    python -m tools.make_dataset_tiles --registry .\\work\\plans.csv --masks-dir .\\work\\masks --output .\\dataset
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

import cv2
import numpy as np

from .common import (
    METADATA_SCHEMA_VERSION, SOURCE_TYPES, TOOL_VERSION, UNITS, ClassSchema, DatasetError,
    array_digest, class_pixel_counts, decode_image, load_class_schema, load_mask,
    load_plan_image, normalize_plan_info, read_json, read_registry, require_png,
    resolve_relative, sha256_bytes, sha256_file, write_json, write_png,
)

DEFAULT_TILE = 512
DEFAULT_OVERLAP = 64
PAD_IMAGE_VALUE = (255, 255, 255)
PAD_MASK_VALUE = 0


def tile_starts(length: int, tile: int, stride: int) -> list[int]:
    """Orígenes de tile a lo largo de un eje; cubre [0, length) por completo."""
    if length <= tile:
        return [0]
    values = list(range(0, length - tile + 1, stride))
    if values[-1] != length - tile:
        values.append(length - tile)
    return values


def tile_id_for(plan_id: str, x: int, y: int) -> str:
    return f"{plan_id}_x{x:06d}_y{y:06d}"


def _plan_tile_files(out: Path, plan_id: str) -> list[Path]:
    pattern = f"{plan_id}_x[0-9][0-9][0-9][0-9][0-9][0-9]_y[0-9][0-9][0-9][0-9][0-9][0-9]"
    files = []
    for sub, ext in (("images", ".png"), ("masks", ".png"), ("metadata", ".json")):
        files.extend((out / sub).glob(pattern + ext))
    manifest = out / "plans" / f"{plan_id}.json"
    if manifest.exists():
        files.append(manifest)
    return files


def remove_plan_tiles(out: Path, plan_id: str) -> int:
    files = _plan_tile_files(out, plan_id)
    for f in files:
        f.unlink()
    return len(files)


def tile_plan(image_path: str | Path, mask_path: str | Path, output_root: str | Path,
              plan: dict[str, Any], *, tile: int = DEFAULT_TILE, overlap: int = DEFAULT_OVERLAP,
              min_foreground_ratio: float = 0.0, overwrite: bool = False,
              schema: ClassSchema | None = None, verify: bool = True,
              expected_image_sha256: str | None = None) -> dict[str, Any]:
    """Genera los tiles de un plano. Devuelve el manifiesto del plano."""
    schema = schema or load_class_schema()
    if tile <= 0 or overlap < 0 or overlap >= tile:
        raise DatasetError("Se requiere tile > overlap >= 0")
    if not 0.0 <= min_foreground_ratio <= 1.0:
        raise DatasetError("min_foreground_ratio debe estar entre 0 y 1")
    info = normalize_plan_info(plan)
    plan_id = info["source_plan_id"]
    image_path = require_png(image_path, f"Imagen de {plan_id}")
    mask_path = require_png(mask_path, f"Máscara de {plan_id}")

    image_sha = sha256_file(image_path)
    if expected_image_sha256 and expected_image_sha256 != image_sha:
        raise DatasetError(f"{plan_id}: la imagen cambió desde su importación (sha256 distinto)")
    image = load_plan_image(image_path)
    mask = load_mask(mask_path)
    if image.shape[:2] != mask.shape:
        raise DatasetError(f"{plan_id}: imagen {image.shape[1]}x{image.shape[0]} y máscara "
                           f"{mask.shape[1]}x{mask.shape[0]} difieren")
    ids = set(np.unique(mask).tolist())
    if not ids <= schema.valid_ids:
        raise DatasetError(f"{plan_id}: IDs de máscara inválidos {sorted(ids - schema.valid_ids)}")

    out = Path(output_root)
    if _plan_tile_files(out, plan_id):
        if not overwrite:
            raise DatasetError(f"{plan_id}: ya existen tiles en {out}; usar --overwrite para regenerarlos")
        remove_plan_tiles(out, plan_id)
    for sub in ("images", "masks", "metadata", "plans"):
        (out / sub).mkdir(parents=True, exist_ok=True)

    h, w = mask.shape
    stride = tile - overlap
    xs, ys = tile_starts(w, tile, stride), tile_starts(h, tile, stride)
    mask_sha = sha256_file(mask_path)
    tiles, skipped = [], []

    for y in ys:
        for x in xs:
            ch, cw = min(tile, h - y), min(tile, w - x)
            im_crop = image[y:y + ch, x:x + cw]
            ma_crop = mask[y:y + ch, x:x + cw]
            fg_ratio = float(np.count_nonzero(ma_crop)) / float(ch * cw)
            if fg_ratio < min_foreground_ratio:
                skipped.append({"x": x, "y": y, "width": cw, "height": ch,
                                "foreground_ratio": round(fg_ratio, 6)})
                continue
            pad_b, pad_r = tile - ch, tile - cw
            im_tile = cv2.copyMakeBorder(im_crop, 0, pad_b, 0, pad_r, cv2.BORDER_CONSTANT, value=PAD_IMAGE_VALUE)
            ma_tile = cv2.copyMakeBorder(ma_crop, 0, pad_b, 0, pad_r, cv2.BORDER_CONSTANT, value=PAD_MASK_VALUE)
            tid = tile_id_for(plan_id, x, y)
            im_bytes = write_png(out / "images" / f"{tid}.png", im_tile)
            ma_bytes = write_png(out / "masks" / f"{tid}.png", ma_tile)
            if verify:
                back_im = decode_image(out / "images" / f"{tid}.png")
                back_ma = decode_image(out / "masks" / f"{tid}.png")
                if back_im is None or back_ma is None or not np.array_equal(back_im, im_tile) \
                        or not np.array_equal(back_ma, ma_tile):
                    raise DatasetError(f"{tid}: verificación post-escritura fallida")
            record = {
                "schema_version": METADATA_SCHEMA_VERSION, "tool_version": TOOL_VERSION,
                "tile_id": tid, **{k: info[k] for k in ("source_plan_id", "project_id", "source_type")},
                "source_image": image_path.name, "source_mask": mask_path.name,
                "source_image_sha256": image_sha, "source_mask_sha256": mask_sha,
                "source_width": w, "source_height": h,
                "x": x, "y": y, "width": cw, "height": ch,
                "tile_size": tile, "overlap": overlap, "pad_right": pad_r, "pad_bottom": pad_b,
                "foreground_ratio": round(fg_ratio, 6),
                "class_pixel_counts": class_pixel_counts(ma_tile, schema.num_classes),
                "image_sha256": sha256_bytes(im_bytes), "mask_sha256": sha256_bytes(ma_bytes),
                **{k: info[k] for k in ("units", "scale_verified", "scale_px_per_unit", "dpi", "dpi_source")},
            }
            write_json(out / "metadata" / f"{tid}.json", record)
            tiles.append(tid)

    manifest = {
        "schema_version": METADATA_SCHEMA_VERSION, "tool_version": TOOL_VERSION,
        **info, "source_image": image_path.name, "source_mask": mask_path.name,
        "source_image_sha256": image_sha, "source_mask_sha256": mask_sha,
        "source_image_digest": array_digest(image), "source_mask_digest": array_digest(mask),
        "source_width": w, "source_height": h, "tile_size": tile, "overlap": overlap,
        "stride": stride, "grid_x": xs, "grid_y": ys, "min_foreground_ratio": min_foreground_ratio,
        "class_names": list(schema.names),
        "class_pixel_counts": class_pixel_counts(mask, schema.num_classes),
        "tiles": tiles, "skipped": skipped,
    }
    write_json(out / "plans" / f"{plan_id}.json", manifest)
    return manifest


def tile_registry(registry: Path, masks_dir: Path, output: Path, *, plan_ids: set[str] | None = None,
                  allow_needs_review: bool = False, **kwargs) -> list[dict]:
    """Genera tiles para cada plano del registro que tenga máscara en ``masks_dir``.

    Omite los planos cuyo reporte de conversión (``<id>.report.json``) tenga la
    bandera LabelMe ``needs_review``, igual que ``build_dataset``.
    """
    rows, _ = read_registry(registry)
    results, pending, review = [], [], []
    for row in rows:
        pid = row["source_plan_id"]
        if plan_ids is not None and pid not in plan_ids:
            continue
        mask_path = masks_dir / f"{pid}.png"
        if not mask_path.exists():
            pending.append(pid)
            continue
        report_path = masks_dir / f"{pid}.report.json"
        if not allow_needs_review and report_path.exists() and read_json(report_path).get("needs_review"):
            review.append(pid)
            continue
        manifest = tile_plan(resolve_relative(registry.parent, row["image"]), mask_path, output, row,
                             expected_image_sha256=row.get("image_sha256") or None, **kwargs)
        print(f"OK {pid}: {len(manifest['tiles'])} tiles, {len(manifest['skipped'])} descartados")
        results.append(manifest)
    if pending:
        print(f"Sin máscara (omitidos): {', '.join(pending)}")
    if review:
        print(f"Con bandera needs_review (omitidos): {', '.join(review)}")
    return results


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Genera tiles sincronizados de imagen y máscara.")
    ap.add_argument("--output", required=True, help="Raíz del dataset (images/ masks/ metadata/ plans/)")
    single = ap.add_argument_group("modo un plano")
    single.add_argument("--image")
    single.add_argument("--mask")
    single.add_argument("--source-plan-id")
    single.add_argument("--project-id")
    single.add_argument("--source-type", choices=SOURCE_TYPES, default="unknown")
    single.add_argument("--units", choices=UNITS)
    single.add_argument("--scale-verified", choices=["true", "false"])
    single.add_argument("--scale-px-per-unit", type=float)
    single.add_argument("--dpi", type=float)
    single.add_argument("--metadata", help="JSON opcional con units/scale_verified/scale_px_per_unit/dpi/dpi_source")
    batch = ap.add_argument_group("modo batch")
    batch.add_argument("--registry", help="plans.csv generado por tools.import_plans")
    batch.add_argument("--masks-dir", help="Carpeta con <source_plan_id>.png")
    batch.add_argument("--allow-needs-review", action="store_true",
                       help="Incluir planos marcados needs_review en LabelMe (desaconsejado)")
    ap.add_argument("--tile", type=int, default=DEFAULT_TILE)
    ap.add_argument("--overlap", type=int, default=DEFAULT_OVERLAP)
    ap.add_argument("--min-foreground-ratio", type=float, default=0.0,
                    help="Descarta tiles con proporción de píxeles no-background (sobre el área válida) menor")
    ap.add_argument("--overwrite", action="store_true")
    ap.add_argument("--classes", help="Ruta alternativa a classes.yaml")
    args = ap.parse_args(argv)
    opts = dict(tile=args.tile, overlap=args.overlap, min_foreground_ratio=args.min_foreground_ratio,
                overwrite=args.overwrite)
    try:
        opts["schema"] = load_class_schema(args.classes)
        if args.registry:
            if not args.masks_dir:
                raise DatasetError("--registry requiere --masks-dir")
            tile_registry(Path(args.registry), Path(args.masks_dir), Path(args.output),
                          allow_needs_review=args.allow_needs_review, **opts)
            return 0
        missing = [n for n in ("image", "mask", "source_plan_id", "project_id") if not getattr(args, n)]
        if missing:
            raise DatasetError("modo un plano requiere --" + ", --".join(m.replace("_", "-") for m in missing))
        plan: dict[str, Any] = dict(read_json(args.metadata)) if args.metadata else {}
        plan.update(source_plan_id=args.source_plan_id, project_id=args.project_id,
                    source_type=args.source_type)
        for key in ("units", "scale_verified", "scale_px_per_unit", "dpi"):
            if getattr(args, key) is not None:
                plan[key] = getattr(args, key)
        if args.dpi is not None and not plan.get("dpi_source"):
            plan["dpi_source"] = "manual"
        manifest = tile_plan(args.image, args.mask, args.output, plan, **opts)
        print(f"Tiles generados: {len(manifest['tiles'])}; descartados: {len(manifest['skipped'])}; "
              f"salida: {args.output}")
    except DatasetError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
