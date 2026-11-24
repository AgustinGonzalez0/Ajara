"""Re-renderiza los planos completos de un split (misma semilla → mismo dibujo y máscara).

Sirve para evaluar motores sobre planos enteros (no tiles) y comparar el motor clásico
con Vision AI en exactamente los mismos planos. Verifica que la máscara coincida byte a
byte con la que se usó para generar los tiles (sha256 del manifiesto del plano).

Uso::

    python -m tools.render_split --dataset ../data/dataset_vector_v1 --cache ../data/vector_cache/swiss \
        --split test --output ../data/bench_test --limit 150
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .build_vector_dataset import _seed_for
from .common import DatasetError, read_json, sha256_file, write_json, write_png
from .render_vector_plans import render_plan
from .vector_sources import load_cached_plan


def render_split(dataset: Path, cache: Path, split: str, output: Path, limit: int = 0) -> list[dict]:
    manifest = read_json(dataset / "dataset_manifest.json")
    seed = manifest["params"]["seed"]
    door_label = manifest.get("door_label", "vano")
    plans = read_json(dataset / "splits" / "split_manifest.json")["plans_by_split"][split]
    if limit:
        plans = plans[:limit]
    (output / "images").mkdir(parents=True, exist_ok=True)
    (output / "masks").mkdir(parents=True, exist_ok=True)
    out = []
    for pid in plans:
        base, _, variant = pid.rpartition("_v")
        plan = load_cached_plan(cache / f"{base}.json.gz")
        r = render_plan(plan, _seed_for(seed, base, int(variant)), door_label=door_label,
                        max_side=manifest["params"].get("max_side", 4096))
        img, msk = output / "images" / f"{pid}.png", output / "masks" / f"{pid}.png"
        write_png(img, r.image)
        write_png(msk, r.mask)
        expected = read_json(dataset / "plans" / f"{pid}.json")["source_mask_sha256"]
        if sha256_file(msk) != expected:
            raise DatasetError(f"{pid}: la máscara re-renderizada no coincide con la del dataset")
        out.append({"plan_id": pid, "px_per_m": r.px_per_m, "width": int(r.mask.shape[1]), "height": int(r.mask.shape[0])})
    write_json(output / "plans.json", {"dataset": str(dataset), "split": split, "plans": out})
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--cache", required=True)
    ap.add_argument("--split", default="test")
    ap.add_argument("--output", required=True)
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args(argv)
    try:
        out = render_split(Path(a.dataset), Path(a.cache), a.split, Path(a.output), a.limit)
    except DatasetError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    print(f"{len(out)} planos en {a.output} (máscaras verificadas por sha256)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
