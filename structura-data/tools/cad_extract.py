"""Extrae todas las plantas de una carpeta de DXF → imágenes + máscaras + revisión.

Uso::

    python -m tools.cad_extract --dxf ../data/external/soto_colegio/dxf --output ../data/cad_soto --workers 8

Salida: ``images/``, ``masks/``, ``overlays/`` (para revisar), ``sheets.json`` con la
procedencia (archivo, lámina, conteos, espesor de muro, firma para detectar duplicados).
Las copias del mismo dibujo (mismo conjunto de etiquetas) se marcan ``duplicate_of``.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np

from .common import write_json, write_png

PALETTE = np.array([[255, 255, 255], [0, 0, 0], [0, 170, 0], [230, 120, 0], [0, 0, 220], [170, 0, 170]], np.uint8)


def _process(dxf: str, out: str, wall_px: float) -> list[dict]:
    import cv2

    from .cad_plans import find_plan_sheets, load_primitives, render_sheet

    out_p = Path(out)
    name = Path(dxf).stem
    try:
        prims = load_primitives(dxf)
        sheets = find_plan_sheets(prims)
    except Exception as e:  # archivo dañado o entidades no soportadas
        return [{"file": name, "error": f"{type(e).__name__}: {e}"}]
    rows = []
    for k, sh in enumerate(sheets):
        img, mask, info = render_sheet(sh, wall_px=wall_px)
        counts = np.bincount(mask.ravel(), minlength=6).tolist()
        sig = hashlib.sha1(json.dumps([info["labels"], [round(c / max(1, sum(counts)), 3) for c in counts]]).encode()).hexdigest()[:12]
        sid = f"{name}_s{k}"
        write_png(out_p / "images" / f"{sid}.png", img)
        write_png(out_p / "masks" / f"{sid}.png", mask)
        over = img.copy()
        m = mask > 0
        over[m] = (0.45 * over[m] + 0.55 * PALETTE[mask[m]][:, ::-1]).astype(np.uint8)
        sc = min(1.0, 1400 / max(over.shape[:2]))
        cv2.imwrite(str(out_p / "overlays" / f"{sid}.jpg"), cv2.resize(over, None, fx=sc, fy=sc, interpolation=cv2.INTER_AREA),
                    [cv2.IMWRITE_JPEG_QUALITY, 85])
        rows.append({"sheet_id": sid, "file": name, "sheet": k, "wall_width_units": sh.wall_width,
                     "size_px": [int(img.shape[1]), int(img.shape[0])], "labels": info["labels"],
                     "class_pixels": counts, "signature": sig, "stats": sh.stats})
    return rows


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dxf", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--wall-px", type=float, default=10.0)
    a = ap.parse_args(argv)
    out = Path(a.output)
    for sub in ("images", "masks", "overlays"):
        (out / sub).mkdir(parents=True, exist_ok=True)
    files = sorted(str(p) for p in Path(a.dxf).glob("*.dxf"))
    meta = out / "_meta"
    meta.mkdir(exist_ok=True)
    pending = [f for f in files if not (meta / f"{Path(f).stem}.json").exists()]
    workers = a.workers
    # Reanudable: cada archivo deja su resultado; si un proceso muere (memoria con DXF
    # enormes) se rehace el pool con menos procesos y se reintenta una vez.
    from concurrent.futures.process import BrokenProcessPool

    while pending:
        if workers == 1:
            # Uno por uno, cada archivo en su propio proceso: un cierre se atribuye bien.
            f = pending[0]
            try:
                with ProcessPoolExecutor(max_workers=1) as ex:
                    r = ex.submit(_process, f, str(out), a.wall_px).result()
            except BrokenProcessPool:
                r = [{"file": Path(f).stem, "error": "el proceso se cerró (memoria)"}]
            write_json(meta / f"{Path(f).stem}.json", r)
            pending.remove(f)
            print(f"  {len(files) - len(pending)}/{len(files)} {Path(f).stem}: "
                  f"{sum(1 for x in r if 'sheet_id' in x)} plantas", flush=True)
            continue
        try:
            with ProcessPoolExecutor(max_workers=workers) as ex:
                futs = {ex.submit(_process, f, str(out), a.wall_px): f for f in pending}
                for fut in as_completed(futs):
                    f = futs[fut]
                    r = fut.result()
                    write_json(meta / f"{Path(f).stem}.json", r)
                    pending.remove(f)
                    print(f"  {len(files) - len(pending)}/{len(files)} {Path(f).stem}: "
                          f"{sum(1 for x in r if 'sheet_id' in x)} plantas", flush=True)
        except BrokenProcessPool:
            workers = max(1, workers // 2)
            print(f"  un proceso se cerró; reintento con {workers} procesos", flush=True)
    rows: list[dict] = []
    for f in files:
        rows += json.loads((meta / f"{Path(f).stem}.json").read_text(encoding="utf-8"))
    seen: dict[str, str] = {}
    for r in sorted((r for r in rows if "sheet_id" in r), key=lambda r: r["sheet_id"]):
        if r["signature"] in seen:
            r["duplicate_of"] = seen[r["signature"]]
        else:
            seen[r["signature"]] = r["sheet_id"]
    write_json(out / "sheets.json", {"source": a.dxf, "sheets": rows})
    uniq = sum(1 for r in rows if "sheet_id" in r and "duplicate_of" not in r)
    print(f"{sum(1 for r in rows if 'sheet_id' in r)} plantas, {uniq} únicas, {sum(1 for r in rows if 'error' in r)} archivos con error")
    return 0


if __name__ == "__main__":
    sys.exit(main())
