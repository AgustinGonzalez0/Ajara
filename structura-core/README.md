# STRUCTURA CORE — Vision AI (entrenamiento)

Segmentación semántica de planos (U-Net Small, 6 clases, entrada RGB 512×512).
No es un sistema de ingeniería ni valida seguridad estructural.

## Especificación 0.1 (implementada)
U-Net Small · base 16 · 4 niveles · BatchNorm · CrossEntropy (sin pesos) · AdamW lr 1e-3 ·
40 épocas · batch 4 · AMP FP16 en CUDA · ONNX opset 17. La función de pérdida está en
revisión: ver `../docs/EVALUACION_LOSS.md`.

## Módulos
| Archivo | Función |
|---|---|
| `core/model.py` | U-Net Small (sin cambios respecto del prototipo) |
| `core/data.py` | Dataset de structura-data (train/validation/test), lectura Unicode-safe |
| `core/train.py` | AMP, semillas, CSV por época, mejor checkpoint por mIoU |
| `core/metrics.py` | Matriz de confusión acumulada: IoU, precision, recall, Boundary F1 por clase |
| `core/evaluate.py` | Informe JSON + Markdown en un split; tiempo de inferencia y memoria GPU |
| `core/tiling.py` | Inferencia por tiles (512/64, misma rejilla que el dataset) con recomposición ponderada |
| `core/predict.py` / `predict_onnx.py` | Inferencia de planos de cualquier tamaño (PyTorch / ONNX Runtime) |
| `core/export_onnx.py` | Exportación + verificación de paridad + `<modelo>.model.json` con procedencia |

## Uso (Windows)
```powershell
cd C:\STRUCTURA\structura-core
..\.venv\Scripts\python.exe -m core.train --dataset ..\data\dataset --output ..\data\runs\vision_ai_0_1
..\.venv\Scripts\python.exe -m core.evaluate --checkpoint ..\data\runs\vision_ai_0_1\best.pt --dataset ..\data\dataset --split test
..\.venv\Scripts\python.exe -m core.predict --model ..\data\runs\vision_ai_0_1\best.pt --input plano.png --output pred
..\.venv\Scripts\python.exe -m core.export_onnx --checkpoint ..\data\runs\vision_ai_0_1\best.pt --output ..\data\runs\vision_ai_0_1\vision_ai.onnx --training-data real
..\.venv\Scripts\python.exe -m unittest discover -s tests -t .
```
`--training-data` es obligatorio (`real|synthetic|untrained`) y queda grabado en los
metadatos: la app nunca presenta como apto un modelo sintético.

## Salidas de entrenamiento
`config.json`, `train_log.csv` (loss, mIoU, IoU por clase, BF1, tiempo y memoria por época),
`best.pt` (mejor mIoU), `latest.pt`, `best_val_metrics.json`. Los checkpoints se cargan con
`torch.load(weights_only=True)`.

## Resultado de referencia (dataset SINTÉTICO, solo para validar el pipeline)
40 épocas, RTX 5070: 0,4 s/época, 842 MB de memoria pico, inferencia 2,7 ms/tile (FP16).
Test: muros IoU 0,99, escaleras 0,99, **puertas/ventanas/columnas 0,00** (desbalance de
clases, ver `../docs/EVALUACION_LOSS.md`). No es un modelo útil para planos reales.
