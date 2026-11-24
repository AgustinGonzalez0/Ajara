import argparse
from pathlib import Path
import torch
from torch import nn
from torch.utils.data import DataLoader
from tqdm import tqdm
from .model import UNetSmall
from .data import PlanDataset

def mean_iou(logits, target, classes=6):
    pred = logits.argmax(1)
    scores = []
    for c in range(classes):
        p, t = pred == c, target == c
        union = (p | t).sum().item()
        if union:
            scores.append((p & t).sum().item() / union)
    return sum(scores) / max(1, len(scores))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--batch-size", type=int, default=4)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--output", default="./artifacts")
    ap.add_argument("--workers", type=int, default=0)
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    out = Path(args.output); out.mkdir(parents=True, exist_ok=True)
    train_ds = PlanDataset(args.dataset, "train", augment=True)
    val_ds = PlanDataset(args.dataset, "validation", augment=False)
    train_dl = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True,
                          num_workers=args.workers, pin_memory=(device == "cuda"))
    val_dl = DataLoader(val_ds, batch_size=args.batch_size, shuffle=False,
                        num_workers=args.workers)

    model = UNetSmall().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    criterion = nn.CrossEntropyLoss()
    best = float("inf")

    for epoch in range(1, args.epochs + 1):
        model.train(); train_loss = 0.0
        for x, y in tqdm(train_dl, desc=f"Epoch {epoch}/{args.epochs}"):
            x, y = x.to(device), y.to(device)
            optimizer.zero_grad(set_to_none=True)
            loss = criterion(model(x), y)
            loss.backward()
            optimizer.step()
            train_loss += loss.item()

        model.eval(); val_loss = 0.0; val_iou = 0.0
        with torch.no_grad():
            for x, y in val_dl:
                x, y = x.to(device), y.to(device)
                logits = model(x)
                val_loss += criterion(logits, y).item()
                val_iou += mean_iou(logits, y)
        train_loss /= max(1, len(train_dl))
        val_loss /= max(1, len(val_dl))
        val_iou /= max(1, len(val_dl))
        print(f"epoch={epoch} train_loss={train_loss:.4f} val_loss={val_loss:.4f} mean_iou={val_iou:.4f}")

        checkpoint = {"model": model.state_dict(), "num_classes": 6, "base": 16, "epoch": epoch}
        torch.save(checkpoint, out / "latest.pt")
        if val_loss < best:
            best = val_loss
            torch.save(checkpoint, out / "best.pt")
    print(f"Entrenamiento terminado. Mejor checkpoint: {out / 'best.pt'}")

if __name__ == "__main__":
    main()
