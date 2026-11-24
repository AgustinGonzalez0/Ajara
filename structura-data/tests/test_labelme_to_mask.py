import base64
import json

import cv2
import numpy as np
from PIL import Image, ImageDraw

from tools.common import DatasetError, load_mask
from tools.labelme_to_mask import convert_labelme, main
from tests.helpers import TempDirTestCase
from tests.synthetic import labelme_json, make_plan, write_labelme, write_png_unicode


class LabelMeCase(TempDirTestCase):
    def make(self, shapes, w=64, h=48, flags=None, image_name="plan.png", json_image=None):
        write_png_unicode(self.root / image_name, np.full((h, w, 3), 255, np.uint8))
        jp = self.root / "plan.json"
        jp.write_text(json.dumps(labelme_json(json_image or image_name, w, h, shapes, flags)),
                      encoding="utf-8")
        return jp

    @staticmethod
    def shape(label, points, kind="polygon", **extra):
        return {"label": label, "points": points, "shape_type": kind, "flags": {}, **extra}


class TestGeometry(LabelMeCase):
    def test_output_contract(self):
        jp = self.make([self.shape("wall", [[2, 3], [20, 9]], "rectangle")])
        mask, report = convert_labelme(jp)
        self.assertEqual(mask.dtype, np.uint8)
        self.assertEqual(mask.shape, (48, 64))
        self.assertEqual(set(np.unique(mask)), {0, 1})
        # Bordes incluidos: (20-2+1) * (9-3+1)
        self.assertEqual(int((mask == 1).sum()), 19 * 7)
        self.assertEqual(report["class_pixel_counts"][1], 19 * 7)

    def test_parity_with_labelme_pil_rasterization(self):
        """LabelMe rasteriza con PIL ImageDraw.polygon. Bordes alineados a ejes: idéntico.
        Bordes oblicuos: solo pueden diferir píxeles del contorno (discretización ±1 px)."""
        rect = self.make([self.shape("wall", [[3, 4], [40, 4], [40, 30], [3, 30]])], w=64, h=64)
        im = Image.new("L", (64, 64), 0)
        ImageDraw.Draw(im).polygon([(3, 4), (40, 4), (40, 30), (3, 30)], outline=1, fill=1)
        np.testing.assert_array_equal(convert_labelme(rect)[0], np.asarray(im))

        rng = np.random.default_rng(7)
        kernel = np.ones((3, 3), np.uint8)
        for _ in range(25):
            pts = rng.integers(0, 60, (int(rng.integers(3, 7)), 2))
            hull = cv2.convexHull(pts.astype(np.int32)).reshape(-1, 2)
            if len(hull) < 3 or cv2.contourArea(hull) < 2:
                continue
            jp = self.make([self.shape("wall", hull.tolist())], w=64, h=64)
            mask, _ = convert_labelme(jp)
            im = Image.new("L", (64, 64), 0)
            ImageDraw.Draw(im).polygon([tuple(map(int, p)) for p in hull], outline=1, fill=1)
            ref = np.asarray(im)
            border = cv2.dilate(ref, kernel) != cv2.erode(ref, kernel)
            diff = mask != ref
            self.assertFalse((diff & ~border).any(), "diferencias fuera del contorno")
            self.assertLessEqual(int(diff.sum()), max(4, int(0.1 * ref.sum())))

    def test_circle_and_mask_shape(self):
        sub = np.zeros((5, 8), np.uint8)
        sub[1:4, 2:6] = 255
        ok, buf = cv2.imencode(".png", sub)
        b64 = base64.b64encode(buf.tobytes()).decode()
        jp = self.make([self.shape("column", [[30, 30], [34, 30]], "circle"),
                        self.shape("stairs", [[10, 10], [17, 14]], "mask", mask=b64)])
        mask, _ = convert_labelme(jp)
        self.assertEqual(mask[30, 30], 4)
        self.assertEqual(int((mask == 5).sum()), 12)
        self.assertTrue((mask[11:14, 12:16] == 5).all())

    def test_mask_shape_bbox_drift_is_warning(self):
        """LabelMe 7 abre archivos con recorte ≠ bbox; se ubica desde points[0] con aviso."""
        ok, buf = cv2.imencode(".png", np.full((3, 3), 255, np.uint8))
        jp = self.make([self.shape("stairs", [[2, 2], [9, 9]], "mask",
                                   mask=base64.b64encode(buf.tobytes()).decode())])
        mask, report = convert_labelme(jp)
        self.assertEqual(int((mask == 5).sum()), 9)
        self.assertTrue((mask[2:5, 2:5] == 5).all())
        self.assertTrue(any("bbox" in w for w in report["warnings"]))

    def test_oriented_rectangle_and_points(self):
        jp = self.make([self.shape("wall", [[10, 10], [30, 10], [30, 20], [10, 20]], "oriented_rectangle"),
                        self.shape("column", [[50, 30], [55, 40]], "points")])
        with self.assertRaisesRegex(DatasetError, "point-radius"):
            convert_labelme(jp)
        mask, _ = convert_labelme(jp, point_radius=2)
        self.assertEqual(int((mask == 1).sum()), 21 * 11)
        self.assertEqual((mask[30, 50], mask[40, 55]), (4, 4))

    def test_line_requires_explicit_width(self):
        jp = self.make([self.shape("wall", [[5, 5], [40, 5]], "line")])
        with self.assertRaisesRegex(DatasetError, "line-width"):
            convert_labelme(jp)
        mask, _ = convert_labelme(jp, line_width=3)
        self.assertEqual(int((mask[:, 20] == 1).sum()), 3)

    def test_degenerate_shapes_are_errors(self):
        # v0.2 descartaba en silencio polígonos de < 3 puntos.
        for shapes in ([self.shape("wall", [[1, 1], [5, 5]])],
                       [self.shape("wall", [[1, 1], [5, 5], [9, 9]])],
                       [self.shape("wall", [[1, 1]], "rectangle")],
                       [self.shape("wall", [[1, 1], [5, 5]], "hexagon")]):
            jp = self.make(shapes)
            with self.assertRaises(DatasetError):
                convert_labelme(jp)


