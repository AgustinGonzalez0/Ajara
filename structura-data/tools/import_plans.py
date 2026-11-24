"""Importa planos PDF/PNG/JPG/TIFF a PNG RGB canónico y los registra en plans.csv.

Por qué existe: la máscara se rasteriza sobre los píxeles que el anotador vio en
LabelMe y los tiles se recortan de la misma imagen. Si cada herramienta
decodificara JPG/PDF por su cuenta (orientación EXIF, transparencias, 16 bits,
DPI de renderizado), máscara e imagen podrían quedar desalineadas. Este módulo
genera una única imagen canónica por plano/página:

* PDF: renderizado vectorial a un DPI explícito (registrado como ``pdf_render``).
* Raster: orientación EXIF aplicada, transparencia compuesta sobre blanco,
  16 bits → 8 bits, salida RGB sin metadatos.

El DPI de cabecera de un raster se registra como ``file_header`` (no verificado).
La escala del dibujo (1:50, 1:100…) NUNCA se infiere: ``scale_verified=false``.

Uso (Windows):
    python -m tools.import_plans --input .\\incoming\\proyecto_a --project-id proj_a ^
        --source-type digital --output-dir .\\work\\raw --registry .\\work\\plans.csv
"""
from __future__ import annotations

import argparse
import sys
import unicodedata
from pathlib import Path
from typing import Iterator

import numpy as np
from PIL import Image, ImageOps

from .common import (
    SOURCE_TYPES, UNITS, DatasetError, read_registry, sha256_bytes, sha256_file,
    to_registry_path, validate_id, write_png, write_registry,
)

RASTER_EXT = {".png", ".jpg", ".jpeg", ".tif", ".tiff"}
PDF_EXT = {".pdf"}
DEFAULT_DPI = 200
DEFAULT_MAX_PIXELS = 250_000_000


def sanitize_id(text: str, max_len: int = 56) -> str:
    """'Planta Baja (año 2020)' → 'Planta_Baja_ano_2020'."""
    ascii_text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    out = "".join(c if c.isalnum() or c in "-_" else "_" for c in ascii_text)
    while "__" in out:
        out = out.replace("__", "_")
    out = out.strip("_-")[:max_len].rstrip("_-")
    if not out:
        raise DatasetError(f"No se pudo derivar un ID válido de {text!r}; usar --plan-id")
    return out


def parse_pages(spec: str | None, page_count: int) -> list[int]:
    """'1,3-5' (1-based) → [0, 2, 3, 4]."""
    if not spec:
        return list(range(page_count))
    pages: list[int] = []
    for part in spec.split(","):
        part = part.strip()
        if "-" in part:
            a, b = (int(x) for x in part.split("-", 1))
            pages.extend(range(a, b + 1))
        elif part:
            pages.append(int(part))
    bad = [p for p in pages if p < 1 or p > page_count]
    if bad:
        raise DatasetError(f"Páginas fuera de rango {bad}; el PDF tiene {page_count}")
    return [p - 1 for p in dict.fromkeys(pages)]


def raster_to_rgb(path: Path, max_pixels: int) -> tuple[np.ndarray, float | None]:
    """Decodifica un raster a RGB uint8 canónico. Devuelve (array, dpi_cabecera)."""
    Image.MAX_IMAGE_PIXELS = max_pixels
    try:
        with Image.open(path) as im:
            if getattr(im, "n_frames", 1) > 1:
                raise DatasetError(f"{path.name}: tiene {im.n_frames} páginas/cuadros; separarlas "
                                   "(o convertir a PDF) para no perder páginas en silencio")
            im.load()
            im = ImageOps.exif_transpose(im)
            dpi = im.info.get("dpi")
            if im.mode in ("I;16", "I;16B", "I;16L", "I"):
                arr = np.asarray(im).astype(np.float64) / 257.0
                im = Image.fromarray(np.clip(np.rint(arr), 0, 255).astype(np.uint8), "L")
            if im.mode in ("RGBA", "LA", "PA") or (im.mode == "P" and "transparency" in im.info):
                rgba = im.convert("RGBA")
                white = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
                im = Image.alpha_composite(white, rgba)
            rgb = np.asarray(im.convert("RGB"), dtype=np.uint8)
    except Image.DecompressionBombError as exc:
        raise DatasetError(f"{path.name}: supera --max-pixels={max_pixels}") from exc
    except OSError as exc:
        raise DatasetError(f"{path.name}: imagen ilegible: {exc}") from exc
    dpi_value = None
    if dpi and isinstance(dpi, tuple) and dpi[0]:
        dpi_value = round(float(dpi[0]), 3)
    return rgb, dpi_value


