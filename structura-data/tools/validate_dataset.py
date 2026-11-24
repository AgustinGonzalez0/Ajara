"""Valida estructuralmente un dataset de tiles antes de entrenar.

Comprueba (errores → código de salida 1):
* Archivos: imágenes/máscaras/metadatos faltantes o huérfanos, extensiones no
  PNG, nombres duplicados (también por mayúsculas, relevante en Windows).
* Contenido: archivos corruptos, máscaras multicanal o no uint8, IDs fuera de
  rango, dimensiones distintas entre imagen y máscara o distintas del tile.
* Metadatos: campos obligatorios y tipos, tile_id = nombre de archivo,
  coordenadas dentro del plano, relleno coherente (imagen blanca / clase 0),
  conteos de clase y hashes iguales a los archivos (detecta ediciones
  posteriores), scale_verified sin unidades/escala.
* Coherencia entre tiles: un plano en varios proyectos, la misma imagen fuente
  con distintos IDs (fuga), atributos de plano contradictorios.
* Manifiestos de plano (plans/): rejilla completa, solapes idénticos entre
  tiles vecinos y reconstrucción exacta del plano original (hash).
* Splits: referencias inexistentes, duplicados, tiles/planos/proyectos en más
  de un split.

No evalúa si los polígonos están bien dibujados: eso requiere revisión humana.

Uso (Windows):
    python -m tools.validate_dataset --dataset .\\dataset --report .\\dataset\\validation_report.json
    python -m tools.validate_dataset --images .\\dataset\\images --masks .\\dataset\\masks --metadata .\\dataset\\metadata
"""
from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

import numpy as np

from .common import (
    DPI_SOURCES, ID_PATTERN, SOURCE_TYPES, SPLIT_NAMES, UNITS, ClassSchema, DatasetError,
    array_digest, class_pixel_counts, consistency_errors, decode_image, load_class_schema,
    read_json, sha256_file, write_json,
)

REQUIRED_META: dict[str, tuple[type, ...]] = {
    "schema_version": (int,), "tile_id": (str,), "source_plan_id": (str,), "project_id": (str,),
    "source_type": (str,), "source_image_sha256": (str,), "source_width": (int,),
    "source_height": (int,), "x": (int,), "y": (int,), "width": (int,), "height": (int,),
    "tile_size": (int,), "overlap": (int,), "pad_right": (int,), "pad_bottom": (int,),
    "class_pixel_counts": (list,), "image_sha256": (str,), "mask_sha256": (str,),
    "units": (str,), "scale_verified": (bool,), "dpi_source": (str,),
}
OPTIONAL_NUMBER = ("scale_px_per_unit", "dpi")
PLAN_LEVEL_FIELDS = ("project_id", "source_type", "source_image_sha256", "source_width",
                     "source_height", "tile_size", "overlap", "units", "scale_verified",
                     "scale_px_per_unit", "dpi")


class Report:
    def __init__(self) -> None:
        self.errors: list[dict[str, str]] = []
        self.warnings: list[dict[str, str]] = []
        self.stats: dict[str, Any] = {}

    def error(self, code: str, item: str, message: str) -> None:
        self.errors.append({"code": code, "item": item, "message": message})

    def warn(self, code: str, item: str, message: str) -> None:
        self.warnings.append({"code": code, "item": item, "message": message})

    @property
    def ok(self) -> bool:
        return not self.errors

    def codes(self, kind: str = "errors") -> set[str]:
        return {e["code"] for e in getattr(self, kind)}

    def to_dict(self) -> dict[str, Any]:
        return {"ok": self.ok, "stats": self.stats, "errors": self.errors, "warnings": self.warnings}

    def print_summary(self, limit: int = 15) -> None:
        for kind, label in (("warnings", "ADVERTENCIAS"), ("errors", "ERRORES")):
            items = getattr(self, kind)
            if not items:
                continue
            by_code: dict[str, list] = defaultdict(list)
            for it in items:
                by_code[it["code"]].append(it)
            print(f"\n{label} ({len(items)}):")
            for code, group in sorted(by_code.items()):
                print(f"  [{code}] x{len(group)}")
                for it in group[:limit]:
                    print(f"    - {it['item']}: {it['message']}")
                if len(group) > limit:
                    print(f"    … {len(group) - limit} más (ver --report)")


def _list_files(folder: Path, recursive: bool) -> list[Path]:
    if not folder.is_dir():
        return []
    it = folder.rglob("*") if recursive else folder.iterdir()
    return sorted(p for p in it if p.is_file())


