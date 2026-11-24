"""Inferencia por tiles con PyTorch sobre un plano de cualquier tamaño.

Genera ``mask.png`` (IDs 0..5, mismo tamaño que la entrada), ``confidence.png``
(0..255) y ``overlay.png``. Antes el prototipo reducía todo el plano a 512×512,
lo que borraba los muros finos en planos grandes.

Uso (Windows):
    python -m core.predict --model .\\runs\\vision_ai_0_1\\best.pt --input .\\plano.png --output .\\pred
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import cv2
import numpy as np

from .io_utils import imwrite, read_rgb
from .tiling import predict_tiled

PALETTE = np.array([[20, 20, 20], [220, 60, 60], [60, 180, 75],
                    [65, 105, 225], [245, 190, 50], [170, 80, 190]], dtype=np.uint8)


def save_outputs(out: Path, rgb: np.ndarray, labels: np.ndarray, confidence: np.ndarray, info: dict) -> None:
    out.mkdir(parents=True, exist_ok=True)
    imwrite(out / "mask.png", labels)
    imwrite(out / "confidence.png", np.clip(confidence * 255, 0, 255).astype(np.uint8))
    color = PALETTE[labels]
    blended = cv2.addWeighted(rgb, 0.55, color, 0.45, 0)
    overlay = np.where((labels > 0)[:, :, None], blended, rgb)
    imwrite(out / "overlay.png", cv2.cvtColor(overlay, cv2.COLOR_RGB2BGR))
    (out / "prediction.json").write_text(json.dumps(info, indent=2, ensure_ascii=False), encoding="utf-8")


def main(argv: list[str] | None = None) -> None:
    from .io_utils import console_safe
    console_safe()
    import torch

    from .checkpoint import class_names, load_model, torch_predict_fn
    from .train import pick_device

    ap = argparse.ArgumentParser(description="Inferencia por tiles (PyTorch).")
    ap.add_argument("--model", required=True)
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--tile", type=int, default=512)
    ap.add_argument("--overlap", type=int, default=64)
    ap.add_argument("--device", choices=["auto", "cuda", "cpu"], default="auto")
    args = ap.parse_args(argv)
    device = pick_device(args.device)
    model, ckpt = load_model(args.model, device)
    rgb = read_rgb(args.input)
    t0 = time.perf_counter()
    res = predict_tiled(rgb, torch_predict_fn(model, device, amp=True), len(class_names(ckpt)),
                        tile=args.tile, overlap=args.overlap)
    if device.type == "cuda":
        torch.cuda.synchronize()
    elapsed = time.perf_counter() - t0
    info = {"input": str(args.input), "size": [rgb.shape[1], rgb.shape[0]], "tiles": res.num_tiles,
            "seconds": round(elapsed, 3), "device": str(device), "class_names": class_names(ckpt),
            "class_pixels": np.bincount(res.labels.ravel(), minlength=len(class_names(ckpt))).tolist()}
    save_outputs(Path(args.output), rgb, res.labels, res.confidence, info)
    print(f"{res.num_tiles} tiles en {elapsed:.2f}s -> {args.output}")


if __name__ == "__main__":
    main()
