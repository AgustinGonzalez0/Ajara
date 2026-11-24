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


class PlanDataset(Dataset):
    def __init__(self, root, split: str = "train", augment: bool = False, size: int = SIZE,
                 num_classes: int = NUM_CLASSES):
        self.root = Path(root)
        self.augment = augment
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
        image = np.ascontiguousarray(image.transpose(2, 0, 1), dtype=np.float32) / 255.0
        mask = np.ascontiguousarray(mask, dtype=np.int64)
        return torch.from_numpy(image), torch.from_numpy(mask)


def worker_init_fn(worker_id: int) -> None:
    """Semilla distinta y reproducible por worker de DataLoader."""
    seed = torch.initial_seed() % 2**32
    np.random.seed((seed + worker_id) % 2**32)
