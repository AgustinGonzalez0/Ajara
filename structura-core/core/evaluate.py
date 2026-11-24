"""Evaluación cuantitativa de un checkpoint sobre un split (por defecto ``test``).

Genera ``<output>/eval_<split>.json`` y ``eval_<split>.md`` con: matriz de
confusión, IoU / precision / recall / Boundary F1 por clase, mIoU, tiempo de
inferencia por tile (ms, tras calentamiento, sincronizado con CUDA), memoria
pico de GPU, nº de parámetros y procedencia del dataset.

Uso (Windows):
    python -m core.evaluate --checkpoint .\\runs\\vision_ai_0_1\\best.pt --dataset C:\\STRUCTURA\\data\\dataset
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader

from .checkpoint import class_names, load_model
from .data import PlanDataset
from .train import evaluate_loader, pick_device


@torch.no_grad()
def benchmark(model: nn.Module, device: torch.device, amp: bool, size: int = 512, batch: int = 1,
              warmup: int = 5, iters: int = 30) -> dict:
    x = torch.rand(batch, 3, size, size, device=device)
    if device.type == "cuda":
        torch.cuda.reset_peak_memory_stats(device)
    for _ in range(warmup):
        with torch.autocast(device.type, dtype=torch.float16, enabled=amp):
            model(x)
    if device.type == "cuda":
        torch.cuda.synchronize(device)
    times = []
    for _ in range(iters):
        t0 = time.perf_counter()
        with torch.autocast(device.type, dtype=torch.float16, enabled=amp):
            model(x)
        if device.type == "cuda":
            torch.cuda.synchronize(device)
        times.append((time.perf_counter() - t0) * 1000)
    times.sort()
    return {"device": str(device), "amp_fp16": amp, "batch": batch, "input": [batch, 3, size, size],
            "ms_median": round(times[len(times) // 2], 3), "ms_p90": round(times[int(len(times) * 0.9)], 3),
            "peak_gpu_mem_mb": round(torch.cuda.max_memory_allocated(device) / 2**20, 1)
            if device.type == "cuda" else None}


def _fmt(v) -> str:
    return "—" if v is None else f"{v:.4f}"


def to_markdown(report: dict) -> str:
    m = report["metrics"]
    lines = [f"# Evaluación Vision AI — split `{report['split']}`", "",
             f"- Checkpoint: `{report['checkpoint']}` (época {report['epoch']})",
             f"- Dataset: `{report['dataset']}` — {report['tiles']} tiles",
             f"- Parámetros: {report['parameters']:,}",
             f"- mIoU: **{_fmt(m['miou'])}** · mIoU (sin background): {_fmt(m['miou_foreground'])} · "
             f"Pixel acc: {_fmt(m['pixel_accuracy'])} · Boundary F1 medio (±{m['boundary_tolerance_px']} px): "
             f"{_fmt(m['mean_boundary_f1_foreground'])}",
             f"- Inferencia 512×512: mediana {report['benchmark']['ms_median']} ms, p90 "
             f"{report['benchmark']['ms_p90']} ms ({report['benchmark']['device']}, "
             f"FP16={report['benchmark']['amp_fp16']}), memoria pico "
             f"{report['benchmark']['peak_gpu_mem_mb']} MB", "",
             "| Clase | IoU | Precision | Recall | Boundary F1 | Píxeles GT |", "|---|---|---|---|---|---|"]
    for name, c in m["per_class"].items():
        lines.append(f"| {name} | {_fmt(c['iou'])} | {_fmt(c['precision'])} | {_fmt(c['recall'])} | "
                     f"{_fmt(c['boundary_f1'])} | {c['gt_pixels']:,} |")
    names = list(m["per_class"])
    lines += ["", "Matriz de confusión (filas = GT, columnas = predicción):", "",
              "| GT \\ Pred | " + " | ".join(names) + " |", "|---" * (len(names) + 1) + "|"]
    for name, row in zip(names, m["confusion_matrix"]):
        lines.append(f"| {name} | " + " | ".join(f"{v:,}" for v in row) + " |")
    lines += ["", "> — = clase ausente en GT y predicción (no entra en la media).",
              "> Estas métricas solo son representativas si el dataset es real y validado."]
    return "\n".join(lines) + "\n"


def evaluate(args: argparse.Namespace) -> dict:
    device = pick_device(args.device)
    amp = device.type == "cuda" and not args.no_amp
    model, ckpt = load_model(args.checkpoint, device)
    names = class_names(ckpt)
    ds = PlanDataset(args.dataset, args.split, augment=False, num_classes=len(names))
    dl = DataLoader(ds, batch_size=args.batch_size, shuffle=False)
    _, metrics = evaluate_loader(model, dl, device, nn.CrossEntropyLoss(), amp, len(names))
    report = {"split": args.split, "checkpoint": str(args.checkpoint), "epoch": ckpt.get("epoch"),
              "dataset": str(args.dataset), "tiles": len(ds),
              "parameters": sum(p.numel() for p in model.parameters()),
              "metrics": metrics, "benchmark": benchmark(model, device, amp),
              "train_config": ckpt.get("config")}
    out = Path(args.output or Path(args.checkpoint).parent)
    out.mkdir(parents=True, exist_ok=True)
    (out / f"eval_{args.split}.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    (out / f"eval_{args.split}.md").write_text(to_markdown(report), encoding="utf-8")
    print(to_markdown(report))
    return report


def main(argv: list[str] | None = None) -> None:
    from .io_utils import console_safe
    console_safe()
    ap = argparse.ArgumentParser(description="Evalúa un checkpoint de Vision AI.")
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--split", default="test", choices=["train", "validation", "test"])
    ap.add_argument("--output", help="Carpeta del informe (por defecto, la del checkpoint)")
    ap.add_argument("--batch-size", type=int, default=4)
    ap.add_argument("--device", choices=["auto", "cuda", "cpu"], default="auto")
    ap.add_argument("--no-amp", action="store_true")
    evaluate(ap.parse_args(argv))


if __name__ == "__main__":
    main()
