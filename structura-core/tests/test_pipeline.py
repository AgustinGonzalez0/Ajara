"""Tests de entrenamiento, evaluación, inferencia y exportación ONNX (incluye paridad)."""
import csv
import json
import unittest

import numpy as np
import torch

from core import evaluate as evaluate_mod
from core import train as train_mod
from core.checkpoint import load_model, torch_predict_fn
from core.data import PlanDataset
from core.export_onnx import export
from core.io_utils import imread, imwrite, read_rgb
from core.predict import main as predict_main
from core.predict_onnx import main as predict_onnx_main, onnx_predict_fn
from core.tiling import predict_tiled
from tests.helpers import TempDirCase, make_tile_dataset, save_random_checkpoint


class TestIO(TempDirCase):
    def test_unicode_paths(self):
        p = self.root / "sub ñ" / "plano_año.png"
        imwrite(p, np.zeros((4, 5, 3), np.uint8))
        self.assertEqual(imread(p).shape, (4, 5, 3))
        self.assertEqual(read_rgb(p).shape, (4, 5, 3))

    def test_dataset_reads_test_split(self):
        ds = PlanDataset(make_tile_dataset(self.root / "ds", 1, 1, 2), "test")
        x, y = ds[0]
        self.assertEqual((tuple(x.shape), tuple(y.shape), y.dtype), ((3, 512, 512), (512, 512), torch.int64))


class TestTraining(TempDirCase):
    def run_train(self, device, epochs=2, **kw):
        ds = make_tile_dataset(self.root / "ds")
        out = self.root / f"run_{device}"
        args = train_mod.build_parser().parse_args(
            ["--dataset", str(ds), "--output", str(out), "--epochs", str(epochs), "--batch-size", "2",
             "--device", device, "--seed", "7"])
        for k, v in kw.items():
            setattr(args, k, v)
        return train_mod.train(args), out, ds

    def test_cpu_training_outputs(self):
        summary, out, ds = self.run_train("cpu", epochs=2)
        for f in ("best.pt", "latest.pt", "config.json", "train_log.csv", "best_val_metrics.json"):
            self.assertTrue((out / f).exists(), f)
        rows = list(csv.DictReader(open(out / "train_log.csv", encoding="utf-8")))
        self.assertEqual(len(rows), 2)
        for col in ("val_miou", "iou_wall", "val_mean_bf1_fg", "peak_mem_mb", "epoch_s"):
            self.assertIn(col, rows[0])
        cfg = json.loads((out / "config.json").read_text(encoding="utf-8"))
        self.assertEqual(cfg["loss"], "CrossEntropyLoss (sin pesos)")
        self.assertFalse(cfg["amp"])
        model, ckpt = load_model(out / "best.pt")
        self.assertEqual(ckpt["epoch"], summary["best_epoch"])

    def test_seed_reproducibility_cpu(self):
        _, out_a, _ = self.run_train("cpu", epochs=1)
        a = torch.load(out_a / "latest.pt", weights_only=True)["model"]
        (out_a / "latest.pt").rename(out_a / "first.pt")
        _, out_b, _ = self.run_train("cpu", epochs=1)
        b = torch.load(out_b / "latest.pt", weights_only=True)["model"]
        for k in a:
            torch.testing.assert_close(a[k], b[k])

    @unittest.skipUnless(torch.cuda.is_available(), "requiere CUDA")
    def test_cuda_amp_training_and_evaluation(self):
        summary, out, ds = self.run_train("cuda", epochs=2)
        cfg = json.loads((out / "config.json").read_text(encoding="utf-8"))
        self.assertTrue(cfg["amp"])
        rows = list(csv.DictReader(open(out / "train_log.csv", encoding="utf-8")))
        self.assertGreater(float(rows[-1]["peak_mem_mb"]), 0)
        args = type("A", (), dict(checkpoint=str(out / "best.pt"), dataset=str(ds), split="test",
                                  output=str(out), batch_size=2, device="cuda", no_amp=False))()
        report = evaluate_mod.evaluate(args)
        self.assertEqual(report["tiles"], 2)
        self.assertIsNotNone(report["metrics"]["miou"])
        self.assertGreater(report["benchmark"]["ms_median"], 0)
        self.assertTrue((out / "eval_test.md").exists())


