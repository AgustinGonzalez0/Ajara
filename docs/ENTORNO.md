# Entorno de desarrollo (verificado el 2026-11-24)

| Componente | Estado | Detalle |
|---|---|---|
| Windows 11 Pro 26H2 | ✅ | |
| GPU | ✅ | RTX 5070 12 GB, driver 621.01, Blackwell sm_120 |
| Python | ⚠️ | Solo **3.14** (lanzador `py`). `python` = alias de Microsoft Store (no funciona). 3.11 no instalado |
| shapely / fonttools | ✅ | shapely 2.2 (geometría de datasets vectoriales), fonttools (cobertura de glifos del PDF) |
| PyTorch | ✅ | **2.11.0+cu128** en `STRUCTURA\.venv`; `cuda.is_available()=True`; arch list incluye sm_120; AMP FP16 verificado |
| ONNX / ONNX Runtime (PC) | ✅ | onnx 1.23.2, onnxruntime 1.32.0 |
| Flutter / Dart | ✅ | 3.47.1 stable / 3.13.1 |
| Android SDK | ✅ | platform 34–37, build-tools 36, NDK 28.2, cmdline-tools 23 |
| JDK | ✅ | JBR 25 de Android Studio (usado por Gradle); JDK 17 Microsoft en PATH |
| Gradle | ✅ | 9.3.1 en caché; AGP 9.1.0; Kotlin 2.4.0 |
| Licencias Android | ⚠️ | `flutter doctor` las reporta "unknown" (no bloqueó compilaciones). Ejecutar: `flutter doctor --android-licenses` |
| Emulador | ✅ | AVD `Pixel_9` (Android 17, x86_64, páginas 16 KB), WHPX disponible |
| Dispositivo físico | ❌ | Ningún dispositivo conectado (Galaxy S26 Ultra pendiente) |

## Red
Desde el 2026-11-24 hay conexión completa (pub.dev, Gradle, Maven, Zenodo, GitHub, Hugging Face,
Kaggle). En sesiones anteriores pub.dev y los repositorios de Gradle estaban bloqueados; por eso
algunas decisiones viejas (visor 3D propio, PdfRenderer nativo) se tomaron sin paquetes externos.
Con la red disponible se sumaron `share_plus` y `pdf` (ver DECISIONES.md).

## Ubicación del proyecto
El monorepo está en `%USERPROFILE%\Desktop\STRUCTURA` (antes `C:\STRUCTURA`). El venv de Python
se movió con él y funciona (`python -m ...`); los ejecutables auxiliares del venv (`pip.exe`)
guardan la ruta vieja: usar `.venv\Scripts\python.exe -m pip`.

## Comandos de verificación
```powershell
flutter doctor -v
$env:USERPROFILE\Desktop\STRUCTURA\.venv\Scripts\python.exe -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_arch_list())"
C:\Users\Agusr\AppData\Local\Android\sdk\emulator\emulator.exe -list-avds
```
