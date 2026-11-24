"""Construye un proyecto sintético completo y ejecuta el pipeline de punta a punta.

    incoming/ (PNG, JPG, PDF) → import_plans → work/raw + plans.csv
    → LabelMe JSON (annotations/) → build_dataset → dataset/

Incluye a propósito: planos menores y mayores que el tile, tamaños no múltiplos
del paso, un plano desde PDF, uno desde JPG, proyectos con varios planos, un
plano marcado ``needs_review`` (debe excluirse) y uno sin anotar (pendiente).

Uso (Windows), para inspeccionar el resultado o abrirlo en LabelMe:
    python -m tests.synthetic_demo --output .\\demo_sintetico
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

import numpy as np

from tests.synthetic import make_plan, write_labelme, write_png_unicode
from tools.build_dataset import build_dataset
from tools.import_plans import collect_inputs, import_plans

SIZES = [(300, 260), (512, 512), (513, 700), (1100, 900), (1500, 1234), (800, 600),
         (960, 961), (700, 540), (640, 480), (1024, 700), (450, 900)]
PROJECTS = {  # project_id → [(nombre de archivo, formato)]
    "proj_01": [("casa_01_planta_baja", "png"), ("casa_01_planta_alta", "png")],
    "proj_02": [("casa_02_pb", "png"), ("casa_02_pa", "png")],
    "proj_03": [("duplex_03_a", "png"), ("duplex_03_b", "png")],
    "proj_04": [("vivienda_04", "pdf")],
    "proj_05": [("escaneo_05", "jpg")],
    "proj_06": [("casa_06", "png")],
    "proj_07": [("casa_07", "png"), ("casa_07_sin_anotar", "png")],
    "proj_08": [("casa_08", "png"), ("casa_08_dudoso", "png")],
}
PDF_DPI = 144


def _write_pdf(path: Path, image_bgr: np.ndarray) -> None:
    """PDF cuya página contiene la imagen a 72 pt por cada 2 px (144 DPI exactos)."""
    import pymupdf

    h, w = image_bgr.shape[:2]
    tmp = path.with_suffix(".tmp.png")
    write_png_unicode(tmp, image_bgr)
    doc = pymupdf.open()
    page = doc.new_page(width=w * 72 / PDF_DPI, height=h * 72 / PDF_DPI)
    page.insert_image(page.rect, filename=str(tmp))
    doc.save(str(path))
    doc.close()
    tmp.unlink()


def build_synthetic_project(root: Path, *, seed: int = 0, run_pipeline: bool = True) -> dict:
    root.mkdir(parents=True, exist_ok=True)
    incoming, work, ann = root / "incoming", root / "work", root / "annotations"
    registry = work / "plans.csv"
    expected: dict[str, np.ndarray] = {}
    k = 0
    for project, files in PROJECTS.items():
        folder = incoming / project
        for name, fmt in files:
            w, h = SIZES[k % len(SIZES)]
            plan = make_plan(w, h, seed=seed + k)
            k += 1
            if fmt == "png":
                write_png_unicode(folder / f"{name}.png", plan.image)
            elif fmt == "jpg":
                write_png_unicode(folder / f"{name}.jpg", plan.image, ".jpg")
            else:
                _write_pdf(folder / f"{name}.pdf", plan.image)
            plan_id = f"{name}_p001" if fmt == "pdf" else name
            expected[plan_id] = plan.expected
            if "sin_anotar" not in name:
                flags = {"needs_review": "dudoso" in name, "partial": False}
                write_labelme(ann / f"{plan_id}.json", f"..\\work\\raw\\{plan_id}.png", plan, flags)
        import_plans(collect_inputs(folder), project_id=project,
                     source_type="scanned" if files[0][1] == "jpg" else "digital",
                     output_dir=work / "raw", registry=registry, dpi=PDF_DPI)
    info = {"root": root, "registry": registry, "annotations": ann, "work": work,
            "dataset": root / "dataset", "expected": expected}
    if run_pipeline:
        info["manifest"] = build_dataset(registry, ann, work, root / "dataset", seed=42)
    return info


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Genera y procesa un dataset sintético de prueba.")
    ap.add_argument("--output", required=True)
    ap.add_argument("--overwrite", action="store_true")
    args = ap.parse_args(argv)
    out = Path(args.output)
    if out.exists() and any(out.iterdir()):
        if not args.overwrite:
            print(f"ERROR: {out} no está vacío; usar --overwrite", file=sys.stderr)
            return 1
        shutil.rmtree(out)
    info = build_synthetic_project(out)
    m = info["manifest"]
    print(f"\nPlanos incluidos: {len(m['plans_included'])}; pendientes: {m['plans_pending_annotation']}; "
          f"needs_review: {m['plans_needs_review']}")
    print(f"Dataset: {info['dataset']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
