"""Dataset de tiles generado por structura-data (images/, masks/, splits/*.txt).

Cambios respecto del prototipo: lectura Unicode-safe, split ``test``, validación
estricta de máscaras y aumentos reproducibles por worker.
"""
from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset

from .io_utils import read_mask, read_rgb

SIZE = 512
NUM_CLASSES = 6
CLASS_NAMES = ["background", "wall", "door", "window", "column", "stairs"]


def read_split(root: Path, split: str) -> list[str]:
    split_file = Path(root) / "splits" / f"{split}.txt"
    if not split_file.exists():
        raise FileNotFoundError(f"No existe {split_file}")
    ids = [x.strip() for x in split_file.read_text(encoding="utf-8-sig").splitlines() if x.strip()]
    if not ids:
        raise ValueError(f"El split {split} está vacío")
    return ids


def photometric(image: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Aumento fotométrico (no toca la máscara): papel, tinta, contraste, ruido, desenfoque
    y compresión JPEG, como en fotos o escaneos de planos. Opcional (--photometric-aug)."""
    img = image.astype(np.float32)
    if rng.random() < 0.8:  # contraste y brillo
        alpha = rng.uniform(0.75, 1.15)
        beta = rng.uniform(-25, 20)
        img = (img - 128) * alpha + 128 + beta
    if rng.random() < 0.3:  # gamma
        img = 255.0 * np.power(np.clip(img, 0, 255) / 255.0, rng.uniform(0.7, 1.4))
    if rng.random() < 0.2:  # tinte de papel por canal
        img = img * rng.uniform(0.9, 1.0, size=3)[None, None, :]
    if rng.random() < 0.5:  # ruido de sensor
        img = img + rng.normal(0, rng.uniform(2, 10), img.shape)
    img = np.clip(img, 0, 255).astype(np.uint8)
    if rng.random() < 0.2:
        img = cv2.GaussianBlur(img, (0, 0), rng.uniform(0.4, 1.2))
    if rng.random() < 0.25:
        ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, int(rng.integers(35, 90))])
        if ok:
            img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    return img


class PlanDataset(Dataset):
    def __init__(self, root, split: str = "train", augment: bool = False, size: int = SIZE,
                 num_classes: int = NUM_CLASSES, photometric_aug: bool = False):
        self.root = Path(root)
        self.augment = augment
        self.photometric_aug = photometric_aug
        self.size = size
        self.num_classes = num_classes
        self.ids = read_split(self.root, split)

    def __len__(self) -> int:
        return len(self.ids)

    def load(self, name: str) -> tuple[np.ndarray, np.ndarray]:
        image = read_rgb(self.root / "images" / f"{name}.png")
        mask = read_mask(self.root / "masks" / f"{name}.png")
        if image.shape[:2] != mask.shape:
            raise ValueError(f"{name}: imagen {image.shape[:2]} y máscara {mask.shape} difieren")
        if image.shape[:2] != (self.size, self.size):
            # Los tiles de structura-data ya miden 512; esto solo cubre datasets externos.
            image = cv2.resize(image, (self.size, self.size), interpolation=cv2.INTER_AREA)
            mask = cv2.resize(mask, (self.size, self.size), interpolation=cv2.INTER_NEAREST)
        if int(mask.max()) >= self.num_classes:
            raise ValueError(f"Máscara {name}: IDs fuera del rango 0..{self.num_classes - 1}")
        return image, mask

    def __getitem__(self, idx: int):
        image, mask = self.load(self.ids[idx])
        if self.augment:
            # Planos: invariantes a espejos y rotaciones de 90°.
            if np.random.rand() < 0.5:
                image, mask = np.fliplr(image), np.fliplr(mask)
            if np.random.rand() < 0.5:
                image, mask = np.flipud(image), np.flipud(mask)
            k = np.random.randint(0, 4)
            image, mask = np.rot90(image, k), np.rot90(mask, k)
            if self.photometric_aug:
                image = photometric(np.ascontiguousarray(image), np.random.default_rng(np.random.randint(0, 2**31)))
        image = np.ascontiguousarray(image.transpose(2, 0, 1), dtype=np.float32) / 255.0
        mask = np.ascontiguousarray(mask, dtype=np.int64)
        return torch.from_numpy(image), torch.from_numpy(mask)


def class_pixel_frequencies(root, split: str = "train", num_classes: int = NUM_CLASSES) -> list[float]:
    """Frecuencia de píxeles por clase en un split. Usa ``metadata/<tile>.json``
    (``class_pixel_counts`` de structura-data); si falta, cuenta en las máscaras."""
    import json

    root = Path(root)
    counts = np.zeros(num_classes, dtype=np.float64)
    for name in read_split(root, split):
        meta = root / "metadata" / f"{name}.json"
        c = None
        if meta.exists():
            c = json.loads(meta.read_text(encoding="utf-8")).get("class_pixel_counts")
        if c is None:
            c = np.bincount(read_mask(root / "masks" / f"{name}.png").ravel(), minlength=num_classes)
        counts[:len(c)] += np.asarray(c[:num_classes], dtype=np.float64)
    total = counts.sum()
    return (counts / total).tolist() if total else [0.0] * num_classes


def enet_class_weights(freqs: list[float], c: float = 1.02) -> list[float]:
    """Pesos ENet ``w = 1 / ln(c + f)`` (propuesta B de docs/EVALUACION_LOSS.md)."""
    import math

    return [1.0 / math.log(c + f) for f in freqs]


def worker_init_fn(worker_id: int) -> None:
    """Semilla distinta y reproducible por worker de DataLoader."""
    seed = torch.initial_seed() % 2**32
    np.random.seed((seed + worker_id) % 2**32)
