"""Cuantización INT8 estática (QDQ) de un modelo ONNX para celulares modestos.

* Calibración con tiles reales del dataset (split train), no con ruido.
* Mide el acuerdo de argmax y el mIoU relativo frente al modelo FP32 en un split.
* Escribe `<salida>.model.json` heredando la procedencia del modelo original y
  agregando `quantization` con las métricas medidas.

Uso (Windows):
    python -m core.quantize --model ..\\data\\runs\\x\\vision_ai.onnx --dataset ..\\data\\dataset ^
        --output ..\\data\\runs\\x\\vision_ai_int8.onnx
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from .data import PlanDataset


class _TileReader:
    """Lector de calibración para onnxruntime.quantization."""

    def __init__(self, dataset: PlanDataset, limit: int):
        self.items = [dataset[i][0].numpy()[None] for i in range(min(limit, len(dataset)))]
        self.i = 0

    def get_next(self):
        if self.i >= len(self.items):
            return None
        x = self.items[self.i]
        self.i += 1
        return {"image": x}

    def rewind(self):
        self.i = 0


def compare(fp32: Path, int8: Path, dataset: PlanDataset, limit: int = 64) -> dict:
    import onnxruntime as ort

    a = ort.InferenceSession(str(fp32), providers=["CPUExecutionProvider"])
    b = ort.InferenceSession(str(int8), providers=["CPUExecutionProvider"])
    agree, inter, union = [], np.zeros(6), np.zeros(6)
    for i in range(min(limit, len(dataset))):
        x, y = dataset[i]
        x = x.numpy()[None]
        pa = a.run(["logits"], {"image": x})[0].argmax(1)[0]
        pb = b.run(["logits"], {"image": x})[0].argmax(1)[0]
        agree.append(float((pa == pb).mean()))
        gt = y.numpy()
        for c in range(6):
            inter[c] += np.logical_and(pb == c, gt == c).sum()
            union[c] += np.logical_or(pb == c, gt == c).sum()
    ious = [inter[c] / union[c] for c in range(6) if union[c] > 0]
    return {"tiles": min(limit, len(dataset)), "argmax_agreement_mean": float(np.mean(agree)),
            "argmax_agreement_min": float(np.min(agree)), "int8_miou": float(np.mean(ious))}


def quantize(model: str | Path, dataset_root: str | Path, output: str | Path, calib_tiles: int = 32,
             eval_split: str = "test") -> dict:
    from onnxruntime.quantization import CalibrationMethod, QuantFormat, QuantType, quantize_static
    from onnxruntime.quantization.shape_inference import quant_pre_process

    import shutil
    import tempfile

    model, output = Path(model), Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    reader = _TileReader(PlanDataset(dataset_root, "train"), calib_tiles)
    # onnxruntime.quantization crea archivos intermedios que fallan con rutas Unicode en
    # Windows (p. ej. "ñ"): se trabaja en un directorio temporal ASCII y luego se mueve.
    with tempfile.TemporaryDirectory(prefix="structura_q_") as tmp:
        src, pre, dst = Path(tmp) / "in.onnx", Path(tmp) / "pre.onnx", Path(tmp) / "out.onnx"
        shutil.copyfile(model, src)
        quant_pre_process(str(src), str(pre))
        quantize_static(str(pre), str(dst), reader, quant_format=QuantFormat.QDQ,
                        activation_type=QuantType.QUInt8, weight_type=QuantType.QInt8,
                        calibrate_method=CalibrationMethod.MinMax, per_channel=True)
        shutil.copyfile(dst, output)
    metrics = compare(model, output, PlanDataset(dataset_root, eval_split))
    src_meta = model.with_suffix(".model.json")
    meta = json.loads(src_meta.read_text(encoding="utf-8")) if src_meta.exists() else {"format": "structura-model/1"}
    data = output.read_bytes()
    meta.update({
        "id": meta.get("id", "vision_ai") + "_int8",
        "file": output.name,
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
        "quantization": {"type": "int8_static_qdq", "calibration_tiles": calib_tiles,
                         "fp32_bytes": model.stat().st_size, **metrics},
    })
    output.with_suffix(".model.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False), encoding="utf-8")
    return meta


def main(argv: list[str] | None = None) -> None:
    from .io_utils import console_safe
    console_safe()
    ap = argparse.ArgumentParser(description="Cuantiza un modelo ONNX a INT8 (QDQ) y mide la degradación.")
    ap.add_argument("--model", required=True)
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--calib-tiles", type=int, default=32)
    ap.add_argument("--eval-split", default="test", choices=["train", "validation", "test"])
    args = ap.parse_args(argv)
    meta = quantize(args.model, args.dataset, args.output, args.calib_tiles, args.eval_split)
    q = meta["quantization"]
    print(f"INT8: {meta['bytes'] / 2**20:.2f} MB (FP32 {q['fp32_bytes'] / 2**20:.2f} MB) - "
          f"acuerdo argmax {q['argmax_agreement_mean']:.4f} (min {q['argmax_agreement_min']:.4f}) - mIoU INT8 {q['int8_miou']:.4f}")


if __name__ == "__main__":
    main()
