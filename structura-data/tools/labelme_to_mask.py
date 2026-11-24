"""Convierte anotaciones LabelMe (JSON) a máscaras PNG de IDs de clase.

Salida: PNG grayscale, un canal, uint8, valores 0..N-1 (config/classes.yaml),
con exactamente el mismo alto/ancho que la imagen anotada.

Rasterización:
* Coordenadas subpíxel (OpenCV ``shift=4``). Para vértices enteros el resultado
  es idéntico al de LabelMe/PIL (bordes incluidos).
* ``polygon`` (≥3 puntos, área > 0), ``oriented_rectangle`` (LabelMe 7),
  ``rectangle``, ``circle`` y ``mask`` (LabelMe ≥5.3, recorte base64) se rellenan.
* ``line``/``linestrip``/``point``/``points`` NO tienen grosor en LabelMe; solo se
  aceptan con ``--line-width``/``--point-radius`` explícitos. No se inventa
  geometría. Los trazos tienen ancho exacto en horizontal/vertical; en oblicuo
  hay ±1 px de discretización.
* Compatibilidad verificada con el formato que escribe LabelMe 7.11.

Solapamientos (``--overlap-policy``):
* ``priority`` (por defecto): gana la clase con mayor prioridad según
  ``overlap_priority`` en classes.yaml (door > window > column > stairs > wall),
  independientemente del orden de dibujo.
* ``order``: comportamiento v0.2, la última forma del JSON prevalece.

Por cada plano se escribe ``<id>.report.json`` con conteos por clase,
solapamientos, banderas de revisión y advertencias.

Uso (Windows):
    python -m tools.labelme_to_mask --input .\\annotations --image-dir .\\work\\raw --output .\\work\\masks
"""
from __future__ import annotations

import argparse
import base64
import itertools
import json
import sys
from pathlib import Path, PureWindowsPath
from typing import Any

import cv2
import numpy as np

from .common import (
    TOOL_VERSION, ClassSchema, DatasetError, class_pixel_counts, load_class_schema,
    load_plan_image, require_png, sha256_bytes, sha256_file, write_json, write_png,
)

SHIFT = 4
SCALE = 1 << SHIFT


def _fixed(points: np.ndarray) -> np.ndarray:
    return np.round(points * SCALE).astype(np.int32)


def _polygon_area(points: np.ndarray) -> float:
    x, y = points[:, 0], points[:, 1]
    return 0.5 * abs(float(np.dot(x, np.roll(y, 1)) - np.dot(y, np.roll(x, 1))))


def _draw_stroke(canvas: np.ndarray, pts: np.ndarray, width: float, value: int) -> None:
    """Trazo de ancho exacto: un rectángulo por segmento (extremos planos) y
    uniones redondeadas. ``cv2.line`` no respeta el grosor (3 px → 5 px)."""
    # fillPoly incluye los bordes (convención LabelMe: un rectángulo de x1 a x2
    # cubre x2-x1+1 píxeles), por eso el semiancho es (W-1)/2 → W píxeles exactos.
    half = (width - 1.0) / 2.0
    for a, b in zip(pts[:-1], pts[1:]):
        d = b - a
        length = float(np.hypot(*d))
        if length < 1e-9:
            continue
        if half == 0:
            cv2.polylines(canvas, [_fixed(np.array([a, b]))], False, value, 1, cv2.LINE_8, SHIFT)
            continue
        n = np.array([-d[1], d[0]]) / length * half
        quad = np.array([a + n, b + n, b - n, a - n])
        cv2.fillPoly(canvas, [_fixed(quad)], value, lineType=cv2.LINE_8, shift=SHIFT)
    if half > 0:
        for p in pts[1:-1]:
            cv2.circle(canvas, tuple(int(v) for v in _fixed(p)), int(round(half * SCALE)), value, -1,
                       lineType=cv2.LINE_8, shift=SHIFT)


