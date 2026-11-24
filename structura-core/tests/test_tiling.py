import unittest

import numpy as np

from core.tiling import blend_window, predict_tiled, tile_starts

STEP = 40  # la etiqueta se codifica en el canal R: valor = clase * 40


def oracle_fn(batch: np.ndarray) -> np.ndarray:
    """'Modelo' perfecto: lee la clase codificada en el canal R y devuelve logits one-hot."""
    labels = np.clip(np.rint(batch[:, 0] * 255 / STEP), 0, 5).astype(int)
    logits = np.full((batch.shape[0], 6) + batch.shape[2:], -10.0, np.float32)
    for c in range(6):
        logits[:, c][labels == c] = 10.0
    return logits


class TestTiling(unittest.TestCase):
    def test_starts_cover_axis(self):
        for n in (1, 300, 512, 513, 2000, 4097):
            covered = np.zeros(n, bool)
            for s in tile_starts(n, 512, 448):
                covered[s:s + 512] = True
            self.assertTrue(covered.all())

    def test_window_positive(self):
        w = blend_window(512, 64)
        self.assertGreater(w.min(), 0)
        self.assertEqual(w[256, 256], 1.0)

    def test_recomposition_is_exact_for_any_size(self):
        rng = np.random.default_rng(0)
        for (h, w) in ((200, 300), (512, 512), (700, 513), (1500, 2100)):
            with self.subTest(size=(h, w)):
                labels = np.repeat(np.repeat(rng.integers(0, 6, (h // 8 + 1, w // 8 + 1)), 8, 0), 8, 1)[:h, :w]
                rgb = np.zeros((h, w, 3), np.uint8)
                rgb[:, :, 0] = labels * STEP
                res = predict_tiled(rgb, oracle_fn, 6, batch_size=3)
                np.testing.assert_array_equal(res.labels, labels)
                self.assertEqual(res.labels.shape, (h, w))
                self.assertTrue((res.confidence > 0.99).all())

    def test_padding_never_leaks(self):
        # Imagen chica: el relleno blanco (R=255 → clase 5 para el oráculo) no debe aparecer.
        rgb = np.zeros((100, 120, 3), np.uint8)
        res = predict_tiled(rgb, oracle_fn, 6)
        self.assertEqual(res.labels.shape, (100, 120))
        self.assertTrue((res.labels == 0).all())

    def test_bad_output_shape(self):
        with self.assertRaises(ValueError):
            predict_tiled(np.zeros((10, 10, 3), np.uint8), lambda b: np.zeros((1, 2, 3, 3)), 6)


if __name__ == "__main__":
    unittest.main()
