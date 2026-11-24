"""Exporta un checkpoint a ONNX (opset 17, entrada fija 1x3x512x512) y verifica
paridad numérica contra PyTorch con ONNX Runtime.

Escribe junto al .onnx un ``<nombre>.model.json`` con los metadatos que la app
móvil necesita (clases, tamaño, normalización, rejilla de tiles, hash) y la
procedencia del entrenamiento. ``--training-data`` es obligatorio para que nunca
se distribuya un modelo sin declarar si se entrenó con datos reales o sintéticos.

Uso (Windows):
    python -m core.export_onnx --checkpoint .\\runs\\vision_ai_0_1\\best.pt ^
        --output .\\runs\\vision_ai_0_1\\vision_ai.onnx --training-data real
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch

from .checkpoint import class_names, load_model

SIZE = 512


def export(checkpoint: str | Path, output: str | Path, *, training_data: str, opset: int = 17,
           model_id: str = "vision_ai", version: str = "0.1.0", notes: str = "") -> dict:
    model, ckpt = load_model(checkpoint, "cpu")
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    dummy = torch.rand(1, 3, SIZE, SIZE)
    torch.onnx.export(model, (dummy,), str(output), input_names=["image"], output_names=["logits"],
                      opset_version=opset, do_constant_folding=True, dynamo=False)
    parity = check_parity(model, output)
    data = output.read_bytes()
    meta = {
        "format": "structura-model/1",
        "id": model_id, "version": version, "task": "semantic_segmentation",
        "file": output.name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
        "input": {"name": "image", "shape": [1, 3, SIZE, SIZE], "dtype": "float32", "layout": "NCHW",
                  "color": "RGB", "scale": "x/255", "pad_value": 255},
        "output": {"name": "logits", "shape": [1, len(class_names(ckpt)), SIZE, SIZE]},
        "classes": class_names(ckpt),
        "tiling": {"tile": SIZE, "overlap": 64},
        "opset": opset,
        "training": {"data": training_data, "epoch": ckpt.get("epoch"), "val_miou": ckpt.get("val_miou"),
                     # Nunca se marca apto al exportar: requiere evaluación en test real y revisión.
                     "production_ready": False},
        "parity": parity, "notes": notes,
    }
    meta_path = output.with_suffix(".model.json")
    meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    return meta


@torch.no_grad()
def check_parity(model: torch.nn.Module, onnx_path: Path, samples: int = 3, seed: int = 0) -> dict:
    import onnxruntime as ort

    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(seed)
    max_abs, agree = 0.0, []
    for _ in range(samples):
        x = rng.random((1, 3, SIZE, SIZE), dtype=np.float32)
        ref = model(torch.from_numpy(x)).numpy()
        got = sess.run(["logits"], {"image": x})[0]
        max_abs = max(max_abs, float(np.abs(ref - got).max()))
        agree.append(float((ref.argmax(1) == got.argmax(1)).mean()))
    result = {"samples": samples, "max_abs_logit_diff": max_abs, "argmax_agreement_min": min(agree),
              "onnxruntime": ort.__version__}
    if max_abs > 1e-3 or min(agree) < 0.999:
        raise RuntimeError(f"Paridad PyTorch/ONNX insuficiente: {result}")
    return result


def main(argv: list[str] | None = None) -> None:
    from .io_utils import console_safe
    console_safe()
    ap = argparse.ArgumentParser(description="Exporta Vision AI a ONNX y verifica paridad.")
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--training-data", required=True, choices=["real", "synthetic", "untrained"],
                    help="Procedencia de los datos de entrenamiento (se graba en los metadatos)")
    ap.add_argument("--model-id", default="vision_ai")
    ap.add_argument("--version", default="0.1.0")
    ap.add_argument("--notes", default="")
    ap.add_argument("--opset", type=int, default=17)
    args = ap.parse_args(argv)
    meta = export(args.checkpoint, args.output, training_data=args.training_data, opset=args.opset,
                  model_id=args.model_id, version=args.version, notes=args.notes)
    print(f"ONNX exportado: {args.output} ({meta['bytes'] / 2**20:.1f} MB) — paridad {meta['parity']}")


if __name__ == "__main__":
    main()
