# Entorno de desarrollo (verificado el 2026-11-24)

| Componente | Estado | Detalle |
|---|---|---|
| Windows 11 Pro 26H2 | ✅ | |
| GPU | ✅ | RTX 5070 12 GB, driver 621.01, Blackwell sm_120 |
| Python | ⚠️ | Solo **3.14** (lanzador `py`). `python` = alias de Microsoft Store (no funciona). 3.11 no instalado |
| PyTorch | ✅ | **2.11.0+cu128** en `C:\STRUCTURA\.venv`; `cuda.is_available()=True`; arch list incluye sm_120; AMP FP16 verificado |
| ONNX / ONNX Runtime (PC) | ✅ | onnx 1.23.2, onnxruntime 1.32.0 |
| Flutter / Dart | ✅ | 3.47.1 stable / 3.13.1 |
| Android SDK | ✅ | platform 34–37, build-tools 36, NDK 28.2, cmdline-tools 23 |
| JDK | ✅ | JBR 25 de Android Studio (usado por Gradle); JDK 17 Microsoft en PATH |
| Gradle | ✅ | 9.3.1 en caché; AGP 9.1.0; Kotlin 2.4.0 |
| Licencias Android | ⚠️ | `flutter doctor` las reporta "unknown" (no bloqueó compilaciones). Ejecutar: `flutter doctor --android-licenses` |
| Emulador | ✅ | AVD `Pixel_9` (Android 17, x86_64, páginas 16 KB), WHPX disponible |
| Dispositivo físico | ❌ | Ningún dispositivo conectado (Galaxy S26 Ultra pendiente) |

## Red — problema crítico
Desde esta red **no conectan** (TCP timeout, probado también fuera del sandbox):
`pub.dev`, `services.gradle.org`, `plugins.gradle.org`, `repo.maven.apache.org`.
Sí conectan: `pypi.org`, `download.pytorch.org`, `dl.google.com`, `repo1.maven.org`.

Consecuencias y mitigación:
- **No se pueden agregar paquetes Dart nuevos.** Se usan solo los 352 de la caché local
  (`flutter pub get --offline`). SQLite, visores PDF/3D y ONNX para Flutter no están en caché
  → se resolvieron con APIs nativas/propias (ver DECISIONES.md).
- Gradle: el proyecto declara `https://repo1.maven.org/maven2` antes de `mavenCentral()`
  (cambio local del proyecto, no global).
- **Acción recomendada:** probar otra red (hotspot del celular) o consultar al proveedor por
  el bloqueo hacia `34.36.0.14` (pub.dev). El DNS resuelve bien; falla el TCP.

## Comandos de verificación
```powershell
flutter doctor -v
C:\STRUCTURA\.venv\Scripts\python.exe -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_arch_list())"
C:\Users\Agusr\AppData\Local\Android\sdk\emulator\emulator.exe -list-avds
```