class TestRealLabelMe7File(LabelMeCase):
    """fixtures/labelme7: JSON escrito por LabelMe 7.11 (write_label_file) y máscara de
    referencia rasterizada con el rasterizador de LabelMe (ver tests/fixtures/labelme7/README.md)."""

    def test_converts_real_labelme7_json(self):
        from pathlib import Path
        from tools.common import decode_image
        fx = Path(__file__).parent / "fixtures" / "labelme7"
        mask, report = convert_labelme(fx / "plan_lm7.json")
        ref = decode_image(fx / "plan_lm7_reference.png")
        self.assertEqual(report["labelme_version"], "7.11.0")
        self.assertEqual(report["image_flags"], {"needs_review": False, "partial": True})
        self.assertEqual(report["flagged_shapes"][0]["flags"], ["ambiguous"])
        # Exactos: rectángulo entero (window), polígono entero (wall) y shape 'mask' (stairs).
        for cid in (3, 5):
            self.assertEqual(int((mask == cid).sum()), int((ref == cid).sum()), cid)
        np.testing.assert_array_equal(mask[10:16, 5:20], ref[10:16, 5:20])
        # Coordenadas fraccionarias/círculos: diferencias solo en el contorno.
        kernel = np.ones((3, 3), np.uint8)
        diff = mask != ref
        border = np.zeros_like(diff)
        for cid in range(1, 6):
            layer = (ref == cid).astype(np.uint8)
            border |= cv2.dilate(layer, kernel) != cv2.erode(layer, kernel)
        self.assertFalse((diff & ~border).any())
        self.assertLess(int(diff.sum()), 0.03 * int((ref > 0).sum()))


