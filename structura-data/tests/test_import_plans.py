import numpy as np
import pymupdf
from PIL import Image

from tools.common import DatasetError, load_plan_image, read_registry, write_registry
from tools.import_plans import collect_inputs, import_plans, main, parse_pages, sanitize_id
from tests.helpers import TempDirTestCase


def make_pdf(path, pages=2, size=(300, 200)):
    doc = pymupdf.open()
    for i in range(pages):
        page = doc.new_page(width=size[0], height=size[1])
        page.draw_rect(pymupdf.Rect(50, 40 + i * 20, 110, 52 + i * 20), color=(0, 0, 0), fill=(0, 0, 0))
    doc.save(str(path))
    doc.close()


class TestHelpers(TempDirTestCase):
    def test_sanitize_and_pages(self):
        self.assertEqual(sanitize_id("Planta Baja (año 2020)"), "Planta_Baja_ano_2020")
        self.assertEqual(parse_pages("1,3-4", 5), [0, 2, 3])
        with self.assertRaises(DatasetError):
            parse_pages("6", 5)
        with self.assertRaises(DatasetError):
            sanitize_id("¿¿??")


class TestImport(TempDirTestCase):
    def run_import(self, src, **kw):
        opts = dict(project_id="proj_a", source_type="digital", output_dir=self.root / "raw",
                    registry=self.root / "plans.csv")
        opts.update(kw)
        return import_plans(collect_inputs(src), **opts)

    def test_pdf_render_is_spatially_exact(self):
        make_pdf(self.root / "Planta año.pdf")
        rows = self.run_import(self.root / "Planta año.pdf", dpi=144)
        self.assertEqual([r["source_plan_id"] for r in rows], ["Planta_ano_p001", "Planta_ano_p002"])
        img = load_plan_image(self.root / "raw" / "Planta_ano_p001.png")
        self.assertEqual(img.shape, (400, 600, 3))          # 300x200 pt a 144 DPI
        self.assertLess(img[80:104, 100:220].mean(), 10)    # rectángulo negro ×2
        self.assertEqual(img[10:30, 10:30].min(), 255)      # papel blanco
        reg, _ = read_registry(self.root / "plans.csv")
        self.assertEqual((reg[0]["dpi"], reg[0]["dpi_source"], reg[0]["scale_verified"]),
                         ("144", "pdf_render", "false"))
        self.assertEqual(reg[1]["source_page"], "2")

    def test_raster_normalization(self):
        # EXIF orientación 6 (rotar 90°): 40x20 → 20x40
        im = Image.new("RGB", (40, 20), (200, 0, 0))
        exif = Image.Exif()
        exif[0x0112] = 6
        im.save(self.root / "foto.jpg", exif=exif.tobytes(), dpi=(300, 300))
        # Transparencia → blanco; 16 bits → 8 bits
        rgba = np.zeros((10, 10, 4), np.uint8)
        rgba[0, 0] = (0, 0, 0, 255)
        Image.fromarray(rgba, "RGBA").save(self.root / "alpha.png")
        Image.fromarray(np.full((6, 6), 65535, np.uint16)).save(self.root / "scan16.png")
        rows = {r["source_plan_id"]: r for r in self.run_import(self.root, source_type="scanned")}
        self.assertEqual(load_plan_image(self.root / "raw" / "foto.png").shape[:2], (40, 20))
        self.assertEqual((rows["foto"]["dpi"], rows["foto"]["dpi_source"]), ("300", "file_header"))
        a = load_plan_image(self.root / "raw" / "alpha.png")
        self.assertEqual((a[0, 0].tolist(), a[5, 5].tolist()), ([0, 0, 0], [255, 255, 255]))
        self.assertEqual(load_plan_image(self.root / "raw" / "scan16.png").min(), 255)
        self.assertEqual(rows["alpha"]["dpi_source"], "unknown")

    def test_multipage_tiff_rejected(self):
        pages = [Image.new("RGB", (20, 20), "white") for _ in range(3)]
        pages[0].save(self.root / "scan.tif", save_all=True, append_images=pages[1:])
        with self.assertRaisesRegex(DatasetError, "3 páginas"):
            self.run_import(self.root / "scan.tif")

    def test_duplicates_and_overwrite(self):
        Image.new("RGB", (30, 30), "white").save(self.root / "a.png")
        self.run_import(self.root / "a.png")
        with self.assertRaisesRegex(DatasetError, "--overwrite"):
            self.run_import(self.root / "a.png")
        with self.assertRaisesRegex(DatasetError, "ya está importado"):
            self.run_import(self.root / "a.png", plan_id="otro_id")
        # --overwrite conserva columnas cargadas a mano (anotación, escala)
        rows, d = read_registry(self.root / "plans.csv")
        rows[0].update(annotation="ann/a.json", units="m")
        write_registry(self.root / "plans.csv", rows, d)
        self.run_import(self.root / "a.png", overwrite=True)
        rows, _ = read_registry(self.root / "plans.csv")
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["annotation"], rows[0]["units"]), ("ann/a.json", "m"))

    def test_cli(self):
        make_pdf(self.root / "p.pdf", pages=3)
        rc = main(["--input", str(self.root / "p.pdf"), "--project-id", "proj_b", "--source-type",
                   "digital", "--output-dir", str(self.root / "raw"), "--registry",
                   str(self.root / "plans.csv"), "--pages", "2", "--dpi", "100"])
        self.assertEqual(rc, 0)
        rows, _ = read_registry(self.root / "plans.csv")
        self.assertEqual([r["source_plan_id"] for r in rows], ["p_p002"])
        self.assertEqual(main(["--input", str(self.root / "nada"), "--project-id", "x",
                               "--source-type", "digital", "--output-dir", "o", "--registry", "r.csv"]), 1)