def _decode_mask_shape(shape: dict, height: int, width: int, points: np.ndarray, canvas: np.ndarray,
                       value: int) -> str | None:
    """shape_type 'mask' de LabelMe: PNG base64 de un recorte cuyo píxel (0,0)
    está en ``floor(points[0])``; ``points[1]`` es el extremo inclusivo del bbox.

    Igual que LabelMe 7, la extensión la da el propio recorte: si no coincide con
    el bbox (deriva tras editar vértices) se devuelve un aviso, no un error.
    """
    if len(points) != 2:
        raise DatasetError(f"shape 'mask' con {len(points)} puntos (se espera bbox de 2)")
    encoded = shape.get("mask")
    if not encoded:
        raise DatasetError("shape 'mask' sin datos base64")
    try:
        raw = base64.b64decode(encoded)
    except (ValueError, TypeError) as exc:
        raise DatasetError(f"shape 'mask' con base64 inválido: {exc}") from exc
    sub = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_GRAYSCALE)
    if sub is None:
        raise DatasetError("shape 'mask' con PNG ilegible")
    x1, y1 = (int(v) for v in np.floor(points[0]))
    x2, y2 = (int(v) for v in np.floor(points[1]))
    warning = None
    if sub.shape != (y2 - y1 + 1, x2 - x1 + 1):
        warning = (f"shape 'mask': recorte {sub.shape[1]}x{sub.shape[0]} distinto del bbox "
                   f"{x2 - x1 + 1}x{y2 - y1 + 1}; se usa el recorte desde points[0]")
    sh, sw = sub.shape
    sx0, sy0 = max(0, -x1), max(0, -y1)
    dx0, dy0 = max(0, x1), max(0, y1)
    dx1, dy1 = min(width, x1 + sw), min(height, y1 + sh)
    if dx1 > dx0 and dy1 > dy0:
        region = sub[sy0:sy0 + (dy1 - dy0), sx0:sx0 + (dx1 - dx0)] > 0
        canvas[dy0:dy1, dx0:dx1][region] = value
    return warning


def draw_shape(canvas: np.ndarray, shape: dict, value: int, *, line_width: int | None,
               point_radius: int | None) -> list[str]:
    """Dibuja una forma LabelMe sobre ``canvas`` (in place). Devuelve avisos."""
    kind = shape.get("shape_type") or "polygon"
    pts = np.asarray(shape.get("points") or [], dtype=np.float64)
    if pts.ndim != 2 or (len(pts) and pts.shape[1] != 2) or not np.all(np.isfinite(pts)):
        raise DatasetError(f"puntos inválidos en shape '{kind}'")
    h, w = canvas.shape
    if kind in ("polygon", "oriented_rectangle"):
        if kind == "oriented_rectangle" and len(pts) != 4:
            raise DatasetError(f"oriented_rectangle con {len(pts)} puntos (se esperan 4)")
        if len(pts) < 3:
            raise DatasetError(f"polígono con {len(pts)} puntos (mínimo 3)")
        if _polygon_area(pts) < 1.0:
            raise DatasetError("polígono degenerado (área < 1 px²)")
        cv2.fillPoly(canvas, [_fixed(pts)], value, lineType=cv2.LINE_8, shift=SHIFT)
    elif kind == "rectangle":
        if len(pts) != 2:
            raise DatasetError(f"rectángulo con {len(pts)} puntos (se esperan 2)")
        (x1, y1), (x2, y2) = pts
        corners = np.array([[x1, y1], [x2, y1], [x2, y2], [x1, y2]])
        cv2.fillPoly(canvas, [_fixed(corners)], value, lineType=cv2.LINE_8, shift=SHIFT)
    elif kind == "circle":
        if len(pts) != 2:
            raise DatasetError(f"círculo con {len(pts)} puntos (se esperan 2)")
        radius = float(np.linalg.norm(pts[1] - pts[0]))
        if radius < 0.5:
            raise DatasetError("círculo degenerado (radio < 0.5 px)")
        center = tuple(int(v) for v in _fixed(pts[0]))
        cv2.circle(canvas, center, int(round(radius * SCALE)), value, -1, lineType=cv2.LINE_8, shift=SHIFT)
    elif kind == "mask":
        warning = _decode_mask_shape(shape, h, w, pts, canvas, value)
        return [warning] if warning else []
    elif kind in ("line", "linestrip"):
        if not line_width:
            raise DatasetError(f"'{kind}' no tiene grosor en LabelMe; indicar --line-width o usar polígonos")
        if len(pts) < 2 or (kind == "line" and len(pts) != 2):
            raise DatasetError(f"'{kind}' con {len(pts)} puntos")
        _draw_stroke(canvas, pts, float(line_width), value)
    elif kind in ("point", "points"):
        if not point_radius:
            raise DatasetError(f"'{kind}' no tiene tamaño en LabelMe; indicar --point-radius")
        if len(pts) < 1 or (kind == "point" and len(pts) != 1):
            raise DatasetError(f"'{kind}' con {len(pts)} puntos")
        for p in pts:
            center = tuple(int(v) for v in _fixed(p))
            cv2.circle(canvas, center, int(point_radius) * SCALE, value, -1, lineType=cv2.LINE_8, shift=SHIFT)
    else:
        raise DatasetError(f"shape_type no soportado: {kind!r}")
    return []


