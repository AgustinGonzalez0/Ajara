"""Fuentes de planos VECTORIALES con licencia abierta → caché JSON (WKT) uniforme.

Fuentes soportadas (ver ../docs/DATASETS.md para licencias y atribución):

* **Swiss Dwellings v3.0.0** (Zenodo 7788422, CC BY 4.0): ``geometries.csv`` dentro del
  ZIP oficial. Muros, columnas, barandas, puertas, ventanas, escaleras, artefactos y
  ambientes como polígonos en metros, por planta (``floor_id``).
* **ResPlan** (github m-agour/ResPlan): ``ResPlan.pkl``. **Licencia en conflicto** (ver
  D-29): el lector existe, pero el armado del dataset lo excluye salvo pedido explícito. Se lee con un
  *unpickler restringido* que solo permite reconstruir geometrías desde WKB: un pickle
  arbitrario puede ejecutar código al cargarse.

La caché (un ``<plan_id>.json.gz`` por plano) es la única entrada del renderizador:
JSON + WKT, inspeccionable y sin código ejecutable.

Formato de la caché (``structura-vector-plan/1``)::

    {"format": "structura-vector-plan/1", "plan_id": "sd_f13376", "project_id": "sd_site_210",
     "source": "swiss_dwellings", "license": "CC BY 4.0", "attribution": "...",
     "meters_per_unit": 1.0, "origin": {...},
     "layers": {"wall": [wkt], "column": [], "door": [], "window": [], "stairs": [], "railing": []},
     "fixtures": [[tipo, wkt]], "rooms": [[tipo, wkt]]}
"""
from __future__ import annotations

import argparse
import csv
import gzip
import io
import json
import math
import pickle
import random
import sys
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Iterator

from .common import DatasetError

CACHE_FORMAT = "structura-vector-plan/1"
LAYERS = ("wall", "column", "door", "window", "stairs", "railing")

SWISS_CSV = "swiss-dwellings-v3.0.0/geometries.csv"
SWISS_LICENSE = "CC BY 4.0"
SWISS_ATTRIBUTION = ("Standfest, M., Franzen, M., Schröder, Y., Gonzalez Medina, L., Villanueva Hernandez, Y., "
                     "Buck, J. H., Tan, Y.-L., Niedzwiecka, M., Colmegna, R. (2022). Swiss Dwellings v3.0.0. "
                     "Zenodo. doi:10.5281/zenodo.7788422. CC BY 4.0")
# ResPlan: licencia EN CONFLICTO dentro de su propio repositorio (LICENSE = CC BY 4.0;
# croissant.json y Kaggle = CC BY-NC-SA 4.0), autores no identificados y origen en renders
# de avisos inmobiliarios. No se usa para entrenar hasta que el responsable lo decida (D-29).
RESPLAN_LICENSE = "EN CONFLICTO: CC BY 4.0 (LICENSE) / CC BY-NC-SA 4.0 (croissant.json, Kaggle)"
RESPLAN_ATTRIBUTION = "ResPlan, github.com/m-agour/ResPlan (autores no publicados; ver D-29)"

# (entity_type, entity_subtype) de Swiss Dwellings → capa de STRUCTURA.
SWISS_LAYER = {
    ("separator", "WALL"): "wall",
    ("separator", "COLUMN"): "column",
    ("separator", "RAILING"): "railing",
    ("opening", "DOOR"): "door",
    ("opening", "ENTRANCE_DOOR"): "door",
    ("opening", "WINDOW"): "window",
    ("feature", "STAIRS"): "stairs",
}
# Artefactos que se dibujan como contexto (clase background): agregan "ruido" realista.
SWISS_FIXTURES = {"KITCHEN", "SINK", "TOILET", "BATHTUB", "SHOWER", "ELEVATOR", "BUILT_IN_FURNITURE",
                  "WASHING_MACHINE", "RAMP"}


@dataclass
class VectorPlan:
    plan_id: str
    project_id: str
    source: str
    license: str
    attribution: str
    meters_per_unit: float
    layers: dict[str, list[Any]]
    fixtures: list[tuple[str, Any]] = field(default_factory=list)
    rooms: list[tuple[str, Any]] = field(default_factory=list)
    origin: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Caché
