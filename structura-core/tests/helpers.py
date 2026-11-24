from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

from core.io_utils import imwrite
from core.model import UNetSmall


class TempDirCase(unittest.TestCase):
    def setUp(self) -> None:
        base = Path(tempfile.mkdtemp(prefix="structura_core_"))
        self.root = base / "carpeta año ñ"
        self.root.mkdir()
        self.addCleanup(shutil.rmtree, base, ignore_errors=True)


def make_tile_dataset(root: Path, n_train: int = 4, n_val: int = 2, n_test: int = 2, size: int = 512,
                      seed: int = 0) -> Path:
    """Dataset mínimo con el formato de structura-data: muros oscuros = clase 1, puertas = 2."""
    rng = np.random.default_rng(seed)
    splits = {"train": n_train, "validation": n_val, "test": n_test}
    for split, n in splits.items():
        ids = []
        for i in range(n):
            name = f"{split}_{i:03d}"
            img = np.full((size, size, 3), 255, np.uint8)
            mask = np.zeros((size, size), np.uint8)
            for _ in range(4):
                x, y = rng.integers(0, size - 60, 2)
                if rng.random() < 0.5:
                    img[y:y + 10, x:x + 60] = 0
                    mask[y:y + 10, x:x + 60] = 1
                else:
                    img[y:y + 60, x:x + 10] = 0
                    mask[y:y + 60, x:x + 10] = 1
            img[20:30, 200:230] = 160
            mask[20:30, 200:230] = 2
            imwrite(root / "images" / f"{name}.png", img)
            imwrite(root / "masks" / f"{name}.png", mask)
            ids.append(name)
        (root / "splits").mkdir(parents=True, exist_ok=True)
        (root / "splits" / f"{split}.txt").write_text("\n".join(ids) + "\n", encoding="utf-8")
    return root


def save_random_checkpoint(path: Path, seed: int = 0) -> Path:
    torch.manual_seed(seed)
    model = UNetSmall(6, 16)
    torch.save({"model": model.state_dict(), "num_classes": 6, "base": 16, "epoch": 0,
                "class_names": ["background", "wall", "door", "window", "column", "stairs"]}, path)
    return path
