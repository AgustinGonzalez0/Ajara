"""Entrenamiento de Vision AI (U-Net Small) con AMP, métricas completas y registro CSV.

Especificación 0.1: CrossEntropy, AdamW lr=1e-3, 40 épocas, batch 4, AMP FP16 en CUDA.
El mejor checkpoint se elige por mIoU de validación (no por loss).

Opciones EXPERIMENTALES (por defecto apagadas: la especificación 0.1 no cambia):
  --class-weights enet   CE ponderada w = 1/ln(1.02 + f) (propuesta B, D-18 PENDIENTE).
  --photometric-aug      aumentos de contraste, ruido, desenfoque y JPEG en train.

Uso (Windows):
    python -m core.train --dataset C:\\STRUCTURA\\data\\dataset --output .\\runs\\vision_ai_0_1
"""
from __future__ import annotations

import argparse
import csv
import json
import platform
import time
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader

from .data import CLASS_NAMES, NUM_CLASSES, PlanDataset, class_pixel_frequencies, enet_class_weights, worker_init_fn
from .io_utils import set_seed
from .metrics import SegmentationMetrics
from .model import UNetSmall


def pick_device(requested: str) -> torch.device:
    if requested == "cuda" and not torch.cuda.is_available():
        raise SystemExit("Se pidió --device cuda pero CUDA no está disponible "
                         "(¿PyTorch CPU-only? instalar desde https://download.pytorch.org/whl/cu128)")
    if requested == "auto":
        return torch.device("cuda" if torch.cuda.is_available() else "cpu")
    return torch.device(requested)


@torch.no_grad()
def evaluate_loader(model: nn.Module, loader: DataLoader, device: torch.device, criterion: nn.Module,
                    amp: bool, num_classes: int = NUM_CLASSES) -> tuple[float, dict]:
    model.eval()
    metrics = SegmentationMetrics(num_classes, CLASS_NAMES[:num_classes], device=device)
    total_loss, n = 0.0, 0
    for x, y in loader:
        x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
        with torch.autocast(device.type, dtype=torch.float16, enabled=amp):
            logits = model(x)
            loss = criterion(logits.float(), y)
        total_loss += float(loss) * x.shape[0]
        n += x.shape[0]
        metrics.update(logits.argmax(1), y)
    return total_loss / max(1, n), metrics.compute()


