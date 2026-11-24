"""Cada test inyecta un defecto concreto en un dataset válido y exige que el
validador lo detecte con el código esperado."""
import shutil
import tempfile
from pathlib import Path

import numpy as np

from tools.common import decode_image, read_json, sha256_file, write_json, write_png
from tools.make_dataset_tiles import tile_plan
from tools.make_splits import make_splits
from tools.validate_dataset import main, validate_dataset_root
from tests.helpers import TempDirTestCase


SIZES = [(600, 520), (637, 531), (700, 560), (400, 300)]  # el último < tile → con relleno


def _blocks(rng, h, w, high, channels=None):
    """Imagen por bloques de 8 px: comprime bien y sigue teniendo bordes en todo el plano."""
    shape = (h // 8 + 1, w // 8 + 1) + ((channels,) if channels else ())
    small = rng.integers(0, high, shape, dtype=np.uint8)
    big = np.repeat(np.repeat(small, 8, axis=0), 8, axis=1)
    return np.ascontiguousarray(big[:h, :w])


class DatasetCase(TempDirTestCase):
    @classmethod
    def setUpClass(cls):
        cls._template = Path(tempfile.mkdtemp(prefix="structura_tpl_"))
        rng = np.random.default_rng(1)
        ds = cls._template / "dataset"
        for i, (w, h) in enumerate(SIZES):
            write_png(cls._template / f"p{i}.png", _blocks(rng, h, w, 255, 3))
            write_png(cls._template / f"p{i}_mask.png", _blocks(rng, h, w, 6))
            tile_plan(cls._template / f"p{i}.png", cls._template / f"p{i}_mask.png", ds,
                      {"source_plan_id": f"plan_{i}", "project_id": f"proj_{i}", "source_type": "digital"})
        make_splits(ds / "metadata", ds / "splits", train=0.5, validation=0.25, test=0.25)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._template, ignore_errors=True)

    def setUp(self):
        super().setUp()
        self.ds = self.root / "dataset"
        shutil.copytree(self._template / "dataset", self.ds)
        self.tiles = sorted(p.stem for p in (self.ds / "metadata").glob("*.json"))

    def codes(self):
        return validate_dataset_root(self.ds).codes()

    def tile(self, n=0):
        return self.tiles[n]

    def meta_path(self, tid):
        return self.ds / "metadata" / f"{tid}.json"

    def edit_meta(self, tid, **changes):
        m = read_json(self.meta_path(tid))
        for k, v in changes.items():
            if v is KeyError:
                m.pop(k)
            else:
                m[k] = v
        write_json(self.meta_path(tid), m)


class TestValidDataset(DatasetCase):
    def test_valid_dataset_passes(self):
        report = validate_dataset_root(self.ds)
        self.assertEqual(report.errors, [])
        self.assertEqual(report.stats["plans"], 4)
        self.assertEqual(sum(report.stats["split_tiles"].values()), len(self.tiles))

    def test_cli_exit_codes(self):
        self.assertEqual(main(["--dataset", str(self.ds), "--report", str(self.root / "r.json")]), 0)
        self.assertTrue(read_json(self.root / "r.json")["ok"])
        (self.ds / "masks" / f"{self.tile()}.png").unlink()
        self.assertEqual(main(["--dataset", str(self.ds)]), 1)

    def test_legacy_flags_still_work(self):
        rc = main(["--images", str(self.ds / "images"), "--masks", str(self.ds / "masks"),
                   "--metadata", str(self.ds / "metadata")])
        self.assertEqual(rc, 0)


class TestFileDefects(DatasetCase):
    def test_missing_image_and_mask(self):
        (self.ds / "images" / f"{self.tile(0)}.png").unlink()
        (self.ds / "masks" / f"{self.tile(1)}.png").unlink()
        self.assertTrue({"missing_image", "missing_mask"} <= self.codes())

    def test_orphan_metadata(self):
        tid = self.tile()
        (self.ds / "images" / f"{tid}.png").unlink()
        (self.ds / "masks" / f"{tid}.png").unlink()
        self.assertIn("orphan_metadata", self.codes())

    def test_corrupt_files(self):
        p = self.ds / "images" / f"{self.tile()}.png"
        p.write_bytes(p.read_bytes()[:200])  # PNG truncado
        q = self.ds / "masks" / f"{self.tile(1)}.png"
        q.write_bytes(b"")
        self.assertTrue({"corrupt_image", "corrupt_mask"} <= self.codes())

    def test_unexpected_extension_and_case_duplicate(self):
        shutil.copy(self.ds / "masks" / f"{self.tile()}.png", self.ds / "masks" / "extra.jpg")
        self.assertIn("unexpected_file", self.codes())

    def test_missing_metadata(self):
        self.meta_path(self.tile()).unlink()
        self.assertIn("missing_metadata", self.codes())


