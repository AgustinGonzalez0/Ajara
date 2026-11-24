# STRUCTURA AI

**De una foto de un plano a un modelo 3D y una evaluación preliminar de sismo, tsunami y
viento, todo en el celular y sin conexión.**

- 📷 **Una sola foto**: detecta la hoja, corrige la perspectiva y la iluminación.
  También acepta PDF, PNG, JPG y TIFF.
- ⚡ **Motor clásico sin IA (por defecto)**: muros, puertas, ventanas y columnas en unos
  100 ms en cualquier celular. Es determinista, no descarga nada y no depende de tokens ni de APIs.
- 🧠 **Vision AI opcional**: una U-Net propia, cuantizada INT8 (1,9 MB), corrida con ONNX
  Runtime en el dispositivo. Hoy hay un modelo **de prueba** (entrenado con planos sintéticos).
- 🧊 **Modelo 3D** navegable (órbita, zoom, capas) y exportado a GLB.
- 🌊 **Evaluación preliminar**: indicadores demanda/capacidad, muros coloreados en 3D,
  vaivén sísmico y agua de tsunami animados. **No reemplaza el cálculo estructural ni declara
  que una estructura sea segura** (ver [`docs/SIMULACION.md`](docs/SIMULACION.md)).
- 🔒 **Privacidad**: el APK de release no tiene permiso de internet y la telemetría de ONNX
  Runtime está eliminada (verificado con `tool/verify_release.ps1`).

Estado y pendientes: [`docs/PROGRESS.md`](docs/PROGRESS.md) ·
Arquitectura: [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) ·
Decisiones: [`docs/DECISIONES.md`](docs/DECISIONES.md) ·
Entorno: [`docs/ENTORNO.md`](docs/ENTORNO.md)

## Flujo en la app
Nuevo proyecto → **Foto del plano** (o importar archivo) → ajustar esquinas → **Analizar**
(motor clásico) → revisar en el editor 2D → **Modelo 3D** → **Evaluar**: calibrar con una
cota, declarar pisos, material y espesor → resultados → **Ver en 3D**.

## Módulos
| Carpeta | Qué es | Tests |
|---|---|---|
| `structura-data` | Pipeline de dataset (Python): importación, LabelMe → máscaras, tiles, validación, splits | 85 |
| `structura-core` | Entrenamiento, evaluación, exportación ONNX y **cuantización INT8** de Vision AI (PyTorch + CUDA) | 18 |
| `packages/structura_model` | Building Model: procedencia, confianza, desconocidos explícitos | 5 |
| `packages/structura_vision` | **Visión clásica sin IA**: rectificación de fotos, binarización, detección | 6 |
| `packages/structura_geometry` | Geometry Engine: vectorización, malla 3D, GLB | 8 |
| `packages/structura_pipeline` | Integración IA: tiles, etapas, progreso, cancelación | 9 |
| `packages/structura_sim` | **Evaluación preliminar** de sismo, tsunami y viento | 9 |
| `structura-mobile` | App Android (Flutter) | 24, más 1 E2E en Android |

## Celulares compatibles
- Android 7.0 o superior (API 24), arm64-v8a y armeabi-v7a.
- APK arm64 de 56 MB.
- El motor clásico no necesita ninguna aceleración: los planos grandes se procesan a
  escala para acotar la memoria.
- La IA es opcional; si el dispositivo no puede ejecutarla, la app lo informa y usa el motor clásico.

## Instalación (Windows 11)
```powershell
cd C:\STRUCTURA
py -3.14 -m venv .venv          # 3.11 también sirve
.\.venv\Scripts\python.exe -m pip install torch==2.11.0 --index-url https://download.pytorch.org/whl/cu128
.\.venv\Scripts\python.exe -m pip install -r structura-core\requirements.txt -r structura-data\requirements.txt
cd structura-mobile; flutter pub get --offline
```

## Tests
```powershell
cd C:\STRUCTURA\structura-data;  ..\.venv\Scripts\python.exe -m unittest discover -s tests -t .
cd C:\STRUCTURA\structura-core;  ..\.venv\Scripts\python.exe -m unittest discover -s tests -t .
foreach ($p in "structura_model","structura_vision","structura_geometry","structura_pipeline","structura_sim") { cd C:\STRUCTURA\packages\$p; dart test }
cd C:\STRUCTURA\structura-mobile; flutter test
flutter test integration_test\device_e2e_test.dart -d emulator-5554     # Android
```

## Build Android
```powershell
cd C:\STRUCTURA\structura-mobile
flutter build apk --release --split-per-abi
powershell -File tool\verify_release.ps1     # sin red, sin telemetría, clases ONNX conservadas
```

## Modelo de IA (cuando haya datos reales)
```powershell
cd C:\STRUCTURA\structura-core
..\.venv\Scripts\python.exe -m core.train    --dataset ..\data\dataset --output ..\data\runs\vision_ai_0_1
..\.venv\Scripts\python.exe -m core.evaluate --checkpoint ..\data\runs\vision_ai_0_1\best.pt --dataset ..\data\dataset
..\.venv\Scripts\python.exe -m core.export_onnx --checkpoint ..\data\runs\vision_ai_0_1\best.pt --output ..\data\runs\vision_ai_0_1\vision_ai.onnx --training-data real
..\.venv\Scripts\python.exe -m core.quantize --model ..\data\runs\vision_ai_0_1\vision_ai.onnx --dataset ..\data\dataset --output ..\data\runs\vision_ai_0_1\vision_ai_int8.onnx
```
Copiar `*_int8.onnx` y `*_int8.model.json` a `structura-mobile/assets/models/`.