# ---------------------------------------------------------------------------

def write_cache(path: Path, record: dict[str, Any]) -> None:
    record = {"format": CACHE_FORMAT, **record}
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with gzip.open(tmp, "wt", encoding="utf-8") as fh:
        json.dump(record, fh, ensure_ascii=False, separators=(",", ":"))
    tmp.replace(path)


def load_cached_plan(path: str | Path) -> VectorPlan:
    """Lee un plano de la caché y lo convierte a geometrías shapely."""
    from shapely import wkt as _wkt

    with gzip.open(path, "rt", encoding="utf-8") as fh:
        r = json.load(fh)
    if r.get("format") != CACHE_FORMAT:
        raise DatasetError(f"{path}: formato de caché desconocido {r.get('format')!r}")

    def geoms(items: Iterable[str]) -> list[Any]:
        out = []
        for s in items:
            g = _wkt.loads(s)
            if not g.is_empty:
                out.append(g if g.is_valid else g.buffer(0))
        return out

    layers = {k: geoms(r["layers"].get(k, [])) for k in LAYERS}
    fixtures = [(t, g) for t, s in r.get("fixtures", []) for g in geoms([s])]
    rooms = [(t, g) for t, s in r.get("rooms", []) for g in geoms([s])]
    return VectorPlan(r["plan_id"], r["project_id"], r["source"], r["license"], r["attribution"],
                      float(r.get("meters_per_unit", 1.0)), layers, fixtures, rooms, r.get("origin", {}))


def list_cache(cache_dir: str | Path) -> list[Path]:
    return sorted(Path(cache_dir).glob("*.json.gz"))


# ---------------------------------------------------------------------------
# Swiss Dwellings
# ---------------------------------------------------------------------------

def _swiss_rows(zip_path: Path) -> Iterator[dict[str, str]]:
    csv.field_size_limit(2**31 - 1)
    with zipfile.ZipFile(zip_path) as z:
        name = SWISS_CSV if SWISS_CSV in z.namelist() else next(
            (n for n in z.namelist() if n.endswith("geometries.csv")), None)
        if name is None:
            raise DatasetError(f"{zip_path}: no contiene geometries.csv")
        with z.open(name) as raw:
            yield from csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8", newline=""))


def index_swiss(zip_path: Path) -> dict[str, dict[str, Any]]:
    """Primera pasada (sin geometrías): metadatos y conteos por planta."""
    floors: dict[str, dict[str, Any]] = {}
    for d in _swiss_rows(zip_path):
        fid = d["floor_id"]
        f = floors.get(fid)
        if f is None:
            f = floors[fid] = {"floor_id": fid, "site_id": d["site_id"], "building_id": d["building_id"],
                               "plan_id": d["plan_id"], "counts": Counter()}
        layer = SWISS_LAYER.get((d["entity_type"], d["entity_subtype"]))
        if layer:
            f["counts"][layer] += 1
    return floors


def select_swiss_floors(floors: dict[str, dict[str, Any]], limit: int, seed: int = 42,
                        max_per_building: int = 2, min_walls: int = 20, column_share: float = 0.3) -> list[str]:
    """Elige plantas variadas: una por plan_id (las plantas tipo repiten geometría),
    a lo sumo ``max_per_building`` por edificio y repartidas entre sitios. Hasta
    ``column_share`` del total se reserva para plantas con columnas (clase escasa)."""
    rng = random.Random(seed)
    by_plan: dict[str, list[dict]] = defaultdict(list)
    for f in floors.values():
        if f["counts"]["wall"] >= min_walls and f["counts"]["door"] + f["counts"]["window"] > 0:
            by_plan[f["plan_id"]].append(f)
    candidates = [min(v, key=lambda f: int(f["floor_id"])) for v in by_plan.values()]
    chosen: list[str] = []
    per_building: Counter = Counter()

    def round_robin(pool: list[dict], quota: int) -> None:
        by_site: dict[str, list[dict]] = defaultdict(list)
        for f in pool:
            if f["floor_id"] not in taken:
                by_site[f["site_id"]].append(f)
        for v in by_site.values():
            v.sort(key=lambda f: int(f["floor_id"]))
            rng.shuffle(v)
        sites = sorted(by_site)
        rng.shuffle(sites)
        target = len(chosen) + quota
        while len(chosen) < target and any(by_site[s] for s in sites):
            for s in sites:  # ronda: una planta por sitio para maximizar diversidad
                while by_site[s]:
                    f = by_site[s].pop()
                    if per_building[f["building_id"]] < max_per_building:
                        per_building[f["building_id"]] += 1
                        chosen.append(f["floor_id"])
                        taken.add(f["floor_id"])
                        break
                if len(chosen) >= target:
                    break

    taken: set[str] = set()
    round_robin([f for f in candidates if f["counts"]["column"] > 0], int(limit * column_share))
    round_robin(candidates, limit - len(chosen))
    return chosen


