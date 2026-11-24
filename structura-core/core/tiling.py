"""Inferencia por tiles para planos de cualquier tamaño.

Usa la MISMA rejilla que structura-data (tile 512, overlap 64, último tile
alineado al borde, relleno blanco), de modo que el modelo ve en inferencia
exactamente el tipo de recorte con el que se entrenó.

Recomposición: se acumulan probabilidades (softmax) ponderadas por una ventana
que reduce el peso de los bordes de cada tile (donde el contexto es menor) y se
toma argmax. Las zonas de relleno nunca se copian al resultado.

``predict_fn`` recibe un lote float32 (N,3,T,T) normalizado a [0,1] y devuelve
logits (N,C,T,T) como numpy; así sirve igual para PyTorch y ONNX Runtime.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

import numpy as np

PredictFn = Callable[[np.ndarray], np.ndarray]


def tile_starts(length: int, tile: int, stride: int) -> list[int]:
    if length <= tile:
        return [0]
    values = list(range(0, length - tile + 1, stride))
    if values[-1] != length - tile:
        values.append(length - tile)
    return values


def blend_window(tile: int, overlap: int) -> np.ndarray:
    """Peso 1 en el centro, rampa lineal (mín. 0.1) en las franjas de solape."""
    w = np.ones(tile, np.float32)
    if overlap > 0:
        ramp = np.linspace(0.1, 1.0, overlap, dtype=np.float32)
        w[:overlap] = ramp
        w[-overlap:] = ramp[::-1]
    return np.outer(w, w)


@dataclass
class TiledResult:
    labels: np.ndarray        # (H,W) uint8
    confidence: np.ndarray    # (H,W) float32, probabilidad de la clase elegida
    num_tiles: int


def predict_tiled(rgb: np.ndarray, predict_fn: PredictFn, num_classes: int, *, tile: int = 512,
                  overlap: int = 64, batch_size: int = 4) -> TiledResult:
    if rgb.ndim != 3 or rgb.shape[2] != 3 or rgb.dtype != np.uint8:
        raise ValueError("rgb debe ser uint8 HxWx3")
    if not 0 <= overlap < tile:
        raise ValueError("se requiere 0 <= overlap < tile")
    h, w = rgb.shape[:2]
    stride = tile - overlap
    coords = [(x, y) for y in tile_starts(h, tile, stride) for x in tile_starts(w, tile, stride)]
    acc = np.zeros((num_classes, h, w), np.float32)
    weight = np.zeros((h, w), np.float32)
    window = blend_window(tile, overlap)

    for i in range(0, len(coords), batch_size):
        chunk = coords[i:i + batch_size]
        batch = np.full((len(chunk), tile, tile, 3), 255, np.uint8)  # relleno blanco
        for j, (x, y) in enumerate(chunk):
            crop = rgb[y:y + tile, x:x + tile]
            batch[j, :crop.shape[0], :crop.shape[1]] = crop
        x_in = batch.transpose(0, 3, 1, 2).astype(np.float32) / 255.0
        logits = np.asarray(predict_fn(x_in), dtype=np.float32)
        if logits.shape != (len(chunk), num_classes, tile, tile):
            raise ValueError(f"predict_fn devolvió {logits.shape}")
        logits -= logits.max(axis=1, keepdims=True)
        probs = np.exp(logits)
        probs /= probs.sum(axis=1, keepdims=True)
        for j, (x, y) in enumerate(chunk):
            ch, cw = min(tile, h - y), min(tile, w - x)
            wv = window[:ch, :cw]
            acc[:, y:y + ch, x:x + cw] += probs[j, :, :ch, :cw] * wv
            weight[y:y + ch, x:x + cw] += wv

    probs_full = acc / np.maximum(weight, 1e-6)
    labels = probs_full.argmax(axis=0).astype(np.uint8)
    confidence = np.take_along_axis(probs_full, labels[None].astype(np.int64), axis=0)[0]
    return TiledResult(labels, confidence.astype(np.float32), len(coords))
