import argparse
from pathlib import Path
import cv2
import numpy as np
import torch
from .model import UNetSmall

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
    device = "cuda" if torch.cuda.is_available() else "cpu"
    ckpt = torch.load(args.model, map_location=device)
    model = UNetSmall(ckpt.get("num_classes", 6), ckpt.get("base", 16)).to(device)
    model.load_state_dict(ckpt["model"]); model.eval()

    src = cv2.imread(args.input, cv2.IMREAD_COLOR)
    if src is None: raise FileNotFoundError(args.input)
    h, w = src.shape[:2]
    rgb = cv2.cvtColor(cv2.resize(src, (512, 512)), cv2.COLOR_BGR2RGB)
    x = torch.from_numpy(rgb.transpose(2, 0, 1).copy()).float().unsqueeze(0) / 255.0
    with torch.no_grad():
        pred = model(x.to(device)).argmax(1)[0].cpu().numpy().astype(np.uint8)
    pred = cv2.resize(pred, (w, h), interpolation=cv2.INTER_NEAREST)
    color = PALETTE[pred][:, :, ::-1]
    overlay = cv2.addWeighted(src, 0.55, color, 0.45, 0)
    out = Path(args.output); out.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out / "mask.png"), pred)
    cv2.imwrite(str(out / "overlay.png"), overlay)
    print(f"Resultados guardados en {out}")

if __name__ == "__main__":
    main()
