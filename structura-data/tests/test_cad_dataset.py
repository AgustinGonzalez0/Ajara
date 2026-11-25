"""Dataset de ajuste fino desde CAD: píxeles ignorados, obras agrupadas y splits."""
import unittest

import numpy as np

from tools.build_cad_dataset import IGNORE, group_of, ignore_mask, split_of, tiles


class TestIgnoreMask(unittest.TestCase):
    def test_unlabeled_double_line_wall_is_ignored_labeled_wall_kept(self):
        rgb = np.full((200, 200, 3), 255, np.uint8)
        mask = np.zeros((200, 200), np.uint8)
        # Muro etiquetado (relleno) y muro sin capa dibujado con dos líneas a 10 px.
        rgb[40:50, 20:180] = 0
        mask[40:50, 20:180] = 1
        rgb[120, 20:180] = 0
        rgb[130, 20:180] = 0
        out = ignore_mask(rgb, mask, wall_px=10)
        self.assertTrue((out[42:48, 30:170] == 1).all())  # etiqueta intacta
        self.assertEqual(out[38, 100], IGNORE)  # anillo de borde incierto
        self.assertTrue((out[122:129, 40:160] == IGNORE).all())  # banda entre líneas
        self.assertEqual(out[180, 100], 0)  # papel: fondo confiable
        self.assertEqual(out[80, 100], 0)


class TestSplits(unittest.TestCase):
    def test_versions_of_the_same_building_share_a_group(self):
        self.assertEqual(group_of("P_F_Plano_municipal_72"), group_of("Inst_edificio_72_I_A"))
        self.assertEqual(group_of("copia_hipolito_yrigoyen"), group_of("Estructuras_CENTRO_CULTURAL_MMO_2024"))
        self.assertEqual(group_of("Casa_Sistemas_copia"), "casa_sistemas_copia")

    def test_explicit_groups_win_and_never_mix(self):
        tg, vg = {"centro_cultural"}, {"inst_electrica"}
        self.assertEqual(split_of("copia_hipolito_yrigoyen", 0.2, 0.1, tg, vg), "test")
        self.assertEqual(split_of("inst_electrica", 0.2, 0.1, tg, vg), "validation")
        self.assertEqual(split_of("pROyecto_municipal_72_3", 0.2, 0.1, tg, vg), "train")

    def test_tiles_cover_the_sheet(self):
        xs = sorted({x for x, _ in tiles(600, 1300)})
        self.assertEqual(xs[0], 0)
        self.assertEqual(xs[-1] + 512, 1300)
        self.assertTrue(all(b - a <= 448 for a, b in zip(xs, xs[1:])))
        self.assertEqual(tiles(300, 300), [(0, 0)])
