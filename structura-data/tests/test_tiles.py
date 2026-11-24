import json

import numpy as np

from tools.common import DatasetError, decode_image, read_json, write_png
from tools.make_dataset_tiles import main, tile_plan, tile_starts
from tests.helpers import TempDirTestCase

PLAN = {"source_plan_id": "plan_a", "project_id": "proj_a", "source_type": "digital"}


def reconstruct(out, plan_id):
    """Recompone imagen y máscara desde los tiles usando solo los metadatos."""
    man = read_json(out / "plans" / f"{plan_id}.json")
    H, W = man["source_height"], man["source_width"]
    img = np.zeros((H, W, 3), np.uint8)
    mask = np.full((H, W), 255, np.uint8)
    for tid in man["tiles"]:
        m = read_json(out / "metadata" / f"{tid}.json")
        ti, tm = decode_image(out / "images" / f"{tid}.png"), decode_image(out / "masks" / f"{tid}.png")
        x, y, w, h = m["x"], m["y"], m["width"], m["height"]
        img[y:y + h, x:x + w] = ti[:h, :w]
        mask[y:y + h, x:x + w] = tm[:h, :w]
    return img, mask, man


class TestGrid(TempDirTestCase):
    def test_tile_starts_cover_axis(self):
        for length in (1, 300, 511, 512, 513, 960, 961, 1500, 4097):
            starts = tile_starts(length, 512, 448)
            covered = np.zeros(length, bool)
            for s in starts:
                covered[s:s + 512] = True
            self.assertTrue(covered.all(), length)
            self.assertEqual(starts[0], 0)
            self.assertTrue(all(b - a <= 448 for a, b in zip(starts, starts[1:])), length)
            if length >= 512:
                self.assertEqual(starts[-1], length - 512)


