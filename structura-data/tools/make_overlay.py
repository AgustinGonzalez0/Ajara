"""Superpone una máscara de IDs sobre su imagen para revisión visual (control de calidad).

Usa la misma paleta que core/predict.py, de modo que anotaciones y predicciones
se comparan con los mismos colores (RGB): background gris oscuro, wall rojo,
door verde, window azul, column amarillo, stairs violeta.

Uso (Windows):
    python -m tools.make_overlay --image .\\work\\raw\\plan_001.png --mask .\\work\\masks\\plan_001.png ^
        --output .\\review\\plan_001_overlay.png
    python -m tools.make_overlay --image-dir .\\work\\raw --mask-dir .\\work\\masks --output .\\review
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import cv2
import numpy as np

from .common import DatasetError, load_mask, load_plan_image, write_png

PALETTE_RGB = np.array([[20, 20, 20], [220, 60, 60], [60, 180, 75],
                        [65, 105, 225], [245, 190, 50], [170, 80, 190]], dtype=np.uint8)


def overlay(image_bgr: np.ndarray, mask: np.ndarray, alpha: float = 0.45) -> np.ndarray:
    if image_bgr.shape[:2] != mask.shape:
        raise DatasetError("imagen y máscara con dimensiones distintas")
    if int(mask.max()) >= len(PALETTE_RGB):
        raise DatasetError(f"ID de clase {int(mask.max())} sin color en la paleta")
    color = PALETTE_RGB[mask][:, :, ::-1]
    blended = cv2.addWeighted(image_bgr, 1 - alpha, color, alpha, 0)
    return np.where((mask > 0)[:, :, None], blended, image_bgr)  # el fondo queda intacto


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Genera overlays máscara/imagen para revisión.")
    ap.add_argument("--image")
    ap.add_argument("--mask")
    ap.add_argument("--image-dir")
    ap.add_argument("--mask-dir")
    ap.add_argument("--output", required=True, help="Archivo PNG (modo único) o carpeta (modo carpeta)")
    ap.add_argument("--alpha", type=float, default=0.45)
    args = ap.parse_args(argv)
    try:
        if args.image and args.mask:
            pairs = [(Path(args.image), Path(args.mask), Path(args.output))]
        elif args.image_dir and args.mask_dir:
            out = Path(args.output)
            pairs = [(Path(args.image_dir) / m.name, m, out / f"{m.stem}_overlay.png")
                     for m in sorted(Path(args.mask_dir).glob("*.png"))]
        else:
            raise DatasetError("indicar --image y --mask, o --image-dir y --mask-dir")
        for img_path, mask_path, target in pairs:
            write_png(target, overlay(load_plan_image(img_path), load_mask(mask_path), args.alpha))
            print(f"OK {target}")
    except (DatasetError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
