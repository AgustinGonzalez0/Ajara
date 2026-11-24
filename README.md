# STRUCTURA AI

Interpretación local de planos arquitectónicos 2D y reconstrucción 3D editable.
Procesamiento en el dispositivo, sin servicios externos. **Reconstrucción geométrica, no
cálculo estructural.**

Estado actual y pendientes: [`docs/PROGRESS.md`](docs/PROGRESS.md) ·
Arquitectura: [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) ·
Decisiones: [`docs/DECISIONES.md`](docs/DECISIONES.md) ·
Entorno: [`docs/ENTORNO.md`](docs/ENTORNO.md)

## Módulos
| Carpeta | Qué es | Tests |
|---|---|---|
| `structura-data` | Pipeline de dataset (Python): importación, LabelMe→máscaras, tiles, validación, splits | 85 |
| `structura-core` | Entrenamiento/evaluación/exportación de Vision AI (PyTorch, CUDA) | 17 |
| `packages/structura_model` | Building Model (Dart puro) | 5 |
| `packages/structura_geometry` | Geometry Engine: vectorización, 3D, GLB (Dart puro) | 8 |
| `packages/structura_pipeline` | Integración CORE: tiles, etapas, progreso, cancelación (Dart puro) | 9 |
| `structura-mobile` | App Android (Flutter) | 23 + 1 E2E en Android |

## Instalación (Windows 11)

```powershell
# Python (PyTorch con CUDA 12.8: necesario para la RTX 5070 / Blackwell)
cd C:\STRUCTURA
py -3.14 -m venv .venv          # 3.11 también sirve si se instala
.\.venv\Scripts\python.exe -m pip install torch==2.11.0 --index-url https://download.pytorch.org/whl/cu128
.\.venv\Scripts\python.exe -m pip install -r structura-core\requirements.txt -r structura-data\requirements.txt
.\.venv\Scripts\python.exe -c "import torch; print(torch.cuda.is_available())"   # debe imprimir True

# Flutter (sin red hacia pub.dev se usa la caché local)
cd structura-mobile
flutter pub get --offline
```

## Ejecutar los tests

```powershell
cd C:\STRUCTURA\structura-data;  ..\.venv\Scripts\python.exe -m unittest discover -s tests -t .
cd C:\STRUCTURA\structura-core;  ..\.venv\Scripts\python.exe -m unittest discover -s tests -t .
cd C:\STRUCTURA\packages\structura_model;    dart test
cd C:\STRUCTURA\packages\structura_geometry; dart test
cd C:\STRUCTURA\packages\structura_pipeline; dart test
cd C:\STRUCTURA\structura-mobile;            flutter test
# Android (emulador o dispositivo conectado):
flutter test integration_test\device_e2e_test.dart -d emulator-5554
```

## Flujo de entrenamiento
```powershell
cd C:\STRUCTURA\structura-data
..\.venv\Scripts\python.exe -m tools.build_dataset --registry ..\data\work\plans.csv --annotations ..\data\annotations --work ..\data\work --output ..\data\dataset --overwrite
cd ..\structura-core
..\.venv\Scripts\python.exe -m core.train    --dataset ..\data\dataset --output ..\data\runs\vision_ai_0_1
..\.venv\Scripts\python.exe -m core.evaluate --checkpoint ..\data\runs\vision_ai_0_1\best.pt --dataset ..\data\dataset --split test
..\.venv\Scripts\python.exe -m core.export_onnx --checkpoint ..\data\runs\vision_ai_0_1\best.pt --output ..\data\runs\vision_ai_0_1\vision_ai.onnx --training-data real
```
El modelo exportado (`.onnx` + `.model.json`) se copia a `structura-mobile/assets/models/`.

## App Android
```powershell
cd C:\STRUCTURA\structura-mobile
flutter run -d <dispositivo>          # debug
flutter build apk --release           # release sin permiso INTERNET (ver D-05)
```