def resolve_image_path(json_path: Path, image_name: str, image_dir: Path | None) -> Path:
    """Resuelve imagePath como LabelMe (relativo al JSON) y luego en --image-dir."""
    name_path = PureWindowsPath(image_name) if "\\" in image_name else Path(image_name)
    candidates = [json_path.parent / Path(*name_path.parts)] if not name_path.is_absolute() else [Path(image_name)]
    if image_dir is not None:
        candidates.append(image_dir / name_path.name)
    candidates.append(json_path.parent / name_path.name)
    for c in candidates:
        if c.is_file():
            return c
    raise DatasetError(f"No se encontró la imagen '{image_name}' (buscada en {[str(c) for c in candidates]})")


def convert_labelme(json_path: str | Path, *, image_path: str | Path | None = None,
                    image_dir: str | Path | None = None, schema: ClassSchema | None = None,
                    overlap_policy: str = "priority", unknown_label: str = "error",
                    line_width: int | None = None, point_radius: int | None = None
                    ) -> tuple[np.ndarray, dict[str, Any]]:
    """Convierte un JSON LabelMe. Devuelve (máscara uint8 HxW, reporte)."""
    schema = schema or load_class_schema()
    json_path = Path(json_path)
    if overlap_policy not in ("priority", "order"):
        raise DatasetError(f"overlap_policy inválida {overlap_policy!r}")
    raw = json_path.read_bytes()
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise DatasetError(f"JSON inválido: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("shapes", []), list):
        raise DatasetError("no parece un JSON de LabelMe (falta 'shapes')")

    warnings: list[str] = []
    json_image = data.get("imagePath") or ""
    if image_path is not None:
        image_path = Path(image_path)
        if json_image and PureWindowsPath(json_image).name.lower() != image_path.name.lower():
            raise DatasetError(f"el JSON fue anotado sobre '{PureWindowsPath(json_image).name}' "
                               f"pero se indicó la imagen '{image_path.name}'")
    else:
        if not json_image:
            raise DatasetError("JSON sin imagePath")
        image_path = resolve_image_path(json_path, json_image, Path(image_dir) if image_dir else None)
    require_png(image_path, "La imagen anotada")
    image = load_plan_image(image_path)
    h, w = image.shape[:2]
    for key, actual in (("imageHeight", h), ("imageWidth", w)):
        declared = data.get(key)
        if declared is None:
            warnings.append(f"JSON sin {key}; no se pudo verificar la dimensión")
        elif int(declared) != actual:
            raise DatasetError(f"{key} JSON={declared} pero la imagen mide {actual}: "
                               "la anotación no corresponde a esta imagen")

    label_to_id = schema.label_to_id
    layers = {cid: np.zeros((h, w), np.uint8) for cid in range(1, schema.num_classes)}
    ordered_mask = np.zeros((h, w), np.uint8) if overlap_policy == "order" else None
    shape_counts: dict[str, int] = {}
    shape_types: dict[str, int] = {}
    flagged_shapes: list[dict] = []
    seen: set[tuple] = set()
    out_of_bounds = 0

    for idx, shape in enumerate(data.get("shapes", [])):
        label = str(shape.get("label", "")).strip().lower()
        if label == "background":
            raise DatasetError(f"shape #{idx}: no dibujar 'background' (es el valor por defecto)")
        if label not in label_to_id:
            if unknown_label == "ignore":
                warnings.append(f"shape #{idx}: etiqueta desconocida '{label}' ignorada")
                continue
            raise DatasetError(f"shape #{idx}: etiqueta desconocida '{label}'; válidas: {list(schema.names[1:])}")
        cid = label_to_id[label]
        key = (label, shape.get("shape_type"), json.dumps(shape.get("points"), sort_keys=True))
        if key in seen:
            warnings.append(f"shape #{idx} ({label}) duplicada exactamente")
        seen.add(key)
        try:
            for msg in draw_shape(layers[cid], shape, 1, line_width=line_width, point_radius=point_radius):
                warnings.append(f"shape #{idx} ({label}): {msg}")
            if ordered_mask is not None:
                draw_shape(ordered_mask, shape, cid, line_width=line_width, point_radius=point_radius)
        except DatasetError as exc:
            raise DatasetError(f"shape #{idx} ({label}): {exc}") from None
        # Puntos validados por draw_shape. Tolerancia de 1 px: un clic en el borde
        # exterior del último píxel produce coordenadas = ancho/alto.
        pts = np.asarray(shape["points"], dtype=np.float64)
        if pts.min() < -1.0 or pts[:, 0].max() > w + 1.0 or pts[:, 1].max() > h + 1.0:
            out_of_bounds += 1
        shape_counts[label] = shape_counts.get(label, 0) + 1
        kind = shape.get("shape_type") or "polygon"
        shape_types[kind] = shape_types.get(kind, 0) + 1
        active_flags = sorted(k for k, v in (shape.get("flags") or {}).items() if v)
        if active_flags or (shape.get("description") or "").strip():
            flagged_shapes.append({"index": idx, "label": label, "flags": active_flags,
                                   "description": (shape.get("description") or "").strip()})

    if out_of_bounds:
        warnings.append(f"{out_of_bounds} formas exceden los bordes de la imagen (se recortan)")

    if ordered_mask is not None:
        mask = ordered_mask
    else:
        mask = np.zeros((h, w), np.uint8)
        for name in schema.priority:  # de menor a mayor prioridad
            cid = schema.id_of(name)
            mask[layers[cid] > 0] = cid

    overlaps = []
    for a, b in itertools.combinations(range(1, schema.num_classes), 2):
        n = int(np.count_nonzero(layers[a] & layers[b]))
        if n:
            na, nb = schema.names[a], schema.names[b]
            expected = schema.is_expected_overlap(na, nb)
            winner = (na if schema.priority.index(na) > schema.priority.index(nb) else nb) \
                if overlap_policy == "priority" else "última forma"
            overlaps.append({"classes": [na, nb], "pixels": n, "expected": expected, "winner": winner})
            if not expected:
                warnings.append(f"conflicto {na}/{nb}: {n} px solapados (gana {winner}); revisar")

    image_flags = {k: bool(v) for k, v in (data.get("flags") or {}).items()}
    report = {
        "tool": "labelme_to_mask", "tool_version": TOOL_VERSION,
        "json_file": json_path.name, "json_sha256": sha256_bytes(raw),
        "image_file": image_path.name, "image_sha256": sha256_file(image_path),
        "width": w, "height": h, "overlap_policy": overlap_policy,
        "class_names": list(schema.names),
        "class_pixel_counts": class_pixel_counts(mask, schema.num_classes),
        "shape_counts": shape_counts, "shape_types": shape_types,
        "overlaps": overlaps, "image_flags": image_flags,
        "needs_review": bool(image_flags.get("needs_review")),
        "partial": bool(image_flags.get("partial")),
        "flagged_shapes": flagged_shapes, "warnings": warnings,
        "labelme_version": data.get("version"),
    }
    if not shape_counts:
        warnings.append("sin formas anotadas: la máscara es solo background")
    return mask, report


def write_mask(mask: np.ndarray, report: dict, output_dir: Path, stem: str, overwrite: bool,
               write_report: bool = True) -> Path:
    target = output_dir / f"{stem}.png"
    if target.exists() and not overwrite:
        raise DatasetError(f"{target} ya existe; usar --overwrite")
    report = dict(report, mask_file=target.name)
    write_png(target, mask)
    if write_report:
        write_json(output_dir / f"{stem}.report.json", report)
    return target


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Convierte anotaciones LabelMe a máscaras PNG de IDs.")
    ap.add_argument("--input", required=True, help="JSON individual o carpeta con JSON")
    ap.add_argument("--output", required=True, help="Carpeta de máscaras de plano completo")
    ap.add_argument("--image-dir", help="Carpeta donde buscar las imágenes (si imagePath no resuelve)")
    ap.add_argument("--unknown-label", choices=["error", "ignore"], default="error")
    ap.add_argument("--overlap-policy", choices=["priority", "order"], default="priority")
    ap.add_argument("--line-width", type=int, help="Grosor en px para line/linestrip (sin valor por defecto)")
    ap.add_argument("--point-radius", type=int, help="Radio en px para point (sin valor por defecto)")
    ap.add_argument("--classes", help="Ruta alternativa a classes.yaml")
    ap.add_argument("--no-report", action="store_true", help="No escribir <id>.report.json")
    ap.add_argument("--overwrite", action="store_true")
    args = ap.parse_args(argv)

    try:
        schema = load_class_schema(args.classes)
    except DatasetError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    src, out = Path(args.input), Path(args.output)
    json_files = [src] if src.is_file() else sorted(src.glob("*.json"))
    if not json_files:
        print("ERROR: no se encontraron JSON de LabelMe.", file=sys.stderr)
        return 1
    out.mkdir(parents=True, exist_ok=True)
    errors = []
    for jf in json_files:
        try:
            mask, report = convert_labelme(
                jf, image_dir=args.image_dir, schema=schema, overlap_policy=args.overlap_policy,
                unknown_label=args.unknown_label, line_width=args.line_width,
                point_radius=args.point_radius)
            target = write_mask(mask, report, out, jf.stem, args.overwrite, not args.no_report)
            extra = " [NEEDS_REVIEW]" if report["needs_review"] else ""
            print(f"OK {jf.name} -> {target.name} ({report['width']}x{report['height']}){extra}")
            for w in report["warnings"]:
                print(f"   aviso: {w}")
        except (DatasetError, OSError) as exc:
            errors.append(f"{jf.name}: {exc}")
    if errors:
        print("\nERRORES:\n" + "\n".join(errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
