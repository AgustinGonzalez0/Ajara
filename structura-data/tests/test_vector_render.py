"""Tests de fuentes vectoriales, renderizador y armado del dataset desde vectores."""
from __future__ import annotations

import csv
import io
import json
import math
import os
import pickle
import random
import tempfile
import unittest
import zipfile
from pathlib import Path

import numpy as np

try:
    import shapely  # noqa: F401
    from shapely import affinity
    from shapely.geometry import Polygon, box
    HAVE_SHAPELY = True
except ImportError:  # pragma: no cover
    HAVE_SHAPELY = False


def _rect(x0, y0, x1, y1):
    return box(x0, y0, x1, y1)


def box_plan_record(plan_id="sd_f1", project_id="sd_site_1", angle=0.0):
    """Planta de 8 × 6 m con muros de 0,2 m, una puerta, una ventana, una columna y una escalera."""
    walls = [_rect(0, 0, 8, 0.2), _rect(0, 5.8, 8, 6), _rect(0, 0, 0.2, 6), _rect(7.8, 0, 8, 6), _rect(4, 0.2, 4.2, 5.8)]
    door = _rect(1.5, 0, 2.4, 0.2)
    window = _rect(5.5, 5.8, 6.7, 6)
    column = _rect(7.4, 2.8, 7.8, 3.2)
    stairs = _rect(5, 1, 7, 2.2)
    room = _rect(0.2, 0.2, 4, 5.8)

    def rot(g):
        return affinity.rotate(g, angle, origin=(0, 0)).wkt if angle else g.wkt

    return {
        "plan_id": plan_id, "project_id": project_id, "source": "swiss_dwellings", "license": "CC BY 4.0",
        "attribution": "test", "meters_per_unit": 1.0, "origin": {},
        "layers": {"wall": [rot(w) for w in walls], "column": [rot(column)], "door": [rot(door)],
                   "window": [rot(window)], "stairs": [rot(stairs)], "railing": []},
        "fixtures": [["TOILET", rot(_rect(0.5, 4.5, 0.9, 5.2))]], "rooms": [["BEDROOM", rot(room)]],
    }


@unittest.skipUnless(HAVE_SHAPELY, "requiere shapely")
class TestRestrictedUnpickler(unittest.TestCase):
    def test_blocks_code_execution(self):
        from tools.vector_sources import RestrictedUnpickler

        class Evil:
            def __reduce__(self):
                return (os.system, ("echo pwned",))

        payload = pickle.dumps(Evil())
        with self.assertRaises(pickle.UnpicklingError):
            RestrictedUnpickler(io.BytesIO(payload)).load()

    def test_allows_shapely_geometries(self):
        from tools.vector_sources import RestrictedUnpickler

        data = [{"id": 3, "wall": _rect(0, 0, 1, 1), "area": 12.5}]
        back = RestrictedUnpickler(io.BytesIO(pickle.dumps(data))).load()
        self.assertTrue(back[0]["wall"].equals(_rect(0, 0, 1, 1)))


