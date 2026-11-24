"""Carga de checkpoints y funciones de predicción reutilizables."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import torch

from .data import CLASS_NAMES
from .model import UNetSmall


def load_model(path: str | Path, device: torch.device | str = "cpu") -> tuple[UNetSmall, dict]:
    # weights_only=True: el checkpoint solo contiene tensores y tipos básicos.
    ckpt = torch.load(str(path), map_location=device, weights_only=True)
    model = UNetSmall(ckpt.get("num_classes", 6), ckpt.get("base", 16)).to(device)
    model.load_state_dict(ckpt["model"])
    model.eval()
    return model, ckpt


def torch_predict_fn(model: torch.nn.Module, device: torch.device, amp: bool = False):
    @torch.no_grad()
    def fn(batch: np.ndarray) -> np.ndarray:
        x = torch.from_numpy(batch).to(device)
        with torch.autocast(device.type, dtype=torch.float16, enabled=amp and device.type == "cuda"):
            logits = model(x)
        return logits.float().cpu().numpy()
    return fn


def class_names(ckpt: dict) -> list[str]:
    return list(ckpt.get("class_names") or CLASS_NAMES)