def _index(folder: Path, ext: str, role: str, recursive: bool, report: Report) -> dict[str, Path]:
    index: dict[str, Path] = {}
    lower: dict[str, str] = {}
    for p in _list_files(folder, recursive):
        if p.name.startswith(".") and p.suffix == ".tmp":
            report.warn("stray_temp_file", p.name, f"archivo temporal en {role} (escritura interrumpida)")
            continue
        if p.suffix.lower() != ext:
            if not (role == "masks" and p.name.endswith(".report.json")):
                report.error("unexpected_file", p.name, f"extensión no válida en {role}/ (se espera {ext})")
            continue
        key = p.stem.lower()
        if p.stem in index or key in lower:
            report.error("duplicate_name", p.stem, f"nombre repetido en {role}/ (Windows no distingue mayúsculas)")
            continue
        index[p.stem] = p
        lower[key] = p.stem
    return index


def _check_meta_fields(name: str, meta: dict, schema: ClassSchema, report: Report) -> bool:
    ok = True
    for field, types in REQUIRED_META.items():
        if field not in meta:
            report.error("metadata_missing_field", name, f"falta '{field}'")
            ok = False
        elif not isinstance(meta[field], types) or (bool not in types and isinstance(meta[field], bool)):
            report.error("metadata_bad_type", name, f"'{field}' tiene tipo {type(meta[field]).__name__}")
            ok = False
    for field in OPTIONAL_NUMBER:
        v = meta.get(field)
        if v is not None and (isinstance(v, bool) or not isinstance(v, (int, float)) or v <= 0):
            report.error("metadata_bad_type", name, f"'{field}' debe ser número > 0 o null")
            ok = False
    if not ok:
        return False
    if meta["tile_id"] != name:
        report.error("metadata_tile_id", name, f"tile_id={meta['tile_id']!r} no coincide con el archivo")
    for f in ("source_plan_id", "project_id"):
        if not ID_PATTERN.match(meta[f]):
            report.error("metadata_bad_id", name, f"{f}={meta[f]!r} no es un ID válido")
    for f, choices in (("source_type", SOURCE_TYPES), ("units", UNITS), ("dpi_source", DPI_SOURCES)):
        if meta[f] not in choices:
            report.error("metadata_bad_value", name, f"{f}={meta[f]!r} no está en {choices}")
    if meta["scale_verified"] and (meta["units"] == "unknown" or not meta.get("scale_px_per_unit")):
        report.error("scale_unverifiable", name, "scale_verified=true sin units/scale_px_per_unit")
    if len(meta["class_pixel_counts"]) != schema.num_classes:
        report.error("metadata_bad_value", name, "class_pixel_counts con longitud distinta al nº de clases")
    t = meta["tile_size"]
    geom = [meta["x"] >= 0, meta["y"] >= 0, 0 < meta["width"] <= t, 0 < meta["height"] <= t,
            meta["width"] + meta["pad_right"] == t, meta["height"] + meta["pad_bottom"] == t,
            meta["x"] + meta["width"] <= meta["source_width"],
            meta["y"] + meta["height"] <= meta["source_height"], 0 <= meta["overlap"] < t]
    if not all(geom):
        report.error("metadata_geometry", name, "coordenadas/relleno incoherentes con tile_size o plano fuente")
        return False
    return True