def ingest_swiss(zip_path: Path, cache_dir: Path, limit: int, seed: int = 42,
                 floor_ids: list[str] | None = None) -> list[str]:
    """Dos pasadas sobre el CSV: índice → selección → geometrías de las plantas elegidas."""
    if floor_ids is None:
        floor_ids = select_swiss_floors(index_swiss(zip_path), limit, seed)
    wanted = set(floor_ids)
    rows: dict[str, dict[str, Any]] = {}
    for d in _swiss_rows(zip_path):
        fid = d["floor_id"]
        if fid not in wanted:
            continue
        r = rows.get(fid)
        if r is None:
            r = rows[fid] = {
                "plan_id": f"sd_f{fid}", "project_id": f"sd_site_{d['site_id']}", "source": "swiss_dwellings",
                "license": SWISS_LICENSE, "attribution": SWISS_ATTRIBUTION, "meters_per_unit": 1.0,
                "origin": {"floor_id": fid, "plan_id": d["plan_id"], "building_id": d["building_id"],
                           "site_id": d["site_id"]},
                "layers": {k: [] for k in LAYERS}, "fixtures": [], "rooms": [], "_seen": set(),
            }
        key = (d["entity_type"], d["entity_subtype"], d["geometry"])
        if key in r["_seen"]:  # muros compartidos entre departamentos aparecen repetidos
            continue
        r["_seen"].add(key)
        layer = SWISS_LAYER.get((d["entity_type"], d["entity_subtype"]))
        if layer:
            r["layers"][layer].append(d["geometry"])
        elif d["entity_type"] == "feature" and d["entity_subtype"] in SWISS_FIXTURES:
            r["fixtures"].append([d["entity_subtype"], d["geometry"]])
        elif d["entity_type"] == "area":
            r["rooms"].append([d["entity_subtype"], d["geometry"]])
    written = []
    for fid in floor_ids:
        r = rows.get(fid)
        if r is None:
            continue
        r.pop("_seen")
        write_cache(cache_dir / f"{r['plan_id']}.json.gz", r)
        written.append(r["plan_id"])
    return written


# ---------------------------------------------------------------------------
# ResPlan
# ---------------------------------------------------------------------------

class RestrictedUnpickler(pickle.Unpickler):
    """Solo reconstruye geometrías desde WKB y escalares numpy. Cualquier otra clase
    (os.system, subprocess, eval, ...) se rechaza antes de ejecutarse."""

    ALLOWED = {("shapely.io", "from_wkb"), ("numpy._core.multiarray", "scalar"),
               ("numpy.core.multiarray", "scalar"), ("numpy", "dtype")}

    def find_class(self, module: str, name: str):
        if (module, name) in self.ALLOWED:
            return super().find_class(module, name)
        raise pickle.UnpicklingError(f"clase no permitida en el pickle: {module}.{name}")


def load_resplan(pkl_path: Path) -> list[dict[str, Any]]:
    with open(pkl_path, "rb") as fh:
        data = RestrictedUnpickler(fh).load()
    if not isinstance(data, list):
        raise DatasetError(f"{pkl_path}: se esperaba una lista de planos")
    return data


def _parts(g: Any) -> list[Any]:
    if g is None or getattr(g, "is_empty", True):
        return []
    return [p for p in (g.geoms if hasattr(g, "geoms") else [g]) if p.geom_type == "Polygon" and p.area > 0]


