"""Generador de planos sintéticos con anotación LabelMe y máscara esperada.

Cada plano contiene: muros exteriores y un tabique, una ventana integrada en el
muro superior, una puerta con vano/hoja/arco en el tabique, una columna, una
escalera y una línea de cota con texto (que NO se etiqueta: debe quedar como
background).

Todas las formas usan coordenadas enteras alineadas a ejes, de modo que la
máscara esperada se calcula de forma independiente con slicing de NumPy
(bordes incluidos, igual que LabelMe/PIL). En el JSON, puerta y ventana se
escriben ANTES que los muros: con la política "order" de v0.2 desaparecerían;
con "priority" deben prevalecer.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

CLASS_IDS = {"wall": 1, "door": 2, "window": 3, "column": 4, "stairs": 5}
PRIORITY = ["wall", "stairs", "column", "window", "door"]


@dataclass
class SynthPlan:
    image: np.ndarray                      # BGR uint8
    shapes: list[dict] = field(default_factory=list)
    expected: np.ndarray | None = None     # máscara esperada (prioridad)

    @property
    def height(self) -> int:
        return self.image.shape[0]

    @property
    def width(self) -> int:
        return self.image.shape[1]


def _rect_shape(label: str, x1: int, y1: int, x2: int, y2: int, as_polygon: bool = False) -> dict:
    if as_polygon:
        pts = [[x1, y1], [x2, y1], [x2, y2], [x1, y2]]
        kind = "polygon"
    else:
        pts = [[x1, y1], [x2, y2]]
        kind = "rectangle"
    return {"label": label, "points": [[float(a), float(b)] for a, b in pts], "group_id": None,
            "description": "", "shape_type": kind, "flags": {}, "mask": None}


def expected_mask(width: int, height: int, shapes: list[dict]) -> np.ndarray:
    """Máscara esperada calculada sin OpenCV (solo rectángulos alineados)."""
    mask = np.zeros((height, width), np.uint8)
    for label in PRIORITY:
        for s in shapes:
            if s["label"] != label:
                continue
            xs = [int(p[0]) for p in s["points"]]
            ys = [int(p[1]) for p in s["points"]]
            x1, x2 = max(0, min(xs)), min(width - 1, max(xs))
            y1, y2 = max(0, min(ys)), min(height - 1, max(ys))
            mask[y1:y2 + 1, x1:x2 + 1] = CLASS_IDS[label]
    return mask


def make_plan(width: int, height: int, seed: int = 0, wall: int = 12) -> SynthPlan:
    rng = np.random.default_rng(seed)
    img = np.full((height, width, 3), 255, np.uint8)
    m = int(rng.integers(16, 30))
    x0, y0, x1, y1 = m, m, width - m - 1, height - m - 1
    t = wall
    walls = [(x0, y0, x1, y0 + t - 1), (x0, y1 - t + 1, x1, y1),
             (x0, y0, x0 + t - 1, y1), (x1 - t + 1, y0, x1, y1)]
    xv = x0 + (x1 - x0) // 2 + int(rng.integers(-10, 10))
    walls.append((xv, y0, xv + t - 1, y1))
    for (a, b, c, d) in walls:
        img[b:d + 1, a:c + 1] = 0

    shapes: list[dict] = []
    # Ventana integrada en el muro superior: símbolo de dos líneas dentro del espesor.
    wl = min(60, max(20, (xv - x0) // 3))
    wx = x0 + t + 8
    window = (wx, y0, wx + wl - 1, y0 + t - 1)
    img[window[1]:window[3] + 1, window[0]:window[2] + 1] = 255
    cv2.rectangle(img, (window[0], window[1]), (window[2], window[3]), (0, 0, 0), 1)
    cv2.line(img, (window[0], y0 + t // 2), (window[2], y0 + t // 2), (0, 0, 0), 1)
    shapes.append(_rect_shape("window", *window))

    # Puerta en el tabique: se dibujan vano + hoja + arco, pero según el manual
    # (convención propuesta) solo se etiqueta el VANO dentro del espesor del muro.
    dl = min(48, max(16, (y1 - y0) // 4))
    yd = y0 + t + 10
    img[yd:yd + dl, xv:xv + t] = 255
    cv2.line(img, (xv + t, yd), (xv + t + dl - 1, yd), (0, 0, 0), 2)
    cv2.ellipse(img, (xv + t, yd), (dl - 1, dl - 1), 0, 0, 90, (0, 0, 0), 1)
    door = (xv, yd, xv + t - 1, yd + dl - 1)
    shapes.append(_rect_shape("door", *door))

    # Muros (después de puerta/ventana en el JSON a propósito). Algunos como polígono.
    for i, w in enumerate(walls):
        shapes.append(_rect_shape("wall", *w, as_polygon=(i % 2 == 1)))

    # Columna adosada al muro inferior (se solapa con wall: solape esperado).
    cs = 18
    cx, cy = x0 + t + 20, y1 - t - cs + 4
    img[cy:cy + cs, cx:cx + cs] = 60
    shapes.append(_rect_shape("column", cx, cy, cx + cs - 1, cy + cs - 1))

    # Escalera en el ambiente derecho.
    sw, sh = min(70, max(20, (x1 - xv) // 3)), min(110, max(30, (y1 - y0) // 3))
    sx, sy = x1 - t - sw - 10, y1 - t - sh - 10
    if sx > xv + t + 5 and sy > y0 + t + 5:
        cv2.rectangle(img, (sx, sy), (sx + sw - 1, sy + sh - 1), (0, 0, 0), 1)
        for yy in range(sy, sy + sh, 10):
            cv2.line(img, (sx, yy), (sx + sw - 1, yy), (0, 0, 0), 1)
        shapes.append(_rect_shape("stairs", sx, sy, sx + sw - 1, sy + sh - 1))

    # Cota + texto: background por convención (no se etiqueta).
    if m >= 18:
        cv2.line(img, (x0, m // 2), (x1, m // 2), (90, 90, 90), 1)
        cv2.putText(img, "4.50", ((x0 + x1) // 2, m // 2 - 2), cv2.FONT_HERSHEY_PLAIN, 0.6, (90, 90, 90), 1)

    plan = SynthPlan(img, shapes)
    plan.expected = expected_mask(width, height, shapes)
    return plan


def labelme_json(image_path: str, width: int, height: int, shapes: list[dict],
                 flags: dict | None = None) -> dict:
    return {"version": "5.5.0", "flags": flags or {}, "shapes": shapes, "imagePath": image_path,
            "imageData": None, "imageHeight": height, "imageWidth": width}


def write_labelme(path: Path, image_path: str, plan: SynthPlan, flags: dict | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(labelme_json(image_path, plan.width, plan.height, plan.shapes, flags),
                               indent=2), encoding="utf-8")


def write_png_unicode(path: Path, array: np.ndarray, ext: str = ".png") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ok, buf = cv2.imencode(ext, array)
    assert ok
    path.write_bytes(buf.tobytes())
