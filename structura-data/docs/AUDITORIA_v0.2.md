# Auditoría técnica — 2026-11-24

Paquetes auditados: `structura_core_prototype` y `structura_dataset_tools_v0_2`.
No se recibió el documento maestro ni las herramientas v0.1 de importación y procesamiento de
imágenes. **No existía un importador PDF**, aunque PyMuPDF figuraba en las dependencias.

## 1. Dataset Tools v0.2 — defectos encontrados y estado en v0.3

| # | Defecto | Severidad | v0.3 |
|---|---|---|---|
| 1 | `bool("false") == True`: `"scale_verified": "false"` quedaba en `true` | Alta | Corregido: booleano estricto |
| 2 | Polígonos de menos de 3 puntos se descartaban en silencio | Alta | Corregido: error |
| 3 | Solapamientos: la última forma gana. Un muro dibujado después borra la ventana. | Alta | Prioridad de clases + reporte de conflictos |
| 4 | `line`/`point` con grosor inventado (10 px / 5 px) | Media | Grosor explícito obligatorio |
| 5 | `cv2.imread/imwrite` fallan con rutas Unicode en Windows (reproducido) | Alta | E/S con `imdecode`/`imencode` |
| 6 | PNG con transparencia se leía con fondo negro | Media | Se compone sobre blanco |
| 7 | Re-ejecutar el tiler dejaba tiles obsoletos mezclados | Alta | `--overwrite` borra los del plano; el build regenera todo |
| 8 | Metadata sin resolución, tamaño de origen, hashes ni registro de descartes | Media | Esquema v1 completo |
| 9 | El validador no detectaba huérfanos, duplicados entre planos, ediciones posteriores, relleno incorrecto ni fuga entre splits | Alta | Más de 40 códigos de error, incluida la reconstrucción del plano |
| 10 | `classes.yaml` no lo usaba ningún módulo (IDs escritos a mano en 3 sitios) | Media | Única fuente de verdad |
| 11 | Sin modo batch, sin pipeline, sin tests | Media | `build_dataset`, modo `--registry`, 85 tests |
| 12 | Falta `tools/__init__.py` (funcionaba como paquete implícito) | Baja | Agregado |
| 13 | `tqdm` declarado y sin uso | Baja | Eliminado |
| 14 | No admitía `oriented_rectangle`/`points` de LabelMe 7 | Media | Admitidos y verificados con LabelMe 7.11 |

## 2. CORE Prototype — hallazgos (no modificado en esta etapa)

**Compatibilidad con el dataset**: correcta. `PlanDataset` lee `images/<id>.png`,
`masks/<id>.png` y `splits/{train,validation}.txt`, que es lo que genera `build_dataset`. Lo
verifica un test que emula `core/data.py`.

| Prioridad | Hallazgo |
|---|---|
| **P0** | `requirements.txt: torch>=2.2`: desde PyPI en Windows se instala la versión **solo CPU**. La RTX 5070 (Blackwell, sm_120) necesita PyTorch ≥ 2.7 con CUDA 12.8: `pip install torch --index-url https://download.pytorch.org/whl/cu128`. |
| **P0** | `data.py`, `predict.py`, `predict_onnx.py` usan `cv2.imread`/`imwrite`: fallan con rutas que contengan `ñ` o acentos. |
| **P0** | `train.py` no usa AMP FP16 (lo pide la especificación). |
| **P0** | Métricas: el mIoU se promedia por batch e ignora las clases ausentes en cada batch (sesgo). Faltan IoU por clase, precision, recall, Boundary F1, tiempo de inferencia y memoria. Hay que acumular una matriz de confusión por época. |
| **P0** | No hay evaluación sobre `test.txt`. |
| **P1** | `predict.py` reduce el plano completo a 512×512: en un plano de 6000 px las paredes finas desaparecen. Hace falta inferencia por tiles con la misma rejilla (512/64) y recomposición. |
| **P1** | El mejor checkpoint se elige por `val_loss`, no por mIoU. No se fija semilla. No hay registro por época (CSV). |
| **P1** | Desbalance de clases: en el dataset sintético window es 0.07 % y column 0.04 % de los píxeles. Con CrossEntropy sin pesos, el modelo tenderá a ignorarlas. Propuesta: CE ponderada (cambio mínimo, requiere aprobación porque la especificación dice CrossEntropy). |
| P2 | No hay tests. `export_onnx.py` no verifica que ONNX y PyTorch den el mismo resultado. |
| P2 | `CLASS_SCHEMA.md` duplica `classes.yaml`. |

Lo que sí está bien: la arquitectura U-Net Small (base 16, 6 clases, 4 niveles, BatchNorm),
AdamW con lr 1e-3, aumentos con flips y rotaciones de 90° (válidos para planos), la
normalización /255 coherente entre entrenamiento, PyTorch y ONNX, y la exportación ONNX con
opset 17 y entrada fija 512×512.

## 3. Entorno de desarrollo detectado
- GPU: RTX 5070, 12 GB, driver 621.01.
- Python: solo 3.14 instalado (lanzador `py`). `python` apunta al alias de Microsoft Store.
  **Python 3.11 no está instalado.**
- LabelMe en PyPI: versión 7.11.0. Su configuración usa `with_image_data` (la clave
  `store_data` de versiones anteriores ya no existe).
