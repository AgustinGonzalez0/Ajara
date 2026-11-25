"""Dataset de ajuste fino desde planos CAD reales (salida de ``tools.cad_extract``).

Las etiquetas CAD salen de las capas del dibujo y son **débiles**: muchos archivos dibujan
parte de los muros en otras capas. Para no enseñarle a la IA que un muro sin etiquetar es
fondo, se marcan como **ignorados (255)**:

* bandas entre líneas paralelas a distancia de un espesor de muro (cierre morfológico de la
  tinta) que no tienen etiqueta → muros probables sin capa;
* un anillo de 2 px alrededor de cada etiqueta (borde incierto del rasterizado).

El resto del fondo (papel, muebles, cotas, textos) sí se usa como fondo.

Splits **por obra** (``group_of``: nunca la misma obra en train y test) y sin láminas duplicadas.
Además de los tiles, copia las láminas de test completas a ``<output>_test`` (máscara
original) y ``<output>_test_ign`` (con ignorados) para ``core.benchmark``.

Uso::

    python -m tools.build_cad_dataset --cad ../data/cad_soto --output ../data/cad_ft_v1
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

import cv2
import numpy as np

from .common import write_json, write_png

IGNORE = 255
TILE = 512
STRIDE = 448


def ignore_mask(rgb: np.ndarray, mask: np.ndarray, wall_px: float = 10.0) -> np.ndarray:
    """Máscara con 255 donde la etiqueta CAD no es confiable (ver docstring del módulo)."""
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    ink = (gray < 200).astype(np.uint8)
    k = max(3, int(round(1.6 * wall_px)) | 1)
    closed = cv2.morphologyEx(ink, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_RECT, (k, k)))
    band = (closed > 0) & (ink == 0)
    band = cv2.dilate(band.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
    fg = mask > 0
    ring = (cv2.dilate(fg.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0) & ~fg
    out = mask.copy()
    out[(band & ~fg) | ring] = IGNORE
    return out


def group_of(file: str) -> str:
    """Obra a la que pertenece un archivo: varias copias/versiones de la misma obra van juntas."""
    f = file.lower()
    if "72" in f:
        return "edificio_72"
    if "hipolito" in f or "centro_cultural" in f:
        return "centro_cultural"
    if "agua_fria" in f:
        return "inst_agua"
    return f


def split_of(file: str, test: float, val: float, test_groups: set[str], val_groups: set[str]) -> str:
    g = group_of(file)
    if test_groups or val_groups:
        return "test" if g in test_groups else "validation" if g in val_groups else "train"
    h = int(hashlib.sha256(g.encode("utf-8")).hexdigest()[:8], 16) / 0xFFFFFFFF
    return "test" if h < test else "validation" if h < test + val else "train"


def tiles(h: int, w: int) -> list[tuple[int, int]]:
    def starts(n: int) -> list[int]:
        if n <= TILE:
            return [0]
        s = list(range(0, n - TILE, STRIDE))
        return s + [n - TILE]
    return [(x, y) for y in starts(h) for x in starts(w)]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cad", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--test", type=float, default=0.2)
    ap.add_argument("--val", type=float, default=0.12)
    ap.add_argument("--keep-empty", type=float, default=0.08, help="fracción de tiles sin dibujo que se conservan")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--test-groups", default="", help="obras para test, separadas por coma (ver group_of)")
    ap.add_argument("--val-groups", default="", help="obras para validación, separadas por coma")
    a = ap.parse_args(argv)
    cad, out = Path(a.cad), Path(a.output)
    sheets = [s for s in json.loads((cad / "sheets.json").read_text(encoding="utf-8"))["sheets"]
              if "sheet_id" in s and not s.get("duplicate_of") and s["labels"].get("wall", 0) > 0]
    for d in (out, Path(f"{out}_test"), Path(f"{out}_test_ign")):
        if d.exists():
            shutil.rmtree(d)
    for sub in ("images", "masks", "splits"):
        (out / sub).mkdir(parents=True)
    for d in (Path(f"{out}_test"), Path(f"{out}_test_ign")):
        (d / "images").mkdir(parents=True)
        (d / "masks").mkdir(parents=True)
    rng = np.random.default_rng(a.seed)
    tg = {g.strip().lower() for g in a.test_groups.split(",") if g.strip()}
    vg = {g.strip().lower() for g in a.val_groups.split(",") if g.strip()}
    splits: dict[str, list[str]] = {"train": [], "validation": [], "test": []}
    report = []
    for s in sheets:
        sid = s["sheet_id"]
        split = split_of(s["file"], a.test, a.val, tg, vg)
        rgb = cv2.cvtColor(cv2.imread(str(cad / "images" / f"{sid}.png")), cv2.COLOR_BGR2RGB)
        mask = cv2.imread(str(cad / "masks" / f"{sid}.png"), cv2.IMREAD_UNCHANGED)
        ign = ignore_mask(rgb, mask)
        if split == "test":
            for d, m in ((Path(f"{out}_test"), mask), (Path(f"{out}_test_ign"), ign)):
                shutil.copyfile(cad / "images" / f"{sid}.png", d / "images" / f"{sid}.png")
                write_png(d / "masks" / f"{sid}.png", m)
        h, w = mask.shape
        n = 0
        for x, y in tiles(h, w):
            ti, tm = rgb[y:y + TILE, x:x + TILE], ign[y:y + TILE, x:x + TILE]
            if ti.shape[:2] != (TILE, TILE):
                pad = ((0, TILE - ti.shape[0]), (0, TILE - ti.shape[1]))
                ti = np.pad(ti, pad + ((0, 0),), constant_values=255)
                tm = np.pad(tm, pad, constant_values=0)
            drawn = (ti.min(axis=2) < 200).mean() > 0.004 or ((tm > 0) & (tm < IGNORE)).any()
            if not drawn and rng.random() > a.keep_empty:
                continue
            name = f"cad_{sid}_x{x:05d}_y{y:05d}"
            write_png(out / "images" / f"{name}.png", cv2.cvtColor(ti, cv2.COLOR_RGB2BGR))
            write_png(out / "masks" / f"{name}.png", tm)
            splits[split].append(name)
            n += 1
        report.append({"sheet_id": sid, "file": s["file"], "group": group_of(s["file"]), "split": split, "tiles": n,
                       "ignored_fraction": round(float((ign == IGNORE).mean()), 4)})
    for k, v in splits.items():
        (out / "splits" / f"{k}.txt").write_text("\n".join(v) + "\n", encoding="utf-8")
    write_json(out / "dataset_manifest.json", {
        "source": "planos CAD privados del usuario (no redistribuir)", "ignore_index": IGNORE,
        "tile": TILE, "stride": STRIDE, "sheets": report,
        "tiles": {k: len(v) for k, v in splits.items()},
        "sheets_per_split": {k: sum(1 for r in report if r["split"] == k) for k in splits}})
    print(json.dumps({k: len(v) for k, v in splits.items()}),
          json.dumps({k: sum(1 for r in report if r["split"] == k) for k in splits}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