class TestLabelsAndPolicy(LabelMeCase):
    def test_priority_policy_on_synthetic_plan(self):
        plan = make_plan(700, 540, seed=3)
        write_png_unicode(self.root / "p.png", plan.image)
        write_labelme(self.root / "p.json", "p.png", plan)
        mask, report = convert_labelme(self.root / "p.json")
        np.testing.assert_array_equal(mask, plan.expected)
        self.assertGreater(report["class_pixel_counts"][3], 0)  # ventana presente
        self.assertTrue(all(o["expected"] for o in report["overlaps"]))
        # Con la política v0.2 ("order") los muros dibujados después borran puerta y ventana.
        order_mask, _ = convert_labelme(self.root / "p.json", overlap_policy="order")
        self.assertEqual(int((order_mask == 3).sum()), 0)

    def test_unknown_and_background_labels(self):
        jp = self.make([self.shape("Wall ", [[1, 1], [9, 9]], "rectangle"),
                        self.shape("mueble", [[20, 20], [30, 30]], "rectangle")])
        with self.assertRaisesRegex(DatasetError, "mueble"):
            convert_labelme(jp)
        mask, report = convert_labelme(jp, unknown_label="ignore")
        self.assertEqual(mask[5, 5], 1)  # etiqueta normalizada a minúsculas
        self.assertTrue(any("mueble" in w for w in report["warnings"]))
        jp = self.make([self.shape("background", [[1, 1], [9, 9]], "rectangle")])
        with self.assertRaises(DatasetError):
            convert_labelme(jp)

    def test_conflicts_and_flags_reported(self):
        jp = self.make([self.shape("door", [[0, 0], [10, 10]], "rectangle"),
                        self.shape("window", [[5, 5], [15, 15]], "rectangle",
                                   flags={"ambiguous": True}, description="¿puerta-ventana?")],
                       flags={"needs_review": True, "partial": False})
        mask, report = convert_labelme(jp)
        self.assertEqual(mask[7, 7], 2)  # door > window
        self.assertTrue(report["needs_review"])
        self.assertEqual(report["flagged_shapes"][0]["flags"], ["ambiguous"])
        conflict = [o for o in report["overlaps"] if not o["expected"]]
        self.assertEqual(conflict[0]["pixels"], 36)
        self.assertEqual(conflict[0]["winner"], "door")


class TestImageMatching(LabelMeCase):
    def test_dimension_mismatch(self):
        write_png_unicode(self.root / "plan.png", np.full((48, 64, 3), 255, np.uint8))
        jp = self.root / "plan.json"
        jp.write_text(json.dumps(labelme_json("plan.png", 64, 50, [])), encoding="utf-8")
        with self.assertRaisesRegex(DatasetError, "imageHeight"):
            convert_labelme(jp)

    def test_windows_relative_image_path(self):
        (self.root / "raw").mkdir()
        write_png_unicode(self.root / "raw" / "plan.png", np.full((48, 64, 3), 255, np.uint8))
        ann = self.root / "ann"
        ann.mkdir()
        jp = ann / "plan.json"
        jp.write_text(json.dumps(labelme_json("..\\raw\\plan.png", 64, 48, [])), encoding="utf-8")
        mask, report = convert_labelme(jp)
        self.assertEqual(report["image_file"], "plan.png")

    def test_explicit_image_must_match_annotated_name(self):
        jp = self.make([], json_image="otro_plano.png")
        with self.assertRaisesRegex(DatasetError, "otro_plano"):
            convert_labelme(jp, image_path=self.root / "plan.png")

    def test_jpg_source_rejected(self):
        write_png_unicode(self.root / "plan.jpg", np.full((48, 64, 3), 255, np.uint8), ".jpg")
        jp = self.root / "plan.json"
        jp.write_text(json.dumps(labelme_json("plan.jpg", 64, 48, [])), encoding="utf-8")
        with self.assertRaisesRegex(DatasetError, "import_plans"):
            convert_labelme(jp)


class TestCLI(LabelMeCase):
    def test_cli_writes_mask_and_report(self):
        self.make([self.shape("wall", [[2, 3], [20, 9]], "rectangle")])
        out = self.root / "masks"
        self.assertEqual(main(["--input", str(self.root), "--output", str(out)]), 0)
        self.assertEqual(int((load_mask(out / "plan.png") == 1).sum()), 19 * 7)
        self.assertTrue((out / "plan.report.json").exists())
        self.assertEqual(main(["--input", str(self.root), "--output", str(out)]), 1)  # sin --overwrite
        self.assertEqual(main(["--input", str(self.root), "--output", str(out), "--overwrite"]), 0)
