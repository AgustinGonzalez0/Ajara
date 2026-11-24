"""Inferencia por tiles con ONNX Runtime (CPU), equivalente a core.predict.

Uso (Windows):
    python -m core.predict_onnx --model .\\runs\\vision_ai_0_1\\vision_ai.onnx --input .\\plano.png --output .\\pred_onnx
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np

from .io_utils import read_rgb
from .predict import save_outputs
from .tiling import predict_tiled


def onnx_predict_fn(session):
    def fn(batch: np.ndarray) -> np.ndarray:
        # El modelo exportado tiene batch fijo 1 (formato pensado para móvil).
        return np.concatenate([session.run(["logits"], {"image": batch[i:i + 1]})[0]
                               for i in range(batch.shape[0])], axis=0)
    return fn


def main(argv: list[str] | None = None) -> None:
    from .io_utils import console_safe
    console_safe()
    import onnxruntime as ort

    ap = argparse.ArgumentParser(description="Inferencia por tiles (ONNX Runtime).")
    ap.add_argument("--model", required=True)
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--overlap", type=int, default=64)
    args = ap.parse_args(argv)
    meta_path = Path(args.model).with_suffix(".model.json")
    meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
    classes = meta.get("classes") or ["background", "wall", "door", "window", "column", "stairs"]
    session = ort.InferenceSession(args.model, providers=["CPUExecutionProvider"])
    rgb = read_rgb(args.input)
    t0 = time.perf_counter()
    res = predict_tiled(rgb, onnx_predict_fn(session), len(classes), overlap=args.overlap)
    elapsed = time.perf_counter() - t0
    info = {"input": str(args.input), "size": [rgb.shape[1], rgb.shape[0]], "tiles": res.num_tiles,
            "seconds": round(elapsed, 3), "runtime": f"onnxruntime {ort.__version__} CPU",
            "class_names": classes, "model_training": meta.get("training")}
    save_outputs(Path(args.output), rgb, res.labels, res.confidence, info)
    print(f"{res.num_tiles} tiles en {elapsed:.2f}s -> {args.output}")


if __name__ == "__main__":
    main()