@unittest.skipUnless(HAVE_SHAPELY, "requiere shapely")
class TestSwissIngest(unittest.TestCase):
    def _zip(self, folder: Path) -> Path:
        header = ["apartment_id", "site_id", "building_id", "plan_id", "floor_id", "unit_id", "area_id", "unit_usage",
                  "entity_type", "entity_subtype", "geometry", "elevation", "height"]
        rows = []
        for apt in ("a1", "a2"):  # el muro compartido aparece en los dos departamentos
            rows.append([apt, "10", "100", "500", "7", "", "", "RESIDENTIAL", "separator", "WALL",
                         _rect(0, 0, 5, 0.2).wkt, "0", "2.6"])
        for i in range(25):
            rows.append(["a1", "10", "100", "500", "7", "", "", "RESIDENTIAL", "separator", "WALL",
                         _rect(i, 1, i + 0.2, 3).wkt, "0", "2.6"])
        rows.append(["a1", "10", "100", "500", "7", "", "", "RESIDENTIAL", "opening", "DOOR", _rect(1, 0, 2, 0.2).wkt, "0", "2"])
        rows.append(["a1", "10", "100", "500", "7", "", "", "RESIDENTIAL", "area", "KITCHEN", _rect(0, 0, 3, 3).wkt, "0", "2.6"])
        rows.append(["a1", "10", "100", "500", "7", "", "", "RESIDENTIAL", "feature", "SINK", _rect(0, 0, 0.5, 0.5).wkt, "0", "1"])
        # Otra planta del mismo plan_id (planta tipo): no se debe elegir dos veces.
        rows.append(["a3", "10", "100", "500", "8", "", "", "RESIDENTIAL", "separator", "WALL", _rect(0, 0, 5, 0.2).wkt, "3", "2.6"])
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(header)
        w.writerows(rows)
        z = folder / "swiss.zip"
        with zipfile.ZipFile(z, "w") as zf:
            zf.writestr("swiss-dwellings-v3.0.0/geometries.csv", buf.getvalue())
        return z

    def test_index_select_ingest_and_dedupe(self):
        from tools.vector_sources import index_swiss, ingest_swiss, list_cache, load_cached_plan, select_swiss_floors

        with tempfile.TemporaryDirectory() as td:
            z = self._zip(Path(td))
            floors = index_swiss(z)
            self.assertEqual(floors["7"]["counts"]["wall"], 27)
            chosen = select_swiss_floors(floors, 10)
            self.assertEqual(chosen, ["7"])  # la planta 8 tiene pocos muros y comparte plan_id
            written = ingest_swiss(z, Path(td) / "cache", 10)
            self.assertEqual(written, ["sd_f7"])
            plan = load_cached_plan(list_cache(Path(td) / "cache")[0])
            self.assertEqual(plan.project_id, "sd_site_10")
            self.assertEqual(len(plan.layers["wall"]), 26)  # muro compartido sin duplicar
            self.assertEqual(len(plan.layers["door"]), 1)
            self.assertEqual([t for t, _ in plan.fixtures], ["SINK"])
            self.assertEqual([t for t, _ in plan.rooms], ["KITCHEN"])