def _check_pair(name: str, img_path: Path, mask_path: Path, meta: dict | None, meta_ok: bool,
                schema: ClassSchema, report: Report, stats: dict) -> None:
    img = decode_image(img_path)
    mask = decode_image(mask_path)
    if img is None:
        report.error("corrupt_image", name, "imagen corrupta o ilegible")
    if mask is None:
        report.error("corrupt_mask", name, "máscara corrupta o ilegible")
    if img is None or mask is None:
        return
    if img.dtype != np.uint8:
        report.error("image_dtype", name, f"imagen {img.dtype}; se requiere uint8")
    if img.ndim == 2:
        report.warn("image_grayscale", name, "imagen de un canal (se esperaba RGB)")
    elif img.shape[2] != 3:
        report.warn("image_channels", name, f"imagen con {img.shape[2]} canales")
    if mask.ndim != 2:
        report.error("mask_multichannel", name, f"máscara con {mask.shape[2]} canales; se requiere uno")
        return
    if mask.dtype != np.uint8:
        report.error("mask_dtype", name, f"máscara {mask.dtype}; se requiere uint8")
        return
    if img.shape[:2] != mask.shape:
        report.error("size_mismatch", name, f"imagen {img.shape[:2]} vs máscara {mask.shape}")
        return
    ids = set(np.unique(mask).tolist())
    if not ids <= schema.valid_ids:
        report.error("invalid_class_ids", name, f"IDs inválidos {sorted(ids - schema.valid_ids)}")
        return
    counts = class_pixel_counts(mask, schema.num_classes)
    for i, c in enumerate(counts):
        stats["class_pixels"][i] += c
    if ids == {0}:
        stats["empty_masks"] += 1
        report.warn("empty_mask", name, "máscara solo background")

    if meta is None or not meta_ok:
        return
    t = meta["tile_size"]
    if mask.shape != (t, t):
        report.error("tile_size_mismatch", name, f"tile {mask.shape} distinto de tile_size={t}")
        return
    if counts != meta["class_pixel_counts"]:
        report.error("class_counts_mismatch", name, "conteos de clase distintos a los registrados")
    if sha256_file(img_path) != meta["image_sha256"]:
        report.error("image_modified", name, "la imagen fue modificada después de generar el tile")
    if sha256_file(mask_path) != meta["mask_sha256"]:
        report.error("mask_modified", name, "la máscara fue modificada después de generar el tile")
    h, w = meta["height"], meta["width"]
    if mask[h:, :].any() or mask[:, w:].any():
        report.error("padding_mask", name, "el relleno de la máscara no es clase 0")
    img3 = img if img.ndim == 3 else img[:, :, None]
    if (img3[h:, :] != 255).any() or (img3[:, w:] != 255).any():
        report.error("padding_image", name, "el relleno de la imagen no es blanco")


def _check_plans(plans_dir: Path, images: dict, masks: dict, metadata: dict, report: Report) -> None:
    by_plan: dict[str, set] = defaultdict(set)
    for tid, meta in metadata.items():
        by_plan[meta.get("source_plan_id")].add(tid)
    manifests = {p.stem: p for p in sorted(plans_dir.glob("*.json"))} if plans_dir.is_dir() else {}
    for plan in sorted(set(by_plan) - set(manifests), key=str):
        report.warn("plan_manifest_missing", str(plan), "tiles sin manifiesto plans/<id>.json")
    for plan_id, path in manifests.items():
        try:
            man = read_json(path)
            listed = set(man["tiles"])
            grid = {(x, y) for x in man["grid_x"] for y in man["grid_y"]}
            skipped = {(s["x"], s["y"]) for s in man["skipped"]}
            H, W, t = man["source_height"], man["source_width"], man["tile_size"]
        except (KeyError, TypeError, ValueError) as exc:
            report.error("plan_manifest_invalid", plan_id, f"manifiesto inválido: {exc}")
            continue
        if plan_id not in by_plan and listed:
            report.error("plan_tiles_missing", plan_id, "el manifiesto lista tiles que no existen")
            continue
        missing = listed - by_plan.get(plan_id, set())
        extra = by_plan.get(plan_id, set()) - listed
        for tid in sorted(missing):
            report.error("plan_tile_missing", tid, f"listado en plans/{plan_id}.json pero no existe")
        for tid in sorted(extra):
            report.error("plan_tile_unlisted", tid, f"no figura en plans/{plan_id}.json (tile obsoleto)")
        coords = {(metadata[t_]["x"], metadata[t_]["y"]) for t_ in listed & set(metadata)}
        if coords | skipped != grid or coords & skipped:
            report.error("plan_grid_incomplete", plan_id, "tiles + descartados no cubren la rejilla declarada")
        if missing or extra:
            continue
        # Reconstrucción: solapes idénticos y plano original exacto.
        rec_mask = np.zeros((H, W), np.uint8)
        rec_img = np.zeros((H, W, 3), np.uint8)
        filled = np.zeros((H, W), bool)
        desync = False
        for tid in sorted(listed):
            meta = metadata[tid]
            if tid not in images or tid not in masks:
                continue
            ti, tm = decode_image(images[tid]), decode_image(masks[tid])
            if ti is None or tm is None or ti.ndim != 3 or tm.ndim != 2 or tm.shape != (t, t):
                desync = True
                continue
            x, y, w, h = meta["x"], meta["y"], meta["width"], meta["height"]
            region = filled[y:y + h, x:x + w]
            if region.any():
                if not (np.array_equal(rec_mask[y:y + h, x:x + w][region], tm[:h, :w][region]) and
                        np.array_equal(rec_img[y:y + h, x:x + w][region], ti[:h, :w][region])):
                    report.error("overlap_desync", tid, "el solape no coincide con el tile vecino")
                    desync = True
            rec_mask[y:y + h, x:x + w] = tm[:h, :w]
            rec_img[y:y + h, x:x + w] = ti[:h, :w]
            filled[y:y + h, x:x + w] = True
        if desync or skipped:
            continue
        if not filled.all():
            report.error("plan_coverage", plan_id, "hay píxeles del plano sin cubrir por ningún tile")
        elif array_digest(rec_mask) != man.get("source_mask_digest") or \
                array_digest(rec_img) != man.get("source_image_digest"):
            report.error("plan_reconstruction", plan_id, "la reconstrucción desde tiles no coincide con el plano fuente")


