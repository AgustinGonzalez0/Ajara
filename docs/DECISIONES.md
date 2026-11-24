# Decisiones técnicas (proyecto completo)

Las decisiones de structura-data están en `structura-data/docs/DECISIONES_TECNICAS.md`.
**[PENDIENTE]** = requiere aprobación del responsable del producto.

| # | Decisión | Motivo | Reversible |
|---|---|---|---|
| D-01 | Monorepo git en `C:\STRUCTURA`; `main` conserva los paquetes originales intactos, el trabajo va en `develop` | conservar versiones originales y trazabilidad | sí |
| D-02 | Python 3.14 + PyTorch 2.11.0+cu128 (en lugar de 3.11) | 3.11 no está instalado; hay wheels oficiales cu128 para 3.14 con sm_120; código compatible con 3.11 | sí |
| D-03 | Runtime de IA en el dispositivo en **Dart puro + Kotlin**: el tiling y la geometría en Dart, solo la inferencia en ONNX Runtime nativo | testeable en PC sin Android; misma rejilla que Python; el runtime se puede sustituir | sí |
| D-04 | ONNX Runtime Android **1.32.0** vía Maven (`repo1.maven.org`), CPU, 4 hilos. **No NNAPI/NPU** | NNAPI está deprecado; la compatibilidad de operadores con el NPU del S26 Ultra no está verificada → se mide primero en CPU | sí |
| D-05 | **Telemetría de ONNX Runtime desactivada en 3 capas**: (1) se elimina su `TelemetryInitializer` (ContentProvider que corre al arrancar y consulta recolección de ID de dispositivo); (2) se eliminan `INTERNET` y `ACCESS_NETWORK_STATE` del manifiesto fusionado de release; (3) `OrtEnvironment.setTelemetry(false)` al crear el entorno, que ahora es perezoso | el procesamiento debe ser local y privado; el AAR agrega esos permisos y el provider sin avisar | sí |
| D-06 | PDF con `android.graphics.pdf.PdfRenderer` (sistema) | sin dependencias; offline; no hay paquete Flutter de PDF en caché | sí |
| D-07 | Persistencia: carpeta por proyecto con `project.json` versionado (escritura atómica + `.bak`) + binarios en disco. Sin SQLite | archivos pesados fuera de la base; volumen bajo; inspeccionable; SQLite no disponible offline. El índice puede pasar a SQLite sin cambiar el formato | sí |
| D-08 | Visor 3D por software sobre `Canvas.drawVertices` | no hay librería 3D mantenida disponible; mallas arquitectónicas de miles de triángulos se dibujan bien; reemplazable por GPU sin tocar la malla | sí |
| D-09 | Alturas 3D = **supuestos de visualización** (18 × espesor mediano de muro sin escala; 2,60 m con escala verificada), registrados en malla, GLB y UI. El Building Model mantiene alturas `null` | no inventar medidas | sí |
| D-10 | La malla 3D se regenera desde `building_model.json` al abrir el proyecto (determinista); el GLB se guarda para exportar | abrir proyectos sin re-procesar el plano | sí |
| D-11 | Análisis en isolate de fondo con `BackgroundIsolateBinaryMessenger` | UI fluida durante inferencia y vectorización | sí |
| D-12 | Clase `Column` del Building Model renombrada a `ColumnElement` | colisión con el widget `Column` de Flutter | sí |
| D-13 | go_router 17.5 (no 18) | 18 migra a `material_ui`; la plantilla de Flutter 3.47 usa `flutter/material` | sí |
| D-14 | El checkpoint guarda solo tipos básicos (`str(torch.__version__)`) | `torch.load(weights_only=True)` falla con objetos `TorchVersion` (defecto encontrado por test) | — |
| D-15 | Mejor checkpoint por mIoU de validación; métricas por matriz de confusión acumulada | el prototipo elegía por loss y promediaba mIoU por batch (sesgado) | sí |
| D-16 | Modelo de prueba empaquetado en la app (`vision_ai_synthetic_test`, 7,4 MB), marcado `synthetic` y `production_ready: false`; la UI lo muestra como **MODELO DE PRUEBA** en análisis, editor y 3D | integración real sin simular una IA entrenada | sí |
| D-17 | **[PENDIENTE]** Convención de anotación de puertas (vano) | cambiarla después obliga a re-anotar | — |
| D-18 | **[PENDIENTE]** Función de pérdida (ver `EVALUACION_LOSS.md`) | modifica la especificación 0.1 | — |
