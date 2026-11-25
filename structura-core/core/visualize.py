"""Corre Vision AI sobre imágenes SIN etiquetas (fotos, escaneos, planos de terceros) y
guarda una vista lado a lado para revisión humana.

Escala automática: el modelo aprendió con muros de ~6–17 px. Se estima el espesor de los
trazos más gruesos (percentil 95 de 2·distancia al borde sobre la tinta) y se reescala para
llevarlo a ``--target-wall`` px antes de inferir; la predicción vuelve al tamaño original.

Uso::

    python -m core.visualize --checkpoint ../data/runs/vec_v1_ce/best.pt --input ../data/external/commons_plans/images \
        --output ../data/runs/commons_preview
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np
import torch

from .checkpoint import load_model, torch_predict_fn
from .data import NUM_CLASSES
from .io_utils import console_safe, read_rgb
from .tiling import predict_tiled

PALETTE_BGR = np.array([[0, 0, 0], [40, 40, 230], [40, 180, 40], [230, 140, 0], [200, 0, 200], [0, 200, 230]], np.uint8)


def stroke_width(rgb: np.ndarray) -> float:
    """Espesor de los trazos gruesos (px): percentil 95 de 2·distancia al fondo sobre la tinta."""
    g = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    _, ink = cv2.threshold(g, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    d = cv2.distanceTransform(ink, cv2.DIST_L2, 3)
    v = d[ink > 0]
    return float(2 * np.percentile(v, 95)) if v.size > 100 else 0.0


def main(argv: list[str] | None = None) -> None:
    console_safe()
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--target-wall", type=float, default=10.0)
    ap.add_argument("--no-autoscale", action="store_true")
    a = ap.parse_args(argv)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model, _ = load_model(a.checkpoint, device)
    fn = torch_predict_fn(model, device, amp=device.type == "cuda")
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    report = []
    files = sorted(p for p in Path(a.input).iterdir() if p.suffix.lower() in (".png", ".jpg", ".jpeg"))
    for p in files:
        rgb = read_rgb(p)
        h, w = rgb.shape[:2]
        sw = stroke_width(rgb)
        f = 1.0 if a.no_autoscale or sw <= 0 else float(np.clip(a.target_wall / sw, 0.35, 3.0))
        if max(h, w) * f > 4096:
            f = 4096 / max(h, w)
        small = cv2.resize(rgb, (max(1, int(w * f)), max(1, int(h * f))), interpolation=cv2.INTER_AREA if f < 1 else cv2.INTER_CUBIC)
        pred = predict_tiled(small, fn, NUM_CLASSES, batch_size=8).labels
        pred = cv2.resize(pred, (w, h), interpolation=cv2.INTER_NEAREST)
        counts = np.bincount(pred.ravel(), minlength=NUM_CLASSES)
        bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
        over = (255 - (255 - bgr) * 0.4).astype(np.uint8)
        m = pred > 0
        over[m] = PALETTE_BGR[pred[m]]
        both = np.concatenate([bgr, over], axis=1)
        sc = min(1.0, 1800 / both.shape[1])
        cv2.imwrite(str(out / f"{p.stem}.jpg"), cv2.resize(both, None, fx=sc, fy=sc, interpolation=cv2.INTER_AREA),
                    [cv2.IMWRITE_JPEG_QUALITY, 85])
        report.append({"file": p.name, "stroke_px": round(sw, 1), "scale": round(f, 3),
                       "fraction": [round(c / pred.size, 4) for c in counts.tolist()]})
    (out / "report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    print(f"{len(report)} imágenes → {out}")


if __name__ == "__main__":
    main()