def _check_splits(splits_dir: Path, pairs: set[str], metadata: dict, report: Report, stats: dict) -> None:
    membership: dict[str, list[str]] = defaultdict(list)
    for split in SPLIT_NAMES:
        path = splits_dir / f"{split}.txt"
        if not path.exists():
            (report.warn if split == "test" else report.error)("split_missing", f"{split}.txt", "no existe")
            continue
        ids = [line.strip() for line in path.read_text(encoding="utf-8-sig").splitlines() if line.strip()]
        stats["split_tiles"][split] = len(ids)
        if not ids:
            report.warn("split_empty", f"{split}.txt", "split vacío")
        seen = set()
        for tid in ids:
            if tid in seen:
                report.error("split_duplicate", tid, f"repetido en {split}.txt")
            seen.add(tid)
            if tid not in pairs:
                report.error("split_unknown_tile", tid, f"en {split}.txt pero no existe el par imagen/máscara")
            membership[tid].append(split)
    for tid, splits in sorted(membership.items()):
        if len(set(splits)) > 1:
            report.error("split_tile_leak", tid, f"en varios splits {sorted(set(splits))}")
    unassigned = pairs - set(membership)
    if membership and unassigned:
        report.warn("split_unassigned", f"{len(unassigned)} tiles", "no figuran en ningún split")
    if not metadata:
        return
    group_by = "project_id"
    manifest = splits_dir / "split_manifest.json"
    if manifest.exists():
        try:
            group_by = read_json(manifest).get("group_by", "project_id")
        except ValueError:
            report.warn("split_manifest_invalid", manifest.name, "JSON inválido")
    for field in ("source_plan_id", "project_id"):
        owner: dict[str, set] = defaultdict(set)
        for tid, splits in membership.items():
            if tid in metadata:
                owner[metadata[tid].get(field)].update(splits)
        for group, splits in sorted(owner.items(), key=lambda kv: str(kv[0])):
            if len(splits) > 1:
                if field == "source_plan_id" or group_by == "project_id":
                    report.error("split_group_leak", str(group), f"{field} repartido en {sorted(splits)}")
                else:
                    report.warn("split_project_shared", str(group),
                                f"proyecto en {sorted(splits)} (splits por source_plan_id)")


