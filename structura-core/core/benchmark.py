"""Compara motores sobre los MISMOS planos completos: motor clásico (sin IA, el de la app)
y uno o más checkpoints de Vision AI. Métricas por matriz de confusión acumulada.

Los planos se generan con ``structura-data/tools/render_split.py`` (máscaras verificadas).

Uso::

    python -m core.benchmark --plans ../data/bench_test --checkpoint ce=../data/runs/vec_v1_ce/best.pt \
        --checkpoint enet=../data/runs/vec_v1_enet/best.pt --classic ../packages/structura_vision \
        --output ../data/runs/benchmark_v1
"""
from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
import time
from pathlib import Path

import cv2
import numpy as np
import torch

from .checkpoint import load_model, torch_predict_fn
from .data import CLASS_NAMES, NUM_CLASSES
from .io_utils import console_safe, read_mask, read_rgb
from .metrics import SegmentationMetrics
from .tiling import predict_tiled


def _write_pgm(path: Path, gray: np.ndarray) -> None:
    h, w = gray.shape
    path.write_bytes(f"P5\n{w} {h}\n255\n".encode() + gray.astype(np.uint8).tobytes())


def _read_pgm(path: Path) -> np.ndarray:
    data = path.read_bytes()
    parts, i = [], 0
    while len(parts) < 4:
        while data[i:i + 1].isspace():
            i += 1
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        parts.append(data[i:j])
        i = j
    w, h = int(parts[1]), int(parts[2])
    return np.frombuffer(data[i + 1:i + 1 + w * h], np.uint8).reshape(h, w)


def run_classic(plans: list[Path], package: Path) -> tuple[dict[str, np.ndarray], float]:
    """Corre el motor clásico (Dart) sobre todos los planos de una vez."""
    with tempfile.TemporaryDirectory() as td:
        tdp = Path(td)
        lines = []
        for p in plans:
            gray = cv2.cvtColor(read_rgb(p), cv2.COLOR_RGB2GRAY)
            src, dst = tdp / f"{p.stem}.pgm", tdp / f"{p.stem}.out.pgm"
            _write_pgm(src, gray)
            lines.append(f"{src}\t{dst}")
        lst = tdp / "list.txt"
        lst.write_text("\n".join(lines), encoding="utf-8")
        r = subprocess.run(["dart", "run", "tool/classic_cli.dart", str(lst)], cwd=package, capture_output=True,
                           text=True, encoding="utf-8", shell=True)
        if r.returncode != 0:
            raise RuntimeError(f"motor clásico falló: {r.stderr[-2000:]}")
        ms = float(r.stdout.strip().split()[-3]) if "promedio" in r.stdout else float("nan")
        return {p.stem: _read_pgm(tdp / f"{p.stem}.out.pgm") for p in plans}, ms


def summarize(m: SegmentationMetrics) -> dict:
    res = m.compute()
    return {
        "miou": res["miou"], "miou_foreground": res["miou_foreground"], "pixel_accuracy": res["pixel_accuracy"],
        "per_class": {n: {k: res["per_class"][n][k] for k in ("iou", "precision", "recall", "boundary_f1")}
                      for n in CLASS_NAMES},
    }


def main(argv: list[str] | None = None) -> None:
    console_safe()
    ap = argparse.ArgumentParser(description="Motor clásico vs Vision AI sobre los mismos planos.")
    ap.add_argument("--plans", required=True, help="Carpeta con images/ y masks/ (tools.render_split)")
    ap.add_argument("--checkpoint", action="append", default=[], help="nombre=ruta/best.pt (repetible)")
    ap.add_argument("--classic", help="Carpeta del paquete structura_vision (motor clásico en Dart)")
    ap.add_argument("--output", required=True)
    a = ap.parse_args(argv)

    root = Path(a.plans)
    images = sorted((root / "images").glob("*.png"))
    masks = {p.stem: read_mask(root / "masks" / p.name) for p in images}
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    report: dict = {"plans": len(images), "source": str(root), "engines": {}}

    if a.classic:
        preds, ms = run_classic(images, Path(a.classic))
        m = SegmentationMetrics(NUM_CLASSES, CLASS_NAMES)
        for k, gt in masks.items():
            m.update(torch.from_numpy(preds[k].astype(np.int64))[None], torch.from_numpy(gt.astype(np.int64))[None])
        report["engines"]["classic"] = {**summarize(m), "ms_per_plan": ms, "note": "no detecta escaleras (clase 5)"}

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    for spec in a.checkpoint:
        name, path = spec.split("=", 1)
        model, ckpt = load_model(path, device)
        fn = torch_predict_fn(model, device, amp=device.type == "cuda")
        m = SegmentationMetrics(NUM_CLASSES, CLASS_NAMES, device=device)
        t0 = time.perf_counter()
        for p in images:
            pred = predict_tiled(read_rgb(p), fn, NUM_CLASSES, batch_size=8).labels
            m.update(torch.from_numpy(pred.astype(np.int64))[None], torch.from_numpy(masks[p.stem].astype(np.int64))[None])
        elapsed = (time.perf_counter() - t0) / max(1, len(images)) * 1000
        report["engines"][name] = {**summarize(m), "ms_per_plan": elapsed, "device": str(device),
                                   "checkpoint": str(path), "epoch": ckpt.get("epoch"),
                                   "loss": (ckpt.get("config") or {}).get("loss")}

    (out / "benchmark.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    names = list(report["engines"])
    lines = [f"# Comparación de motores ({len(images)} planos completos de test)", "",
             "| Métrica | " + " | ".join(names) + " |", "|---|" + "---:|" * len(names)]

    def fmt(v):
        return "—" if v is None else f"{v:.3f}"

    lines.append("| mIoU | " + " | ".join(fmt(report["engines"][n]["miou"]) for n in names) + " |")
    for c in CLASS_NAMES[1:]:
        lines.append(f"| IoU {c} | " + " | ".join(fmt(report["engines"][n]["per_class"][c]["iou"]) for n in names) + " |")
    for c in CLASS_NAMES[1:]:
        lines.append(f"| Precisión / recall {c} | " + " | ".join(
            f"{fmt(report['engines'][n]['per_class'][c]['precision'])} / {fmt(report['engines'][n]['per_class'][c]['recall'])}"
            for n in names) + " |")
    lines.append("| ms por plano | " + " | ".join(f"{report['engines'][n]['ms_per_plan']:.0f}" for n in names) + " |")
    (out / "benchmark.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
