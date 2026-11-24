import unittest

import torch

from core.metrics import SegmentationMetrics


class TestConfusionMetrics(unittest.TestCase):
    def test_hand_computed_iou_precision_recall(self):
        gt = torch.tensor([[[0, 0, 1, 1], [0, 0, 1, 1]]])
        pr = torch.tensor([[[0, 1, 1, 1], [0, 0, 0, 1]]])
        m = SegmentationMetrics(3, ["bg", "wall", "door"], tolerance=0)
        m.update(pr, gt)
        r = m.compute()
        # bg: tp=3, gt=4, pred=4 → IoU 3/5; wall: tp=3, gt=4, pred=4 → 3/5
        self.assertAlmostEqual(r["per_class"]["bg"]["iou"], 0.6)
        self.assertAlmostEqual(r["per_class"]["wall"]["iou"], 0.6)
        self.assertAlmostEqual(r["per_class"]["wall"]["precision"], 0.75)
        self.assertAlmostEqual(r["per_class"]["wall"]["recall"], 0.75)
        self.assertIsNone(r["per_class"]["door"]["iou"])          # ausente: no entra en la media
        self.assertAlmostEqual(r["miou"], 0.6)
        self.assertEqual(r["confusion_matrix"], [[3, 1, 0], [1, 3, 0], [0, 0, 0]])

    def test_accumulates_over_batches_not_averaged(self):
        """Regresión del prototipo: el mIoU se promediaba por batch."""
        a_gt = torch.zeros(1, 4, 4, dtype=torch.long)
        a_gt[0, :2] = 1
        a_pr = a_gt.clone()
        b_gt = torch.zeros(1, 4, 4, dtype=torch.long)
        b_gt[0, 0, 0] = 1
        b_pr = torch.zeros(1, 4, 4, dtype=torch.long)    # falla el único píxel de pared
        m = SegmentationMetrics(2, tolerance=0)
        m.update(a_pr, a_gt)
        m.update(b_pr, b_gt)
        wall = m.compute()["per_class"]["1"]["iou"]
        self.assertAlmostEqual(wall, 8 / 9)               # global, no (1.0 + 0.0) / 2

    def test_boundary_f1_tolerance(self):
        gt = torch.zeros(1, 40, 40, dtype=torch.long)
        gt[0, 10:30, 10:30] = 1
        exact = SegmentationMetrics(2, tolerance=2)
        exact.update(gt.clone(), gt)
        self.assertAlmostEqual(exact.compute()["per_class"]["1"]["boundary_f1"], 1.0)
        shifted = torch.zeros_like(gt)
        shifted[0, 11:31, 11:31] = 1                       # 1 px: dentro de la tolerancia
        m = SegmentationMetrics(2, tolerance=2)
        m.update(shifted, gt)
        self.assertAlmostEqual(m.compute()["per_class"]["1"]["boundary_f1"], 1.0)
        far = torch.zeros_like(gt)
        far[0, 15:35, 15:35] = 1                           # 5 px: fuera
        m = SegmentationMetrics(2, tolerance=2)
        m.update(far, gt)
        self.assertLess(m.compute()["per_class"]["1"]["boundary_f1"], 0.6)

    def test_shape_mismatch(self):
        with self.assertRaises(ValueError):
            SegmentationMetrics(2).update(torch.zeros(1, 2, 2), torch.zeros(1, 3, 3))


if __name__ == "__main__":
    unittest.main()
