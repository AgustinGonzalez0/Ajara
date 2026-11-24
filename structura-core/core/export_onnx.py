import argparse
import torch
from .model import UNetSmall

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    ckpt = torch.load(args.checkpoint, map_location="cpu")
    model = UNetSmall(ckpt.get("num_classes", 6), ckpt.get("base", 16))
    model.load_state_dict(ckpt["model"]); model.eval()
    dummy = torch.randn(1, 3, 512, 512)
    torch.onnx.export(model, dummy, args.output, input_names=["image"],
                      output_names=["logits"], opset_version=17,
                      do_constant_folding=True)
    print(f"ONNX exportado: {args.output}")

if __name__ == "__main__":
    main()
