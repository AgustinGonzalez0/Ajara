"""Métricas de segmentación acumuladas sobre todo un split (no promediadas por batch).

* Matriz de confusión ``C[gt, pred]`` acumulada → IoU, precision, recall por clase.
* mIoU = media de IoU sobre las clases presentes (en GT o en predicción);
  las clases ausentes en ambos se reportan como ``None`` y no entran en la media.
* Boundary F1 por clase (Csurka et al., 2013): bordes de la máscara binaria de
  cada clase, tolerancia de ``tolerance`` píxeles, contados globalmente.

Todo se calcula en el dispositivo del tensor (GPU si está disponible).
"""
from __future__ import annotations

from dataclasses import dataclass, field

import torch
import torch.nn.functional as F


def _boundary(binary: torch.Tensor) -> torch.Tensor:
    """Píxeles de la clase cuyo vecindario 3x3 contiene otra clase. binary: (N,H,W) bool."""
    x = binary.float().unsqueeze(1)
    eroded = -F.max_pool2d(-x, kernel_size=3, stride=1, padding=1)
    return (x - eroded).squeeze(1) > 0


def _dilate(binary: torch.Tensor, radius: int) -> torch.Tensor:
    if radius <= 0:
        return binary
    k = 2 * radius + 1
    return F.max_pool2d(binary.float().unsqueeze(1), kernel_size=k, stride=1, padding=radius).squeeze(1) > 0


@dataclass
class SegmentationMetrics:
    num_classes: int
    class_names: list[str] | None = None
    tolerance: int = 2
    device: torch.device | str = "cpu"
    confusion: torch.Tensor = field(init=False)
    bf_counts: torch.Tensor = field(init=False)  # [C, 4]: tp_p, n_pred_b, tp_r, n_gt_b

    def __post_init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.confusion = torch.zeros(self.num_classes, self.num_classes, dtype=torch.int64, device=self.device)
        self.bf_counts = torch.zeros(self.num_classes, 4, dtype=torch.int64, device=self.device)

    @torch.no_grad()
    def update(self, pred: torch.Tensor, target: torch.Tensor) -> None:
        """pred, target: (N,H,W) enteros con IDs de clase."""
        if pred.shape != target.shape:
            raise ValueError(f"pred {tuple(pred.shape)} y target {tuple(target.shape)} difieren")
        pred = pred.to(self.confusion.device).long()
        target = target.to(self.confusion.device).long()
        k = self.num_classes
        valid = (target >= 0) & (target < k)
        idx = target[valid] * k + pred[valid]
        self.confusion += torch.bincount(idx, minlength=k * k).reshape(k, k)
        for c in range(k):
            pb = _boundary(pred == c)
            gb = _boundary(target == c)
            n_pb, n_gb = pb.sum(), gb.sum()
            if n_pb == 0 and n_gb == 0:
                continue
            self.bf_counts[c, 0] += (pb & _dilate(gb, self.tolerance)).sum()
            self.bf_counts[c, 1] += n_pb
            self.bf_counts[c, 2] += (gb & _dilate(pb, self.tolerance)).sum()
            self.bf_counts[c, 3] += n_gb

    def compute(self) -> dict:
        cm = self.confusion.double().cpu()
        tp = cm.diag()
        gt = cm.sum(1)
        pr = cm.sum(0)
        union = gt + pr - tp
        names = self.class_names or [str(i) for i in range(self.num_classes)]
        bf = self.bf_counts.double().cpu()
        per_class = {}
        ious = []
        for c in range(self.num_classes):
            present = union[c] > 0
            iou = float(tp[c] / union[c]) if present else None
            precision = float(tp[c] / pr[c]) if pr[c] > 0 else None
            recall = float(tp[c] / gt[c]) if gt[c] > 0 else None
            bp = float(bf[c, 0] / bf[c, 1]) if bf[c, 1] > 0 else None
            br = float(bf[c, 2] / bf[c, 3]) if bf[c, 3] > 0 else None
            bf1 = (2 * bp * br / (bp + br)) if bp is not None and br is not None and (bp + br) > 0 else (
                0.0 if (bp is not None or br is not None) else None)
            per_class[names[c]] = {"iou": iou, "precision": precision, "recall": recall,
                                   "boundary_f1": bf1, "gt_pixels": int(gt[c]), "pred_pixels": int(pr[c])}
            if iou is not None:
                ious.append(iou)
        total = float(cm.sum())
        fg = [per_class[n]["iou"] for n in names[1:] if per_class[n]["iou"] is not None]
        bf1s = [per_class[n]["boundary_f1"] for n in names[1:] if per_class[n]["boundary_f1"] is not None]
        return {
            "miou": sum(ious) / len(ious) if ious else None,
            "miou_foreground": sum(fg) / len(fg) if fg else None,
            "pixel_accuracy": float(tp.sum() / total) if total else None,
            "mean_boundary_f1_foreground": sum(bf1s) / len(bf1s) if bf1s else None,
            "boundary_tolerance_px": self.tolerance,
            "per_class": per_class,
            "confusion_matrix": [[int(v) for v in row] for row in self.confusion.cpu().tolist()],
        }
