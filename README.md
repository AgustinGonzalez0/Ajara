# STRUCTURA AI

**De una foto de un plano a un modelo 3D y una evaluación preliminar de sismo, tsunami y
viento, todo en el celular y sin conexión.**

- 📷 **Una sola foto**: detecta la hoja, corrige la perspectiva y la iluminación.
  También acepta PDF, PNG, JPG y TIFF.
- ⚡ **Motor clásico sin IA (por defecto)**: muros, puertas, ventanas y columnas en unos
  100 ms en cualquier celular. Es determinista, no descarga nada y no depende de tokens ni de APIs.
- 🧠 **Vision AI** (se elige en Configuración): U-Net propia de 1,9 MB (INT8) con ONNX Runtime en el
  dispositivo, entrenada con 1 499 plantas reales (Swiss Dwellings, CC BY 4.0) dibujadas con estilos
  variados: mIoU 0,89 en test frente a 0,25 del motor clásico. **En validación**: falta medirla con
  fotos de planos reales. Las simulaciones no usan IA: son fórmulas deterministas.
- 🧊 **Modelo 3D detallado** navegable (órbita, zoom, capas) y exportado a GLB: cierra esquinas,
  alinea muros, encaja aberturas y arma el piso solo dentro de los ambientes.
- 🌊 **Evaluación preliminar**: indicadores demanda/capacidad, muros coloreados en 3D,
  vaivén sísmico y agua de tsunami animados. **No reemplaza el cálculo estructural ni declara
  que una estructura sea segura** (ver [`docs/SIMULACION.md`](docs/SIMULACION.md)).
- 🔒 **Privacidad**: el APK de release no tiene permiso de internet y la telemetría de ONNX
  Runtime está eliminada (verificado con `tool/verify_release.ps1`).

Estado y pendientes: [`docs/PROGRESS.md`](docs/PROGRESS.md) ·
Arquitectura: [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) ·
Decisiones: [`docs/DECISIONES.md`](docs/DECISIONES.md) ·
Entorno: [`docs/ENTORNO.md`](docs/ENTORNO.md) ·
Presentar el proyecto: [`docs/GUIA_DEMO.md`](docs/GUIA_DEMO.md)

## Flujo en la app (pocos toques)
**Fotografiar plano** → confirmar el recorte (**Generar modelo 3D**) → el 3D aparece solo →
**Evaluar sismo, tsunami y viento** (marcar una cota la primera vez) → resultados en semáforo →
**Compartir informe PDF**. Las detecciones se corrigen tocándolas en "Plano".

## Módulos
| Carpeta | Qué es | Tests |
|---|---|---|
| `structura-data` | Datasets (Python): LabelMe, planos vectoriales renderizados, DXF de AutoCAD, tiles, validación, splits | 93 |
| `structura-core` | Entrenamiento, evaluación, benchmark, exportación ONNX y **cuantización INT8** (PyTorch + CUDA) | 22 |
| `packages/structura_model` | Building Model: procedencia, confianza, desconocidos explícitos | 5 |
| `packages/structura_vision` | **Visión clásica sin IA**: rectificación de fotos, binarización, detección | 6 |
| `packages/structura_geometry` | Geometry Engine: vectorización, **afinado del 3D**, malla, piso interior, GLB | 19 |
| `packages/structura_pipeline` | Integración IA: tiles, TTA, etapas, progreso, cancelación | 10 |
| `packages/structura_sim` | **Evaluación preliminar** de sismo, tsunami y viento | 9 |
| `structura-mobile` | App Android (Flutter) | 34, más 1 E2E en Android |

## Celulares compatibles
- Android 7.0 o superior (API 24), arm64-v8a y armeabi-v7a.
- APK arm64 de 57,5 MB (45,7 MB en armeabi-v7a). Probada en un Galaxy S26 Ultra (Android 17).
- El motor clásico no necesita ninguna aceleración: los planos grandes se procesan a
  escala para acotar la memoria.
- La IA es opcional; si el dispositivo no puede ejecutarla, la app lo informa y usa el motor clásico.

## Abrir y ejecutar en Android Studio (celular por USB)
1. En el celular: **Ajustes → Acerca del teléfono → Información de software** → tocar 7 veces
   "Número de compilación". Después **Opciones de desarrollador → Depuración por USB** activada.
   Conectar por USB y aceptar "Permitir depuración".
2. Android Studio → **Open** → elegir la carpeta `Ajara\structura-mobile` (no la raíz).
   Ya tiene los plugins Flutter y Dart; si pregunta por el SDK de Flutter: `C:\Users\Agusr\flutter`.
3. Arriba, en el selector de dispositivos, elegir el celular (p. ej. "SM-S948B").
4. **Run ▶** (`main.dart`). Para medir velocidad real usar *Run → Flutter Run 'main.dart' in Release Mode*
   (el modo debug es varias veces más lento, sobre todo la IA).

Desde la terminal es equivalente: `cd structura-mobile; flutter run --release`.

## Instalación (Windows 11)
```powershell
cd $env:USERPROFILE\Desktop\Ajara
py -3.14 -m venv .venv          # 3.11 también sirve
.\.venv\Scripts\python.exe -m pip install torch==2.11.0 --index-url https://download.pytorch.org/whl/cu128
.\.venv\Scripts\python.exe -m pip install -r structura-core\requirements.txt -r structura-data\requirements.txt
cd structura-mobile; flutter pub get --offline
```

## Tests
```powershell
cd $env:USERPROFILE\Desktop\Ajara\structura-data;  ..\.venv\Scripts\python.exe -m unittest discover -s tests -t .
cd $env:USERPROFILE\Desktop\Ajara\structura-core;  ..\.venv\Scripts\python.exe -m unittest discover -s tests -t .
foreach ($p in "structura_model","structura_vision","structura_geometry","structura_pipeline","structura_sim") { cd $env:USERPROFILE\Desktop\Ajara\packages\$p; dart test }
cd $env:USERPROFILE\Desktop\Ajara\structura-mobile; flutter test
flutter test integration_test\device_e2e_test.dart -d emulator-5554     # Android
```

## Build Android
```powershell
cd $env:USERPROFILE\Desktop\Ajara\structura-mobile
flutter build apk --release --split-per-abi
powershell -File tool\verify_release.ps1     # sin red, sin telemetría, clases ONNX conservadas
```

## Modelo de IA (cuando haya datos reales)
```powershell
cd $env:USERPROFILE\Desktop\Ajara\structura-core
..\.venv\Scripts\python.exe -m core.train    --dataset ..\data\dataset --output ..\data\runs\vision_ai_0_1
..\.venv\Scripts\python.exe -m core.evaluate --checkpoint ..\data\runs\vision_ai_0_1\best.pt --dataset ..\data\dataset
..\.venv\Scripts\python.exe -m core.export_onnx --checkpoint ..\data\runs\vision_ai_0_1\best.pt --output ..\data\runs\vision_ai_0_1\vision_ai.onnx --training-data real
..\.venv\Scripts\python.exe -m core.quantize --model ..\data\runs\vision_ai_0_1\vision_ai.onnx --dataset ..\data\dataset --output ..\data\runs\vision_ai_0_1\vision_ai_int8.onnx
```
Copiar `*_int8.onnx` y `*_int8.model.json` a `structura-mobile/assets/models/`.
