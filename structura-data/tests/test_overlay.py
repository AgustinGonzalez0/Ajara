import numpy as np

from tools.common import DatasetError, decode_image, write_png
from tools.make_overlay import main, overlay
from tests.helpers import TempDirTestCase


class TestOverlay(TempDirTestCase):
    def test_background_untouched_and_classes_colored(self):
        img = np.full((10, 10, 3), 200, np.uint8)
        mask = np.zeros((10, 10), np.uint8)
        mask[2:4, 2:4] = 1
        out = overlay(img, mask)
        self.assertTrue((out[mask == 0] == 200).all())
        self.assertFalse((out[mask == 1] == 200).all())
        with self.assertRaises(DatasetError):
            overlay(img, np.full((10, 10), 9, np.uint8))

    def test_cli(self):
        write_png(self.root / "p.png", np.full((8, 8, 3), 255, np.uint8))
        write_png(self.root / "m.png", np.ones((8, 8), np.uint8))
        self.assertEqual(main(["--image", str(self.root / "p.png"), "--mask", str(self.root / "m.png"),
                               "--output", str(self.root / "o.png")]), 0)
        self.assertEqual(decode_image(self.root / "o.png").shape, (8, 8, 3))