def render_pdf(path: Path, dpi: int, pages_spec: str | None, max_pixels: int
               ) -> Iterator[tuple[int, int, np.ndarray, dict]]:
    """Renderiza páginas del PDF. Yields (página_1based, total, rgb, info)."""
    import pymupdf  # PyMuPDF >= 1.24.3

    try:
        doc = pymupdf.open(path)
    except Exception as exc:  # PyMuPDF lanza tipos variados
        raise DatasetError(f"{path.name}: PDF ilegible: {exc}") from exc
    with doc:
        if doc.needs_pass:
            raise DatasetError(f"{path.name}: PDF protegido con contraseña")
        total = doc.page_count
        for index in parse_pages(pages_spec, total):
            page = doc[index]
            rect = page.rect
            expected = (rect.width * dpi / 72.0) * (rect.height * dpi / 72.0)
            if expected > max_pixels:
                raise DatasetError(
                    f"{path.name} p{index + 1}: {expected / 1e6:.0f} MP a {dpi} DPI supera "
                    f"--max-pixels; reducir --dpi")
            pix = page.get_pixmap(dpi=dpi, alpha=False, colorspace=pymupdf.csRGB)
            raw = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.stride)
            rgb = raw[:, : pix.width * pix.n].reshape(pix.height, pix.width, pix.n)[:, :, :3].copy()
            info = {"page_width_pt": round(rect.width, 3), "page_height_pt": round(rect.height, 3),
                    "rotation": page.rotation}
            yield index + 1, total, rgb, info


def collect_inputs(source: Path) -> list[Path]:
    if source.is_file():
        return [source]
    if source.is_dir():
        files = [p for p in sorted(source.iterdir())
                 if p.is_file() and p.suffix.lower() in RASTER_EXT | PDF_EXT]
        if not files:
            raise DatasetError(f"No hay PDF/PNG/JPG/TIFF en {source}")
        return files
    raise DatasetError(f"No existe {source}")