class TestContentDefects(DatasetCase):
    def test_size_mismatch(self):
        write_png(self.ds / "masks" / f"{self.tile()}.png", np.zeros((512, 511), np.uint8))
        self.assertIn("size_mismatch", self.codes())

    def test_multichannel_mask(self):
        write_png(self.ds / "masks" / f"{self.tile()}.png", np.zeros((512, 512, 3), np.uint8))
        self.assertIn("mask_multichannel", self.codes())

    def test_uint16_mask(self):
        write_png(self.ds / "masks" / f"{self.tile()}.png", np.zeros((512, 512), np.uint16))
        self.assertIn("mask_dtype", self.codes())

    def test_invalid_class_ids(self):
        m = decode_image(self.ds / "masks" / f"{self.tile()}.png")
        m[0, 0] = 7
        write_png(self.ds / "masks" / f"{self.tile()}.png", m)
        self.assertIn("invalid_class_ids", self.codes())

    def test_mask_edited_after_tiling(self):
        tid = self.tile()
        m = decode_image(self.ds / "masks" / f"{tid}.png")
        m[5, 5] = (m[5, 5] + 1) % 6
        write_png(self.ds / "masks" / f"{tid}.png", m)
        self.assertTrue({"mask_modified", "class_counts_mismatch"} <= self.codes())

    def test_padding_not_white(self):
        # Solo los planos menores que el tile (400x300) tienen relleno.
        tid = next(t for t in self.tiles if read_json(self.meta_path(t))["pad_right"] > 0)
        img = decode_image(self.ds / "images" / f"{tid}.png")
        img[0, -1] = (0, 0, 0)
        write_png(self.ds / "images" / f"{tid}.png", img)
        self.assertIn("padding_image", self.codes())

    def test_overlap_desync_detected_even_with_consistent_metadata(self):
        """Un tile alterado cuyo metadata se 'arregla' pasa los controles por tile,
        pero la reconstrucción del plano detecta la desincronización."""
        tid = next(t for t in self.tiles if read_json(self.meta_path(t))["x"] > 0)
        path = self.ds / "masks" / f"{tid}.png"
        m = decode_image(path)
        m[10, 2] = (m[10, 2] + 1) % 6  # dentro de la franja de solape con el tile izquierdo
        write_png(path, m)
        counts = np.bincount(m.ravel(), minlength=6).tolist()
        self.edit_meta(tid, mask_sha256=sha256_file(path), class_pixel_counts=counts)
        codes = self.codes()
        self.assertIn("overlap_desync", codes)
        self.assertNotIn("mask_modified", codes)


class TestMetadataDefects(DatasetCase):
    def test_missing_field(self):
        self.edit_meta(self.tile(), project_id=KeyError)
        self.assertIn("metadata_missing_field", self.codes())

    def test_string_boolean_rejected(self):
        self.edit_meta(self.tile(), scale_verified="false")  # error típico v0.2
        self.assertIn("metadata_bad_type", self.codes())

    def test_scale_verified_without_measurement(self):
        self.edit_meta(self.tile(), scale_verified=True)
        self.assertIn("scale_unverifiable", self.codes())

    def test_geometry_out_of_plan(self):
        self.edit_meta(self.tile(), x=10_000)
        self.assertIn("metadata_geometry", self.codes())

    def test_plan_in_two_projects(self):
        self.edit_meta(self.tile(), project_id="proj_otro")
        self.assertIn("cross_plan_inconsistency", self.codes())

    def test_same_source_image_under_two_plan_ids(self):
        other = read_json(self.meta_path(self.tiles[-1]))["source_image_sha256"]
        for tid in self.tiles:
            if read_json(self.meta_path(tid))["source_plan_id"] == "plan_0":
                self.edit_meta(tid, source_image_sha256=other)
        self.assertIn("cross_plan_inconsistency", self.codes())

    def test_stale_tile_not_in_plan_manifest(self):
        tid = self.tile()
        stale = tid.replace("_x000000", "_x000001")
        for sub, ext in (("images", ".png"), ("masks", ".png")):
            shutil.copy(self.ds / sub / f"{tid}{ext}", self.ds / sub / f"{stale}{ext}")
        m = read_json(self.meta_path(tid))
        m.update(tile_id=stale, x=1)
        write_json(self.meta_path(stale), m)
        self.assertIn("plan_tile_unlisted", self.codes())


class TestSplitDefects(DatasetCase):
    def splits(self, name):
        return (self.ds / "splits" / f"{name}.txt").read_text(encoding="utf-8").split()

    def test_tile_in_two_splits(self):
        leaked = self.splits("train")[0]
        with open(self.ds / "splits" / "test.txt", "a", encoding="utf-8") as fh:
            fh.write(leaked + "\n")
        self.assertTrue({"split_tile_leak", "split_group_leak"} <= self.codes())

    def test_unknown_and_duplicate_entries(self):
        with open(self.ds / "splits" / "validation.txt", "a", encoding="utf-8") as fh:
            fh.write("no_existe\n" + self.splits("validation")[0] + "\n")
        self.assertTrue({"split_unknown_tile", "split_duplicate"} <= self.codes())

    def test_missing_split_file(self):
        (self.ds / "splits" / "train.txt").unlink()
        self.assertIn("split_missing", self.codes())
