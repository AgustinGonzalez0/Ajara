# Arquitectura de STRUCTURA AI

```
C:\STRUCTURA\                      monorepo git (main = base original, develop = trabajo)
├── structura-data\                STRUCTURA DATA (Python): importación, LabelMe→máscaras, tiles,
│                                  validación, splits. 85 tests.
├── structura-core\                STRUCTURA CORE — entrenamiento (Python/PyTorch): Vision AI,
│                                  métricas, evaluación, inferencia por tiles, exportación ONNX. 17 tests.
├── packages\                      STRUCTURA CORE — runtime en el dispositivo (Dart puro, sin Flutter)
│   ├── structura_model\           Building Model: elementos, procedencia, confianza, unidades. 5 tests.
│   ├── structura_geometry\        Geometry Engine: vectorización, malla 3D, GLB. 8 tests.
│   └── structura_pipeline\        Integración: contratos, segmentación por tiles, pipeline por etapas. 9 tests.
├── structura-mobile\              STRUCTURA MOBILE (Flutter): UI, persistencia, puentes nativos. 23 tests + E2E Android.
├── data\                          (no versionado) datasets, runs y modelos generados
└── docs\                          arquitectura, entorno, decisiones, evaluación de loss, progreso
```

## Flujo de datos

```
PDF/PNG/JPG/TIFF
  │  PlanImporter (Dart) / import_plans (Python)     → PNG canónico + sha256 + DPI con origen
  ▼
PlanRaster (RGB)
  │  TiledSegmenter (Dart) ── TileInferencer ──► ONNX Runtime Android (Kotlin, CPU)
  │      rejilla 512/64 idéntica a structura-core/core/tiling.py; recomposición por bandas
  ▼
SegmentationResult (labels + confianza por píxel)
  │  Vectorizer (Geometry Engine, determinista)
  ▼
BuildingModel (JSON versionado)   elementos + procedencia + confianza; medidas reales = null
  │  MeshBuilder (+ DisplayAssumptions declarados)                     salvo escala verificada
  ▼
BuildingMesh ──► GlbWriter (model.glb)   ──► visor 3D por software (Canvas)
```

## Responsabilidades (sin mezclar)
| Capa | Hace | No hace |
|---|---|---|
| Vision AI (ONNX) | probabilidades por píxel | geometría, medidas |
| Pipeline | orquesta etapas, progreso, cancelación, errores tipados | UI, persistencia |
| Geometry Engine | geometría determinista desde segmentación/Building Model | inferencia, UI |
| Building Model | representación + validación + migraciones | cálculo estructural |
| App (Flutter) | UI, proyectos en disco, puentes nativos | lógica geométrica o de IA |

## Contratos entre módulos
- **Modelo**: `<id>.onnx` + `<id>.model.json` (`structura-model/1`), generado por
  `core/export_onnx.py`. Declara clases, entrada, rejilla, sha256 y **procedencia del
  entrenamiento** (`real|synthetic|untrained`). La app no marca como apto ningún modelo
  que no sea `real` + `production_ready`.
- **Runtime**: `InferenceRuntime.load(descriptor, path) → TileInferencer.infer(Float32List)`.
  Sustituible (CPU, GPU, NNAPI, otro motor) sin tocar UI ni geometría.
- **Proyecto**: carpeta versionada (`project.json` `format_version: 1`), ver
  `structura-mobile/lib/data/project_models.dart`.
- **Building Model**: `schema_version: 1`, ver `packages/structura_model`.

## Coordenadas y unidades
Todo el Building Model está en **píxeles del plano** (origen arriba-izquierda). Las medidas
reales solo existen con una `PlanScale` verificada. Las alturas del 3D son **supuestos de
visualización** declarados en la malla y en el GLB (`is_measurement: false`).