@unittest.skipUnless(HAVE_SHAPELY, "requiere shapely")
class TestRender(unittest.TestCase):
    def _plan(self, angle=0.0):
        from tools.vector_sources import load_cached_plan, write_cache

        td = tempfile.mkdtemp()
        p = Path(td) / "p.json.gz"
        write_cache(p, box_plan_record(angle=angle))
        return load_cached_plan(p)

    def test_dominant_angle_aligns_rotated_plans(self):
        from tools.render_vector_plans import dominant_angle, polys, prepare

        plan = self._plan(angle=23.0)
        walls = [p for g in plan.layers["wall"] for p in polys(g)]
        self.assertAlmostEqual(dominant_angle(walls), 23.0, delta=0.5)
        pr = prepare(plan)
        minx, miny, maxx, maxy = pr.bounds
        self.assertAlmostEqual(maxx - minx, 8.0, delta=0.15)  # quedó ortogonal a la hoja
        self.assertAlmostEqual(maxy - miny, 6.0, delta=0.15)

    def test_mask_is_exact_and_rendering_deterministic(self):
        from tools.render_vector_plans import Style, render_plan, sample_style

        plan = self._plan()
        st = sample_style(random.Random(0), px_per_m=50)
        st.tilt_deg, st.synthetic_columns, st.dimensions, st.grid_axes, st.title = 0.0, False, 0, False, False
        r = render_plan(plan, 1, style=Style(**vars(st)))
        self.assertEqual(r.image.shape[:2], r.mask.shape)
        self.assertEqual(r.image.dtype, np.uint8)
        self.assertEqual(set(np.unique(r.mask).tolist()), {0, 1, 2, 3, 4, 5})
        m = r.mask
        margin = (m.shape[1] - 8 * 50) // 2

        def at(x, y):  # coordenadas del plano (m, y hacia arriba) → píxel
            return int(m[int(round(margin + (6 - y) * 50)), int(round(margin + x * 50))])

        self.assertEqual(at(1.95, 0.1), 2)   # centro del vano de la puerta
        self.assertEqual(at(6.1, 5.9), 3)    # ventana
        self.assertEqual(at(7.6, 3.0), 4)    # columna sobre el muro (prioridad)
        self.assertEqual(at(6.0, 1.6), 5)    # escalera
        self.assertEqual(at(0.1, 3.0), 1)    # muro
        self.assertEqual(at(2.0, 3.0), 0)    # interior del ambiente
        # Área del vano: 0,9 × 0,2 m = 0,18 m² = 450 px a 50 px/m (± borde).
        self.assertAlmostEqual(int((m == 2).sum()), 450, delta=80)
        r2 = render_plan(plan, 1, style=Style(**vars(st)))
        self.assertTrue(np.array_equal(r.image, r2.image) and np.array_equal(r.mask, r2.mask))

    def test_door_convention_is_switchable(self):
        from tools.render_vector_plans import render_plan, sample_style

        plan = self._plan()
        st = sample_style(random.Random(3), px_per_m=50)
        st.door, st.tilt_deg = "arc", 0.0
        vano = render_plan(plan, 5, style=st, door_label="vano")
        st2 = sample_style(random.Random(3), px_per_m=50)
        st2.door, st2.tilt_deg = "arc", 0.0
        barrido = render_plan(plan, 5, style=st2, door_label="vano_y_barrido")
        self.assertGreater(int((barrido.mask == 2).sum()), 3 * int((vano.mask == 2).sum()))

    def test_synthetic_columns_at_thick_wall_ends(self):
        from tools.render_vector_plans import polys, prepare, synthetic_columns

        pr = prepare(self._plan())
        cols = synthetic_columns(pr.layers["wall"], random.Random(0), share=1.0)
        self.assertGreaterEqual(len(cols), 4)
        for c in cols:
            self.assertTrue(0.2 <= math.sqrt(c.area) <= 0.45)
            self.assertTrue(any(c.intersects(w) for w in pr.layers["wall"]))


@unittest.skipUnless(HAVE_SHAPELY, "requiere shapely")
class TestBuildVectorDataset(unittest.TestCase):
    def test_end_to_end_grouped_by_site(self):
        from tools.build_vector_dataset import build_vector_dataset
        from tools.common import DatasetError
        from tools.vector_sources import write_cache

        with tempfile.TemporaryDirectory() as td:
            cache = Path(td) / "cache"
            for i, site in enumerate(["1", "1", "2", "3", "4"]):
                write_cache(cache / f"sd_f{i}.json.gz", box_plan_record(f"sd_f{i}", f"sd_site_{site}", angle=7.0 * i))
            out = Path(td) / "ds"
            man = build_vector_dataset([cache], out, workers=1, variants=2, overwrite=True)
            self.assertEqual(man["plans"], 10)
            self.assertEqual(man["sources"], {"swiss_dwellings": 10})
            self.assertTrue((out / "ATTRIBUTION.md").exists())
            split = json.loads((out / "splits" / "split_manifest.json").read_text(encoding="utf-8"))
            owners = {}
            for s, groups in split["groups_by_split"].items():
                for g in groups:
                    owners.setdefault(g, set()).add(s)
            self.assertTrue(all(len(v) == 1 for v in owners.values()))  # un sitio, un split
            meta = json.loads(next((out / "metadata").glob("*.json")).read_text(encoding="utf-8"))
            self.assertEqual(meta["source_type"], "rendered")
            self.assertTrue(meta["scale_verified"])
            # ResPlan (licencia en conflicto) se rechaza salvo autorización explícita.
            write_cache(cache / "rp_9.json.gz", {**box_plan_record("rp_9", "rp_9"), "source": "resplan"})
            with self.assertRaises(DatasetError):
                build_vector_dataset([cache], Path(td) / "ds2", workers=1)


if __name__ == "__main__":
    unittest.main()
