import argparse
from pathlib import Path
import cv2
import numpy as np
import onnxruntime as ort

PALETTE = np.array([
    [20, 20, 20], [220, 60, 60], [60, 180, 75],
    [65, 105, 225], [245, 190, 50], [170, 80, 190]
], dtype=np.uint8)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    session = ort.InferenceSession(args.model, providers=["CPUExecutionProvider"])
    src = cv2.imread(args.input, cv2.IMREAD_COLOR)
    if src is None: raise FileNotFoundError(args.input)
    h, w = src.shape[:2]
    rgb = cv2.cvtColor(cv2.resize(src, (512, 512)), cv2.COLOR_BGR2RGB)
    x = rgb.transpose(2, 0, 1)[None].astype(np.float32) / 255.0
    logits = session.run(["logits"], {"image": x})[0]
    pred = logits.argmax(1)[0].astype(np.uint8)
    pred = cv2.resize(pred, (w, h), interpolation=cv2.INTER_NEAREST)
    color = PALETTE[pred][:, :, ::-1]
    overlay = cv2.addWeighted(src, 0.55, color, 0.45, 0)
    out = Path(args.output); out.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out / "mask.png"), pred)
    cv2.imwrite(str(out / "overlay.png"), overlay)
    print(f"Resultados ONNX guardados en {out}")

if __name__ == "__main__":
    main()