def validate_dataset(images_dir: str | Path, masks_dir: str | Path, metadata_dir: str | Path | None = None,
                     *, plans_dir: str | Path | None = None, splits_dir: str | Path | None = None,
                     schema: ClassSchema | None = None, recursive: bool = False) -> Report:
    schema = schema or load_class_schema()
    report = Report()
    stats: dict[str, Any] = {"class_pixels": [0] * schema.num_classes, "empty_masks": 0, "split_tiles": {}}
    images = _index(Path(images_dir), ".png", "images", recursive, report)
    masks = _index(Path(masks_dir), ".png", "masks", recursive, report)
    metadata: dict[str, dict] = {}
    meta_files: dict[str, Path] = {}
    if metadata_dir is not None:
        meta_files = _index(Path(metadata_dir), ".json", "metadata", recursive, report)
        for name, path in meta_files.items():
            try:
                data = read_json(path)
                if not isinstance(data, dict):
                    raise ValueError("no es un objeto")
                metadata[name] = data
            except ValueError as exc:
                report.error("metadata_invalid_json", name, f"JSON inválido: {exc}")
    if not images and not masks:
        report.error("empty_dataset", str(images_dir), "no hay imágenes ni máscaras")

    meta_ok: dict[str, bool] = {}
    for name in sorted(images.keys() | masks.keys()):
        if name not in images:
            report.error("missing_image", name, "falta la imagen")
            continue
        if name not in masks:
            report.error("missing_mask", name, "falta la máscara")
            continue
        meta = None
        if metadata_dir is not None:
            if name not in meta_files:
                report.error("missing_metadata", name, "falta metadata")
            elif name in metadata:
                meta = metadata[name]
                meta_ok[name] = _check_meta_fields(name, meta, schema, report)
        _check_pair(name, images[name], masks[name], meta, meta_ok.get(name, False), schema, report, stats)
    for name in sorted(set(meta_files) - (images.keys() | masks.keys())):
        report.error("orphan_metadata", name, "metadata sin imagen ni máscara")

    valid_meta = {k: v for k, v in metadata.items() if meta_ok.get(k)}
    if valid_meta:
        for msg in consistency_errors(valid_meta):
            report.error("cross_plan_inconsistency", "dataset", msg)
        plan_attrs: dict[str, dict[str, set]] = defaultdict(lambda: defaultdict(set))
        for meta in valid_meta.values():
            for f in PLAN_LEVEL_FIELDS:
                plan_attrs[meta["source_plan_id"]][f].add(repr(meta.get(f)))
        for plan, attrs in sorted(plan_attrs.items()):
            bad = [f for f, vals in attrs.items() if len(vals) > 1 and f != "project_id"]
            if bad:
                report.error("plan_attribute_conflict", plan, f"tiles del plano con valores distintos en {bad}")
        by_hash: dict[str, list[str]] = defaultdict(list)
        for name, meta in valid_meta.items():
            by_hash[meta["image_sha256"]].append(name)
        for digest, names in by_hash.items():
            projects = {valid_meta[n]["project_id"] for n in names}
            if len(names) > 1 and len(projects) > 1:
                img = decode_image(images[names[0]]) if names[0] in images else None
                if img is not None and img.min() != img.max():
                    report.warn("duplicate_tile_content", ",".join(sorted(names)[:3]),
                                f"contenido idéntico en proyectos distintos {sorted(projects)}")
        if plans_dir is not None:
            _check_plans(Path(plans_dir), images, masks, valid_meta, report)
    if splits_dir is not None and Path(splits_dir).is_dir():
        _check_splits(Path(splits_dir), set(images) & set(masks), valid_meta, report, stats)

    stats.update({
        "images": len(images), "masks": len(masks), "metadata": len(meta_files),
        "plans": len({m["source_plan_id"] for m in valid_meta.values()}),
        "projects": len({m["project_id"] for m in valid_meta.values()}),
        "class_names": list(schema.names),
    })
    report.stats = stats
    return report


def validate_dataset_root(root: str | Path, *, with_splits: bool = True,
                          schema: ClassSchema | None = None) -> Report:
    root = Path(root)
    splits = root / "splits"
    return validate_dataset(root / "images", root / "masks", root / "metadata",
                            plans_dir=root / "plans",
                            splits_dir=splits if with_splits and splits.is_dir() else None,
                            schema=schema)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Valida pares, máscaras, IDs, metadatos, planos y splits.")
    ap.add_argument("--dataset", help="Raíz del dataset (usa images/ masks/ metadata/ plans/ splits/)")
    ap.add_argument("--images")
    ap.add_argument("--masks")
    ap.add_argument("--metadata", help="Carpeta metadata/; si se omite no valida metadatos")
    ap.add_argument("--plans", help="Carpeta plans/ (manifiestos por plano)")
    ap.add_argument("--splits", help="Carpeta con train/validation/test.txt")
    ap.add_argument("--recursive", action="store_true")
    ap.add_argument("--classes", help="Ruta alternativa a classes.yaml")
    ap.add_argument("--report", help="Escribe el informe completo en JSON")
    ap.add_argument("--max-print", type=int, default=15)
    args = ap.parse_args(argv)
    try:
        schema = load_class_schema(args.classes)
        if args.dataset:
            report = validate_dataset_root(args.dataset, schema=schema)
        elif args.images and args.masks:
            report = validate_dataset(args.images, args.masks, args.metadata, plans_dir=args.plans,
                                      splits_dir=args.splits, schema=schema, recursive=args.recursive)
        else:
            raise DatasetError("indicar --dataset o bien --images y --masks")
    except DatasetError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    s = report.stats
    print(f"Imágenes: {s['images']}  máscaras: {s['masks']}  metadata: {s['metadata']}  "
          f"planos: {s['plans']}  proyectos: {s['projects']}")
    total = sum(s["class_pixels"]) or 1
    print("Píxeles por clase: " + ", ".join(
        f"{n}={c / total:.2%}" for n, c in zip(s["class_names"], s["class_pixels"])))
    if s["split_tiles"]:
        print("Splits: " + ", ".join(f"{k}={v}" for k, v in s["split_tiles"].items()))
    report.print_summary(args.max_print)
    if args.report:
        write_json(args.report, report.to_dict())
        print(f"\nInforme: {args.report}")
    if not report.ok:
        print("\nVALIDACIÓN FALLIDA: corregir los errores antes de entrenar.")
        return 1
    print("\nVALIDACIÓN ESTRUCTURAL OK. La calidad semántica requiere revisión humana.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