RESPLAN_ROOMS = {"bathroom": "BATHROOM", "bedroom": "BEDROOM", "kitchen": "KITCHEN", "living": "LIVING_ROOM",
                 "storage": "STOREROOM", "balcony": "BALCONY", "garden": "GARDEN", "parking": "GARAGE"}


def resplan_record(p: dict[str, Any]) -> dict[str, Any] | None:
    """Plano de ResPlan → registro de caché. Las coordenadas vienen en unidades de imagen;
    la escala se deriva del área declarada (m²) frente al área de la huella."""
    from shapely.ops import unary_union

    p = dict(p)
    if "balacony" in p:
        p["balcony"] = p.pop("balacony")
    walls = _parts(p.get("wall"))
    if not walls or not p.get("area"):
        return None
    footprint = unary_union([g for k in ("inner", "wall", "door", "window") for g in _parts(p.get(k))])
    if footprint.is_empty or footprint.area <= 0:
        return None
    mpu = math.sqrt(float(p["area"]) / footprint.area)
    if not 0.005 < mpu < 1.0:
        return None
    pid = int(p["id"])
    return {
        "plan_id": f"rp_{pid}", "project_id": f"rp_{pid}", "source": "resplan", "license": RESPLAN_LICENSE,
        "attribution": RESPLAN_ATTRIBUTION, "meters_per_unit": mpu,
        "origin": {"resplan_id": pid, "area_m2": float(p["area"]), "wall_depth_units": float(p.get("wall_depth") or 0)},
        "layers": {
            "wall": [g.wkt for g in walls],
            "column": [],
            "door": [g.wkt for g in _parts(p.get("door")) + _parts(p.get("front_door"))],
            "window": [g.wkt for g in _parts(p.get("window"))],
            "stairs": [g.wkt for g in _parts(p.get("stair"))],
            "railing": [],
        },
        "fixtures": [],
        "rooms": [[t, g.wkt] for k, t in RESPLAN_ROOMS.items() for g in _parts(p.get(k))],
    }


def ingest_resplan(pkl_path: Path, cache_dir: Path, limit: int, seed: int = 42,
                   split_json: Path | None = None) -> list[str]:
    """Excluye los planos ``augmented`` (rotaciones/espejos de otros planos: fuga entre splits)."""
    excluded: set[int] = set()
    if split_json and Path(split_json).exists():
        excluded = {int(x) for x in json.loads(Path(split_json).read_text(encoding="utf-8")).get("augmented", [])}
    data = [p for p in load_resplan(pkl_path) if int(p["id"]) not in excluded]
    rng = random.Random(seed)
    # Los que tienen escalera primero (clase escasa), el resto al azar.
    with_stairs = [p for p in data if _parts(p.get("stair"))]
    others = [p for p in data if not _parts(p.get("stair"))]
    rng.shuffle(with_stairs)
    rng.shuffle(others)
    written = []
    for p in with_stairs + others:
        if len(written) >= limit:
            break
        rec = resplan_record(p)
        if rec is None:
            continue
        write_cache(cache_dir / f"{rec['plan_id']}.json.gz", rec)
        written.append(rec["plan_id"])
    return written


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Ingesta de planos vectoriales abiertos a la caché JSON.")
    sub = ap.add_subparsers(dest="source", required=True)
    s = sub.add_parser("swiss", help="Swiss Dwellings v3.0.0 (ZIP de Zenodo)")
    s.add_argument("--zip", required=True)
    s.add_argument("--cache", required=True)
    s.add_argument("--limit", type=int, default=1000)
    s.add_argument("--seed", type=int, default=42)
    r = sub.add_parser("resplan", help="ResPlan (ResPlan.pkl)")
    r.add_argument("--pkl", required=True)
    r.add_argument("--split-json")
    r.add_argument("--cache", required=True)
    r.add_argument("--limit", type=int, default=3000)
    r.add_argument("--seed", type=int, default=42)
    a = ap.parse_args(argv)
    try:
        if a.source == "swiss":
            out = ingest_swiss(Path(a.zip), Path(a.cache), a.limit, a.seed)
        else:
            out = ingest_resplan(Path(a.pkl), Path(a.cache), a.limit, a.seed,
                                 Path(a.split_json) if a.split_json else None)
    except DatasetError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    print(f"{len(out)} planos en {a.cache}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