def import_plans(inputs: list[Path], *, project_id: str, source_type: str, output_dir: Path,
                 registry: Path, dpi: int = DEFAULT_DPI, pages: str | None = None,
                 plan_id: str | None = None, units: str = "unknown", overwrite: bool = False,
                 allow_duplicate: bool = False, max_pixels: int = DEFAULT_MAX_PIXELS) -> list[dict]:
    validate_id(project_id, "project_id")
    if source_type not in SOURCE_TYPES:
        raise DatasetError(f"source_type inválido {source_type!r}")
    if units not in UNITS:
        raise DatasetError(f"units inválido {units!r}")
    if not 36 <= dpi <= 1200:
        raise DatasetError("--dpi debe estar entre 36 y 1200")
    if plan_id is not None:
        validate_id(plan_id, "plan_id")
        if len(inputs) != 1:
            raise DatasetError("--plan-id solo puede usarse con un único archivo")

    rows, delimiter = read_registry(registry) if registry.exists() else ([], ",")
    by_id = {r["source_plan_id"]: r for r in rows}
    by_source = {(r.get("source_sha256"), r.get("source_page")): r["source_plan_id"] for r in rows}
    reg_dir = registry.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    new_rows: list[dict] = []
    seen_ids: set[str] = set()

    for src in inputs:
        suffix = src.suffix.lower()
        source_sha = sha256_file(src)
        base_id = plan_id or sanitize_id(src.stem)
        if suffix in PDF_EXT:
            items = ((f"{base_id}_p{page:03d}", str(page), rgb, info, float(dpi), "pdf_render")
                     for page, _total, rgb, info in render_pdf(src, dpi, pages, max_pixels))
        elif suffix in RASTER_EXT:
            rgb, header_dpi = raster_to_rgb(src, max_pixels)
            items = iter([(base_id, "", rgb, {}, header_dpi,
                           "file_header" if header_dpi else "unknown")])
        else:
            raise DatasetError(f"{src.name}: extensión no soportada")

        for pid, page, rgb, info, dpi_value, dpi_source in items:
            validate_id(pid, "source_plan_id")
            if pid in seen_ids:
                raise DatasetError(f"ID duplicado en esta importación: {pid} (renombrar archivos o usar --plan-id)")
            seen_ids.add(pid)
            dup = by_source.get((source_sha, page))
            if dup and dup != pid and not allow_duplicate:
                raise DatasetError(f"{src.name} (página {page or '-'}) ya está importado como {dup}; "
                                   "un duplicado con otro ID filtraría datos entre splits")
            if pid in by_id and not overwrite:
                raise DatasetError(f"{pid} ya existe en {registry.name}; usar --overwrite")
            target = output_dir / f"{pid}.png"
            data = write_png(target, rgb[:, :, ::-1])  # RGB → BGR para OpenCV
            row = {
                "source_plan_id": pid, "project_id": project_id, "source_type": source_type,
                "image": to_registry_path(reg_dir, target), "annotation": "",
                "units": units, "scale_verified": "false", "scale_px_per_unit": "",
                "dpi": "" if dpi_value is None else f"{dpi_value:g}", "dpi_source": dpi_source,
                "source_file": src.name, "source_page": page, "source_sha256": source_sha,
                "image_sha256": sha256_bytes(data), "width": rgb.shape[1], "height": rgb.shape[0],
                "notes": (f"pdf {info['page_width_pt']}x{info['page_height_pt']}pt rot={info['rotation']}"
                          if info else ""),
            }
            if pid in by_id:  # conservar anotación/escala cargadas manualmente
                for keep in ("annotation", "units", "scale_verified", "scale_px_per_unit", "notes"):
                    if by_id[pid].get(keep):
                        row[keep] = by_id[pid][keep]
            by_id[pid] = row
            new_rows.append(row)
            print(f"OK {src.name}{' p' + page if page else ''} -> {target.name} "
                  f"({rgb.shape[1]}x{rgb.shape[0]}, dpi={row['dpi'] or '?'} [{dpi_source}])")

    ordered_ids = list(dict.fromkeys([r["source_plan_id"] for r in rows] +
                                     [r["source_plan_id"] for r in new_rows]))
    ordered = [by_id[i] for i in ordered_ids]
    write_registry(registry, ordered, delimiter)
    print(f"Registro actualizado: {registry} ({len(ordered)} planos)")
    return new_rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Importa planos a PNG canónico y los registra en plans.csv.")
    ap.add_argument("--input", required=True, help="Archivo o carpeta (PDF, PNG, JPG, TIFF)")
    ap.add_argument("--project-id", required=True)
    ap.add_argument("--source-type", required=True, choices=SOURCE_TYPES)
    ap.add_argument("--output-dir", required=True, help="Carpeta de PNG canónicos (p. ej. work\\raw)")
    ap.add_argument("--registry", required=True, help="Ruta de plans.csv (se crea si no existe)")
    ap.add_argument("--dpi", type=int, default=DEFAULT_DPI, help=f"DPI de renderizado PDF (def. {DEFAULT_DPI})")
    ap.add_argument("--pages", help="Páginas PDF 1-based, p. ej. '1,3-4' (def. todas)")
    ap.add_argument("--plan-id", help="ID explícito (solo un archivo)")
    ap.add_argument("--units", default="unknown", choices=UNITS)
    ap.add_argument("--overwrite", action="store_true")
    ap.add_argument("--allow-duplicate", action="store_true",
                    help="Permitir el mismo archivo con otro ID (desaconsejado)")
    ap.add_argument("--max-pixels", type=int, default=DEFAULT_MAX_PIXELS)
    args = ap.parse_args(argv)
    try:
        import_plans(collect_inputs(Path(args.input)), project_id=args.project_id,
                     source_type=args.source_type, output_dir=Path(args.output_dir),
                     registry=Path(args.registry), dpi=args.dpi, pages=args.pages,
                     plan_id=args.plan_id, units=args.units, overwrite=args.overwrite,
                     allow_duplicate=args.allow_duplicate, max_pixels=args.max_pixels)
    except DatasetError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
