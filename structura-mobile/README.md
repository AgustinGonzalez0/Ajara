# STRUCTURA AI — app Android (Flutter)

App para profesionales: **foto o archivo del plano → modelo 3D → evaluación preliminar**,
procesada en el teléfono, sin conexión y sin depender de una IA externa.

## Pantallas
| Pantalla | Qué hace |
|---|---|
| Splash / Onboarding | Identidad y presentación breve |
| Proyectos | Crear proyecto, **foto de un plano**, importar archivo, recientes con estado |
| Proyecto | Pasos: Plano → Análisis → Revisar detecciones → Modelo 3D → **Evaluación preliminar** |
| Foto del plano | Cámara o galería, hoja detectada automáticamente, esquinas ajustables, corrección de perspectiva |
| Importar | PDF (selección de página, DPI), PNG, JPG, TIFF, con validación por contenido |
| Análisis | **Motor clásico sin IA** (por defecto) o Vision AI (ONNX, modelo INT8), con progreso y cancelación |
| Editor 2D | Zoom, desplazamiento, capas (plano, segmentación, vectores), elementos con confianza |
| Modelo 3D | Visor por software (órbita, zoom, planta, capas); GLB guardado en el proyecto |
| Evaluación | Escala por cota (2 puntos), pisos, material y espesor, sismo, tsunami y viento, semáforo y supuestos |
| Simulación 3D | Muros coloreados por demanda/capacidad, vaivén sísmico (exagerado), agua de tsunami |
| Configuración | Tema, DPI de PDF, almacenamiento, modelos instalados (procedencia, SHA-256), capacidades |

## Arquitectura
- `lib/app/`: tema, router (go_router), providers (Riverpod), shell adaptativo (teléfono y tablet).
- `lib/data/`: formato de proyecto versionado y almacén en archivos (escritura atómica + `.bak`).
- `lib/services/`: importación (archivo y foto), análisis (clásico e IA, en un isolate),
  registro de modelos, evaluación.
- `lib/platform/`: canales nativos (ONNX Runtime y PdfRenderer). La parte Kotlin está en `android/app/src/main/kotlin/`.
- La lógica de dominio vive en `../packages/*` (Dart puro, testeable sin Flutter).

## Ejecutar
```powershell
flutter pub get --offline
flutter test                                              # 24 tests
flutter run -d <dispositivo>
flutter test integration_test\device_e2e_test.dart -d <dispositivo>
flutter build apk --release --split-per-abi
powershell -File tool\verify_release.ps1
```

## Privacidad
El APK de release no declara `INTERNET`. El `TelemetryInitializer` de ONNX Runtime se elimina
del manifest, la telemetría se desactiva por código y hay reglas R8 que conservan las clases JNI.
