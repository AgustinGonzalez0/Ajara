"""E/S de imágenes compatible con rutas Unicode en Windows y utilidades de reproducibilidad.

``cv2.imread``/``cv2.imwrite`` fallan con rutas que contienen caracteres como
``ñ`` en Windows; aquí se usa ``imdecode``/``imencode`` sobre bytes.
"""
from __future__ import annotations

import os
import random
from pathlib import Path

import cv2
import numpy as np


def imread(path: str | os.PathLike, flags: int = cv2.IMREAD_COLOR) -> np.ndarray | None:
    p = Path(path)
    if not p.is_file():
        return None
    data = p.read_bytes()
    if not data:
        return None
    return cv2.imdecode(np.frombuffer(data, np.uint8), flags)


def imwrite(path: str | os.PathLike, image: np.ndarray) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    ok, buf = cv2.imencode(p.suffix or ".png", image)
    if not ok:
        raise OSError(f"No se pudo codificar {p}")
    tmp = p.with_name(f".{p.name}.tmp")
    tmp.write_bytes(buf.tobytes())
    os.replace(tmp, p)


def read_rgb(path: str | os.PathLike) -> np.ndarray:
    """Lee una imagen como RGB uint8 HxWx3 (gris → RGB, alfa → compuesto sobre blanco)."""
    img = imread(path, cv2.IMREAD_UNCHANGED)
    if img is None:
        raise FileNotFoundError(f"Imagen ilegible o inexistente: {path}")
    if img.dtype != np.uint8:
        raise ValueError(f"{path}: profundidad {img.dtype} no soportada (convertir con structura-data)")
    if img.ndim == 2:
        return cv2.cvtColor(img, cv2.COLOR_GRAY2RGB)
    if img.shape[2] == 4:
        alpha = img[:, :, 3:4].astype(np.float32) / 255.0
        bgr = img[:, :, :3].astype(np.float32) * alpha + 255.0 * (1.0 - alpha)
        img = np.clip(np.rint(bgr), 0, 255).astype(np.uint8)
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)


def read_mask(path: str | os.PathLike) -> np.ndarray:
    mask = imread(path, cv2.IMREAD_UNCHANGED)
    if mask is None:
        raise FileNotFoundError(f"Máscara ilegible o inexistente: {path}")
    if mask.ndim != 2 or mask.dtype != np.uint8:
        raise ValueError(f"{path}: la máscara debe ser PNG de un canal uint8; es {mask.shape} {mask.dtype}")
    return mask


def set_seed(seed: int, deterministic: bool = False) -> None:
    """Fija semillas de Python, NumPy y PyTorch. ``deterministic`` desactiva
    algoritmos no deterministas de cuDNN (más lento)."""
    import torch

    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.benchmark = not deterministic
    torch.backends.cudnn.deterministic = deterministic


def console_safe() -> None:
    """Evita UnicodeEncodeError al imprimir acentos/símbolos en consolas Windows
    con codificación cp1252/cp850 o salida redirigida."""
    import sys

    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except (AttributeError, ValueError):
            pass