def train(args: argparse.Namespace) -> dict:
    set_seed(args.seed, args.deterministic)
    device = pick_device(args.device)
    amp = device.type == "cuda" and not args.no_amp
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)

    train_ds = PlanDataset(args.dataset, "train", augment=True, photometric_aug=args.photometric_aug)
    val_ds = PlanDataset(args.dataset, "validation", augment=False)
    gen = torch.Generator().manual_seed(args.seed)
    train_dl = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True, generator=gen,
                          num_workers=args.workers, pin_memory=device.type == "cuda",
                          worker_init_fn=worker_init_fn, drop_last=len(train_ds) > args.batch_size)
    val_dl = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False, num_workers=args.workers,
                        pin_memory=device.type == "cuda")

    model = UNetSmall(NUM_CLASSES, args.base).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    freqs = class_pixel_frequencies(args.dataset, "train")
    weights = None
    loss_name = "CrossEntropyLoss (sin pesos)"
    if args.class_weights == "enet":
        weights = enet_class_weights(freqs)
        loss_name = "CrossEntropyLoss ponderada ENet w=1/ln(1.02+f) [EXPERIMENTAL, D-18]"
    criterion = nn.CrossEntropyLoss(weight=torch.tensor(weights, dtype=torch.float32, device=device) if weights else None)
    scaler = torch.amp.GradScaler("cuda", enabled=amp)
    config = {k: v for k, v in vars(args).items()}
    config.update(device=str(device), amp=amp, torch=str(torch.__version__), cuda=str(torch.version.cuda),
                  gpu=torch.cuda.get_device_name(0) if device.type == "cuda" else None,
                  python=platform.python_version(), train_tiles=len(train_ds), val_tiles=len(val_ds),
                  class_names=CLASS_NAMES, loss=loss_name, class_weights=weights,
                  train_class_frequencies=[round(f, 8) for f in freqs])
    (out / "config.json").write_text(json.dumps(config, indent=2, ensure_ascii=False), encoding="utf-8")

    fields = ["epoch", "train_loss", "val_loss", "val_miou", "val_miou_fg", "val_pixel_acc",
              "val_mean_bf1_fg"] + [f"iou_{n}" for n in CLASS_NAMES] + ["lr", "epoch_s", "peak_mem_mb"]
    log_path = out / "train_log.csv"
    with open(log_path, "w", newline="", encoding="utf-8") as fh:
        csv.DictWriter(fh, fieldnames=fields).writeheader()

    best_miou, best_epoch = -1.0, 0
    for epoch in range(1, args.epochs + 1):
        if device.type == "cuda":
            torch.cuda.reset_peak_memory_stats(device)
        t0 = time.perf_counter()
        model.train()
        running, seen = 0.0, 0
        for x, y in train_dl:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
            optimizer.zero_grad(set_to_none=True)
            with torch.autocast(device.type, dtype=torch.float16, enabled=amp):
                logits = model(x)
                loss = criterion(logits.float(), y)
            if not torch.isfinite(loss):
                raise RuntimeError(f"Loss no finito en la época {epoch}")
            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
            running += float(loss) * x.shape[0]
            seen += x.shape[0]
        val_loss, m = evaluate_loader(model, val_dl, device, criterion, amp)
        elapsed = time.perf_counter() - t0
        peak = torch.cuda.max_memory_allocated(device) / 2**20 if device.type == "cuda" else 0.0
        miou = m["miou"] if m["miou"] is not None else 0.0
        row = {"epoch": epoch, "train_loss": running / max(1, seen), "val_loss": val_loss,
               "val_miou": m["miou"], "val_miou_fg": m["miou_foreground"],
               "val_pixel_acc": m["pixel_accuracy"], "val_mean_bf1_fg": m["mean_boundary_f1_foreground"],
               **{f"iou_{n}": m["per_class"][n]["iou"] for n in CLASS_NAMES},
               "lr": optimizer.param_groups[0]["lr"], "epoch_s": round(elapsed, 2), "peak_mem_mb": round(peak, 1)}
        with open(log_path, "a", newline="", encoding="utf-8") as fh:
            csv.DictWriter(fh, fieldnames=fields).writerow(row)
        print(f"epoch {epoch}/{args.epochs} train_loss={row['train_loss']:.4f} val_loss={val_loss:.4f} "
              f"mIoU={miou:.4f} bf1_fg={m['mean_boundary_f1_foreground'] or 0:.4f} "
              f"{elapsed:.1f}s mem={peak:.0f}MB", flush=True)

        ckpt = {"model": model.state_dict(), "num_classes": NUM_CLASSES, "base": args.base, "epoch": epoch,
                "val_miou": m["miou"], "class_names": CLASS_NAMES, "config": config}
        torch.save(ckpt, out / "latest.pt")
        if miou > best_miou:
            best_miou, best_epoch = miou, epoch
            torch.save(ckpt, out / "best.pt")
            (out / "best_val_metrics.json").write_text(json.dumps({"epoch": epoch, **m}, indent=2),
                                                       encoding="utf-8")
    summary = {"best_epoch": best_epoch, "best_val_miou": best_miou, "output": str(out)}
    print(f"Entrenamiento terminado. Mejor mIoU {best_miou:.4f} en época {best_epoch}: {out / 'best.pt'}")
    return summary


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="Entrena Vision AI (U-Net Small).")
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--output", default="./runs/vision_ai")
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--batch-size", type=int, default=4)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--weight-decay", type=float, default=1e-4)
    ap.add_argument("--base", type=int, default=16)
    ap.add_argument("--workers", type=int, default=0, help="0 recomendado en Windows para depurar")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--deterministic", action="store_true", help="cuDNN determinista (más lento)")
    ap.add_argument("--device", choices=["auto", "cuda", "cpu"], default="auto")
    ap.add_argument("--no-amp", action="store_true")
    ap.add_argument("--class-weights", choices=["none", "enet"], default="none",
                    help="none = especificación 0.1; enet = experimento de CE ponderada (D-18 pendiente)")
    ap.add_argument("--photometric-aug", action="store_true", help="Aumentos fotométricos en train (experimental)")
    return ap


def main(argv: list[str] | None = None) -> None:
    from .io_utils import console_safe
    console_safe()
    train(build_parser().parse_args(argv))


if __name__ == "__main__":
    main()
