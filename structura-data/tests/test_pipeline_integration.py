"""ETAPA 3 — prueba integral sobre un proyecto sintético.

LabelMe JSON → máscara PNG → tiles sincronizados → validación → splits.
Verifica coordenadas, IDs de clase, dimensiones, sincronización, ausencia de
fuga entre splits, compatibilidad con core/data.py y determinismo.
"""
import shutil
import tempfile
import unittest
from collections import defaultdict
from pathlib import Path

import numpy as np

from tools.build_dataset import build_dataset
from tools.common import DatasetError, decode_image, load_mask, read_json, read_registry
from tools.validate_dataset import validate_dataset_root
from tests.synthetic_demo import build_synthetic_project


class TestPipelineIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = Path(tempfile.mkdtemp(prefix="structura_e2e_"))
        cls.info = build_synthetic_project(cls._tmp / "proyecto sintético ñ")
        cls.ds = cls.info["dataset"]
        cls.manifest = cls.info["manifest"]
        cls.meta = {p.stem: read_json(p) for p in (cls.ds / "metadata").glob("*.json")}
        cls.splits = {s: (cls.ds / "splits" / f"{s}.txt").read_text(encoding="utf-8").split()
                      for s in ("train", "validation", "test")}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._tmp, ignore_errors=True)

    def test_plan_selection(self):
        self.assertEqual(len(self.manifest["plans_included"]), 11)
        self.assertEqual(self.manifest["plans_pending_annotation"], ["casa_07_sin_anotar"])
        self.assertEqual(self.manifest["plans_needs_review"], ["casa_08_dudoso"])
        self.assertIn("vivienda_04_p001", self.manifest["plans_included"])   # desde PDF
        self.assertIn("escaneo_05", self.manifest["plans_included"])         # desde JPG

    def test_full_masks_have_exact_class_ids(self):
        """La máscara generada coincide píxel a píxel con la esperada (cálculo independiente)."""
        for pid in self.manifest["plans_included"]:
            mask = load_mask(self.info["work"] / "masks" / f"{pid}.png")
            self.assertEqual(mask.dtype, np.uint8)
            np.testing.assert_array_equal(mask, self.info["expected"][pid], err_msg=pid)

    def test_tiles_reconstruct_source_exactly(self):
        """Sin pérdida de coordenadas: recomponer los tiles devuelve imagen y máscara originales."""
        rows, _ = read_registry(self.info["registry"])
        images = {r["source_plan_id"]: self.info["registry"].parent / r["image"] for r in rows}
        by_plan = defaultdict(list)
        for tid, m in self.meta.items():
            by_plan[m["source_plan_id"]].append(m)
        self.assertEqual(sorted(by_plan), sorted(self.manifest["plans_included"]))
        for pid, metas in by_plan.items():
            src_img = decode_image(images[pid])
            src_mask = load_mask(self.info["work"] / "masks" / f"{pid}.png")
            H, W = src_mask.shape
            rec_img = np.zeros_like(src_img)
            rec_mask = np.full((H, W), 255, np.uint8)
            for m in metas:
                ti = decode_image(self.ds / "images" / f"{m['tile_id']}.png")
                tm = decode_image(self.ds / "masks" / f"{m['tile_id']}.png")
                self.assertEqual((ti.shape, tm.shape, tm.dtype), ((512, 512, 3), (512, 512), np.uint8))
                x, y, w, h = m["x"], m["y"], m["width"], m["height"]
                # Sincronización: el tile es exactamente el recorte en las coordenadas declaradas.
                np.testing.assert_array_equal(tm[:h, :w], src_mask[y:y + h, x:x + w])
                np.testing.assert_array_equal(ti[:h, :w], src_img[y:y + h, x:x + w])
                self.assertTrue((tm[h:] == 0).all() and (tm[:, w:] == 0).all())
                self.assertTrue((ti[h:] == 255).all() and (ti[:, w:] == 255).all())
                rec_img[y:y + h, x:x + w] = ti[:h, :w]
                rec_mask[y:y + h, x:x + w] = tm[:h, :w]
            np.testing.assert_array_equal(rec_mask, src_mask, err_msg=pid)
            np.testing.assert_array_equal(rec_img, src_img, err_msg=pid)

    def test_metadata_provenance(self):
        for m in self.meta.values():
            self.assertIs(m["scale_verified"], False)
            self.assertEqual(m["units"], "unknown")
            self.assertIn(m["source_type"], ("digital", "scanned"))
        pdf_tiles = [m for m in self.meta.values() if m["source_plan_id"] == "vivienda_04_p001"]
        self.assertTrue(pdf_tiles and all(m["dpi"] == 144 and m["dpi_source"] == "pdf_render" for m in pdf_tiles))
        png_tiles = [m for m in self.meta.values() if m["source_plan_id"] == "casa_06"]
        self.assertTrue(all(m["dpi"] is None and m["dpi_source"] == "unknown" for m in png_tiles))

    def test_no_project_in_more_than_one_split(self):
        owner = defaultdict(set)
        for split, ids in self.splits.items():
            self.assertTrue(ids, f"{split} vacío")
            for tid in ids:
                owner[self.meta[tid]["project_id"]].add(split)
                owner["plan:" + self.meta[tid]["source_plan_id"]].add(split)
        self.assertTrue(all(len(v) == 1 for v in owner.values()), dict(owner))
        all_ids = [t for ids in self.splits.values() for t in ids]
        self.assertEqual(sorted(all_ids), sorted(self.meta))

    def test_validator_report_clean(self):
        report = validate_dataset_root(self.ds)
        self.assertEqual(report.errors, [])
        self.assertTrue(read_json(self.ds / "validation_report.json")["ok"])

    def test_core_prototype_compatibility(self):
        """Emula core/data.py (PlanDataset) sin torch: mismos nombres y contratos."""
        for split in ("train", "validation"):
            for name in self.splits[split]:
                image = decode_image(self.ds / "images" / f"{name}.png")
                mask = decode_image(self.ds / "masks" / f"{name}.png")
                self.assertEqual(image.shape, (512, 512, 3))
                self.assertEqual(mask.shape, (512, 512))
                self.assertTrue(0 <= int(mask.min()) and int(mask.max()) < 6)

    def test_standalone_tools_respect_needs_review(self):
        """Camino manual (labelme_to_mask CLI + tiler --registry): mismas exclusiones que el build."""
        from tools.labelme_to_mask import main as l2m_main
        from tools.make_dataset_tiles import tile_registry
        masks = self.info["root"] / "masks_standalone"
        self.assertEqual(l2m_main(["--input", str(self.info["annotations"]), "--output", str(masks)]), 0)
        out = self.info["root"] / "dataset_standalone"
        manifests = tile_registry(self.info["registry"], masks, out)
        plans = sorted(m["source_plan_id"] for m in manifests)
        self.assertEqual(plans, sorted(self.manifest["plans_included"]))
        self.assertNotIn("casa_08_dudoso", plans)

    def test_deterministic_rebuild_and_overwrite_guard(self):
        with self.assertRaises(DatasetError):
            build_dataset(self.info["registry"], self.info["annotations"], self.info["work"], self.ds, seed=42)
        out2 = self.info["root"] / "dataset_rebuild"
        build_dataset(self.info["registry"], self.info["annotations"], self.info["work"], out2, seed=42)
        for s, ids in self.splits.items():
            self.assertEqual((out2 / "splits" / f"{s}.txt").read_text(encoding="utf-8").split(), ids)
        for tid, m in self.meta.items():
            m2 = read_json(out2 / "metadata" / f"{tid}.json")
            self.assertEqual((m2["image_sha256"], m2["mask_sha256"]), (m["image_sha256"], m["mask_sha256"]))


if __name__ == "__main__":
    unittest.main()
