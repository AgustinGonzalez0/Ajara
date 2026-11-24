import unittest

import numpy as np

from tools.common import (
    DatasetError, composite_on_white, load_class_schema, load_mask, load_plan_image,
    normalize_plan_info, parse_bool, read_registry, validate_id, write_png, write_registry,
)
from tests.helpers import TempDirTestCase


class TestSchema(unittest.TestCase):
    def test_default_schema_matches_vision_ai_spec(self):
        s = load_class_schema()
        self.assertEqual(s.names, ("background", "wall", "door", "window", "column", "stairs"))
        self.assertEqual(s.num_classes, 6)
        self.assertEqual(s.priority[0], "wall")
        self.assertTrue(s.is_expected_overlap("wall", "door"))
        self.assertFalse(s.is_expected_overlap("door", "window"))


class TestSchemaErrors(TempDirTestCase):
    def _schema(self, text):
        p = self.root / "c.yaml"
        p.write_text(text, encoding="utf-8")
        return load_class_schema(p)

    def test_non_contiguous_ids_rejected(self):
        with self.assertRaises(DatasetError):
            self._schema("classes:\n  - {id: 0, name: background}\n  - {id: 2, name: wall}\n")

    def test_background_must_be_zero(self):
        with self.assertRaises(DatasetError):
            self._schema("classes:\n  - {id: 0, name: wall}\n  - {id: 1, name: background}\n")

    def test_priority_must_cover_classes(self):
        with self.assertRaises(DatasetError):
            self._schema("classes:\n  - {id: 0, name: background}\n  - {id: 1, name: wall}\n"
                         "  - {id: 2, name: door}\noverlap_priority: [wall]\n")


class TestValues(unittest.TestCase):
    def test_parse_bool_strict(self):
        # Regresión v0.2: bool("false") == True.
        self.assertIs(parse_bool("false"), False)
        self.assertIs(parse_bool("False "), False)
        self.assertIs(parse_bool(""), False)
        self.assertIs(parse_bool(None), False)
        self.assertIs(parse_bool("true"), True)
        self.assertIs(parse_bool("sí"), True)
        self.assertIs(parse_bool(1), True)
        with self.assertRaises(DatasetError):
            parse_bool("tal vez")
        with self.assertRaises(DatasetError):
            parse_bool(2)

    def test_validate_id(self):
        self.assertEqual(validate_id("plan_001-A", "id"), "plan_001-A")
        for bad in ("", "plan 1", "año", "_x", "a/b", "a" * 65, None, 5):
            with self.assertRaises(DatasetError, msg=repr(bad)):
                validate_id(bad, "id")

    def test_scale_cannot_be_verified_without_measurement(self):
        base = {"source_plan_id": "p1", "project_id": "pr1", "source_type": "digital"}
        info = normalize_plan_info(base)
        self.assertFalse(info["scale_verified"])
        self.assertEqual(info["units"], "unknown")
        self.assertIsNone(info["dpi"])
        with self.assertRaises(DatasetError):
            normalize_plan_info({**base, "scale_verified": "true"})
        with self.assertRaises(DatasetError):
            normalize_plan_info({**base, "scale_verified": "true", "units": "m"})
        ok = normalize_plan_info({**base, "scale_verified": "true", "units": "m", "scale_px_per_unit": "78,7"})
        self.assertAlmostEqual(ok["scale_px_per_unit"], 78.7)
        with self.assertRaises(DatasetError):
            normalize_plan_info({**base, "source_type": "cad"})
        with self.assertRaises(DatasetError):
            normalize_plan_info({**base, "dpi_source": "pdf_render"})


class TestImageIO(TempDirTestCase):
    def test_unicode_roundtrip(self):
        p = self.root / "sub carpeta ñ" / "planta_año.png"
        arr = np.random.default_rng(0).integers(0, 255, (7, 9, 3), dtype=np.uint8)
        write_png(p, arr)
        np.testing.assert_array_equal(load_plan_image(p), arr)

    def test_grayscale_and_alpha(self):
        gray = np.full((4, 4), 100, np.uint8)
        write_png(self.root / "g.png", gray)
        self.assertEqual(load_plan_image(self.root / "g.png").shape, (4, 4, 3))
        bgra = np.zeros((2, 2, 4), np.uint8)       # negro totalmente transparente
        bgra[0, 0] = (0, 0, 0, 255)                # un píxel negro opaco
        out = composite_on_white(bgra)
        self.assertEqual(out[0, 0].tolist(), [0, 0, 0])
        self.assertEqual(out[1, 1].tolist(), [255, 255, 255])  # v0.2 lo leía negro

    def test_mask_must_be_single_channel_uint8(self):
        write_png(self.root / "rgb.png", np.zeros((4, 4, 3), np.uint8))
        with self.assertRaises(DatasetError):
            load_mask(self.root / "rgb.png")
        write_png(self.root / "m16.png", np.zeros((4, 4), np.uint16))
        with self.assertRaises(DatasetError):
            load_mask(self.root / "m16.png")
        (self.root / "bad.png").write_bytes(b"\x89PNG\r\n\x1a\nbasura")
        with self.assertRaises(DatasetError):
            load_mask(self.root / "bad.png")


class TestRegistry(TempDirTestCase):
    def test_semicolon_csv_from_spanish_excel(self):
        p = self.root / "plans.csv"
        p.write_text("﻿source_plan_id;project_id;source_type;image\np1;pr1;digital;raw/p1.png\n",
                     encoding="utf-8")
        rows, delim = read_registry(p)
        self.assertEqual(delim, ";")
        self.assertEqual(rows[0]["project_id"], "pr1")
        write_registry(p, rows, delim)
        rows2, delim2 = read_registry(p)
        self.assertEqual((rows2[0]["image"], delim2), ("raw/p1.png", ";"))

    def test_missing_columns(self):
        p = self.root / "plans.csv"
        p.write_text("source_plan_id,image\np1,a.png\n", encoding="utf-8")
        with self.assertRaises(DatasetError):
            read_registry(p)


if __name__ == "__main__":
    unittest.main()