class TestInferenceAndExport(TempDirCase):
    def test_large_image_tiled_prediction(self):
        ckpt = save_random_checkpoint(self.root / "rand.pt")
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        model, _ = load_model(ckpt, device)
        rgb = np.full((2300, 3100, 3), 255, np.uint8)
        res = predict_tiled(rgb, torch_predict_fn(model, device), 6, batch_size=4)
        self.assertEqual(res.labels.shape, (2300, 3100))
        self.assertEqual(res.num_tiles, 7 * 5)  # 3100 px: 6 + borde; 2300 px: 4 + borde

    def test_onnx_export_parity_and_metadata(self):
        ckpt = save_random_checkpoint(self.root / "rand.pt")
        onnx_path = self.root / "out" / "vision_ai.onnx"
        meta = export(ckpt, onnx_path, training_data="untrained", notes="test")
        self.assertLess(meta["parity"]["max_abs_logit_diff"], 1e-3)
        self.assertGreaterEqual(meta["parity"]["argmax_agreement_min"], 0.999)
        self.assertEqual(meta["opset"], 17)
        self.assertFalse(meta["training"]["production_ready"])
        saved = json.loads(onnx_path.with_suffix(".model.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["classes"][1], "wall")
        # ONNX y PyTorch dan el mismo resultado por tiles en una imagen no cuadrada
        import onnxruntime as ort
        sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
        model, _ = load_model(ckpt, "cpu")
        rgb = np.random.default_rng(1).integers(0, 255, (600, 700, 3), dtype=np.uint8)
        a = predict_tiled(rgb, torch_predict_fn(model, torch.device("cpu")), 6)
        b = predict_tiled(rgb, onnx_predict_fn(sess), 6)
        self.assertGreater(float((a.labels == b.labels).mean()), 0.999)

    def test_cli_predict_both_runtimes(self):
        ckpt = save_random_checkpoint(self.root / "rand.pt")
        export(ckpt, self.root / "m.onnx", training_data="untrained")
        imwrite(self.root / "plano ñ.png", np.full((700, 900, 3), 255, np.uint8))
        predict_main(["--model", str(ckpt), "--input", str(self.root / "plano ñ.png"),
                      "--output", str(self.root / "p1"), "--device", "cpu"])
        predict_onnx_main(["--model", str(self.root / "m.onnx"), "--input", str(self.root / "plano ñ.png"),
                           "--output", str(self.root / "p2")])
        for d in ("p1", "p2"):
            mask = imread(self.root / d / "mask.png", 0)
            self.assertEqual(mask.shape, (700, 900))
            self.assertTrue((self.root / d / "overlay.png").exists())
        info = json.loads((self.root / "p2" / "prediction.json").read_text(encoding="utf-8"))
        self.assertEqual(info["model_training"]["data"], "untrained")


if __name__ == "__main__":
    unittest.main()


class TestQuantization(TempDirCase):
    def test_int8_quantization_keeps_predictions(self):
        from core.quantize import quantize
        ds = make_tile_dataset(self.root / "ds", 4, 1, 2)
        ckpt = save_random_checkpoint(self.root / "rand.pt")
        fp32 = self.root / "m.onnx"
        export(ckpt, fp32, training_data="untrained")
        meta = quantize(fp32, ds, self.root / "m_int8.onnx", calib_tiles=4)
        q = meta["quantization"]
        self.assertLess(meta["bytes"], 0.4 * q["fp32_bytes"])
        self.assertGreater(q["argmax_agreement_mean"], 0.95)
        self.assertEqual(meta["training"]["data"], "untrained")  # hereda la procedencia
        saved = json.loads((self.root / "m_int8.model.json").read_text(encoding="utf-8"))
        self.assertTrue(saved["id"].endswith("_int8"))