class TestTilePlan(TempDirTestCase):
    def make_inputs(self, w, h, seed=0):
        rng = np.random.default_rng(seed)
        image = rng.integers(0, 255, (h, w, 3), dtype=np.uint8)
        mask = rng.integers(0, 6, (h, w), dtype=np.uint8)
        write_png(self.root / "plan_a.png", image)
        write_png(self.root / "plan_a_mask.png", mask)
        return image, mask

    def test_exact_reconstruction_and_padding(self):
        for (w, h) in ((300, 200), (512, 512), (513, 700), (1201, 977)):
            with self.subTest(size=(w, h)):
                out = self.root / f"ds_{w}x{h}"
                image, mask = self.make_inputs(w, h)
                man = tile_plan(self.root / "plan_a.png", self.root / "plan_a_mask.png", out, PLAN)
                rec_img, rec_mask, _ = reconstruct(out, "plan_a")
                np.testing.assert_array_equal(rec_img, image)
                np.testing.assert_array_equal(rec_mask, mask)
                self.assertEqual(man["class_pixel_counts"], np.bincount(mask.ravel(), minlength=6).tolist())
                for tid in man["tiles"]:
                    meta = read_json(out / "metadata" / f"{tid}.json")
                    ti = decode_image(out / "images" / f"{tid}.png")
                    tm = decode_image(out / "masks" / f"{tid}.png")
                    self.assertEqual(ti.shape, (512, 512, 3))
                    self.assertEqual((tm.shape, tm.dtype), ((512, 512), np.uint8))
                    hh, ww = meta["height"], meta["width"]
                    self.assertTrue((ti[hh:] == 255).all() and (ti[:, ww:] == 255).all())
                    self.assertTrue((tm[hh:] == 0).all() and (tm[:, ww:] == 0).all())
                    np.testing.assert_array_equal(tm[:hh, :ww], mask[meta["y"]:meta["y"] + hh,
                                                                     meta["x"]:meta["x"] + ww])
                    self.assertEqual(tid, f"plan_a_x{meta['x']:06d}_y{meta['y']:06d}")

    def test_metadata_provenance_fields(self):
        self.make_inputs(600, 520)
        plan = {**PLAN, "scale_verified": "false", "dpi": 200, "dpi_source": "pdf_render"}
        man = tile_plan(self.root / "plan_a.png", self.root / "plan_a_mask.png", self.root / "ds", plan)
        meta = read_json(self.root / "ds" / "metadata" / f"{man['tiles'][-1]}.json")
        self.assertIs(meta["scale_verified"], False)  # v0.2: bool("false") → True
        for key in ("source_plan_id", "project_id", "source_type", "x", "y", "width", "height",
                    "source_width", "source_height", "dpi", "units", "scale_verified", "image_sha256"):
            self.assertIn(key, meta)
        self.assertEqual((meta["dpi"], meta["units"], meta["scale_px_per_unit"]), (200.0, "unknown", None))

    def test_rejects_invalid_inputs(self):
        self.make_inputs(100, 80)
        write_png(self.root / "bad_ids.png", np.full((80, 100), 9, np.uint8))
        write_png(self.root / "rgb_mask.png", np.zeros((80, 100, 3), np.uint8))
        write_png(self.root / "small_mask.png", np.zeros((79, 100), np.uint8))
        for mask_name in ("bad_ids.png", "rgb_mask.png", "small_mask.png"):
            with self.assertRaises(DatasetError, msg=mask_name):
                tile_plan(self.root / "plan_a.png", self.root / mask_name, self.root / "ds", PLAN)
        with self.assertRaises(DatasetError):
            tile_plan(self.root / "plan_a.png", self.root / "plan_a_mask.png", self.root / "ds",
                      {**PLAN, "source_plan_id": "plan con espacios"})
        with self.assertRaises(DatasetError):
            tile_plan(self.root / "plan_a.png", self.root / "plan_a_mask.png", self.root / "ds", PLAN,
                      tile=64, overlap=64)

    def test_overwrite_removes_stale_tiles(self):
        self.make_inputs(1000, 600)
        out = self.root / "ds"
        first = tile_plan(self.root / "plan_a.png", self.root / "plan_a_mask.png", out, PLAN, overlap=64)
        with self.assertRaises(DatasetError):
            tile_plan(self.root / "plan_a.png", self.root / "plan_a_mask.png", out, PLAN)
        second = tile_plan(self.root / "plan_a.png", self.root / "plan_a_mask.png", out, PLAN,
                           overlap=0, overwrite=True)
        self.assertNotEqual(first["tiles"], second["tiles"])
        self.assertEqual(sorted(p.stem for p in (out / "metadata").glob("*.json")), sorted(second["tiles"]))
        self.assertEqual(len(list((out / "images").glob("*.png"))), len(second["tiles"]))

    def test_min_foreground_ratio_records_skipped(self):
        image = np.full((512, 1100, 3), 255, np.uint8)
        mask = np.zeros((512, 1100), np.uint8)
        mask[10:50, 10:50] = 1
        write_png(self.root / "plan_a.png", image)
        write_png(self.root / "plan_a_mask.png", mask)
        man = tile_plan(self.root / "plan_a.png", self.root / "plan_a_mask.png", self.root / "ds", PLAN,
                        min_foreground_ratio=0.001)
        self.assertEqual(len(man["tiles"]), 1)
        self.assertEqual(len(man["skipped"]), len(man["grid_x"]) * len(man["grid_y"]) - 1)

    def test_cli_backward_compatible_with_v02_flags(self):
        self.make_inputs(700, 600)
        meta = self.root / "plan_meta.json"
        # Ejemplo literal del README v0.2 ("meters" se normaliza a "m").
        meta.write_text(json.dumps({"units": "meters", "scale_verified": False}), encoding="utf-8")
        rc = main(["--image", str(self.root / "plan_a.png"), "--mask", str(self.root / "plan_a_mask.png"),
                   "--output", str(self.root / "ds"), "--source-plan-id", "plan_a", "--project-id",
                   "proj_a", "--source-type", "scanned", "--tile", "512", "--overlap", "64",
                   "--metadata", str(meta)])
        self.assertEqual(rc, 0)
        self.assertEqual(len(list((self.root / "ds" / "metadata").glob("*.json"))), 4)
