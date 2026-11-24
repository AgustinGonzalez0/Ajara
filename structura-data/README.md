# STRUCTURA DATASET TOOLS 0.3

Pipeline local y offline que prepara los datos de entrenamiento de **Vision AI 0.1**
(segmentación semántica de planos, 6 clases) a partir de planos PDF/PNG/JPG anotados en LabelMe.

```
PDF/PNG/JPG ──import_plans──► PNG canónico + plans.csv
                                   │  (anotación manual en LabelMe)
LabelMe JSON ──labelme_to_mask──► máscara PNG (IDs 0..5)
                                   │
              ──make_dataset_tiles──► tiles 512×512 imagen+máscara+metadata
                                   │
              ──validate_dataset──► informe (si hay errores, se detiene)
                                   │
              ──make_splits──► train.txt / validation.txt / test.txt (por proyecto)
```

`tools.build_dataset` ejecuta todo en orden y **no genera splits si la validación falla**.
El dataset resultante es compatible con `core/data.py` del prototipo CORE
(`images/`, `masks/`, `splits/train.txt`, `splits/validation.txt`).

Este paquete prepara datos. **No** evalúa calidad semántica (eso requiere revisión humana),
**no** infiere escalas ni dimensiones y **no** realiza ningún análisis estructural.

---

## 1. Instalación (Windows 11)

Requiere Python 3.11 (recomendado). También se probó en 3.14.

```powershell
cd $env:USERPROFILE\Desktop\Ajara\structura-data
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
```

Para anotar se necesita LabelMe en un entorno separado (trae Qt y no hace falta para el pipeline):

```powershell
py -3.11 -m venv C:\labelme-env
C:\labelme-env\Scripts\pip install labelme
```

> Si `pip` falla con *"Windows Long Path support"*, usar una ruta corta para el entorno
> (por ejemplo `C:\labelme-env`) o habilitar las rutas largas de Windows.

Comprobar la instalación:

```powershell
python -m unittest discover -s tests -t .
```

Resultado esperado: `Ran 85 tests ... OK` (unos 25 s).

---

## 2. Estructura de carpetas

```
structura_dataset_tools\
  tools\                    código del pipeline (ejecutar siempre como python -m tools.<módulo>)
    common.py               E/S Unicode-safe, esquema de clases, validación de IDs y booleanos
    import_plans.py         PDF/PNG/JPG/TIFF → PNG canónico + plans.csv
    labelme_to_mask.py      LabelMe JSON → máscara PNG + reporte
    make_dataset_tiles.py   tiles sincronizados + metadata + manifiesto por plano
    validate_dataset.py     validación estructural completa
    make_splits.py          splits por proyecto/plano
    build_dataset.py        pipeline completo
    make_overlay.py         superposición máscara/imagen para revisar
  config\
    classes.yaml            única fuente de verdad de clases y prioridades
    labelme_config.yaml     configuración LabelMe (5 etiquetas, banderas)
    plans_template.csv      plantilla del registro de planos
  docs\
    MANUAL_ANOTACION.md     convenciones de anotación (leer antes de anotar)
    DECISIONES_TECNICAS.md  decisiones de diseño y su justificación
    ESQUEMA_METADATOS.md    campos de plans.csv, metadata de tiles y manifiestos
    AUDITORIA_v0.2.md       auditoría que originó esta versión (incluye CORE)
  tests\                    85 tests (unittest, sin dependencias extra) + generador sintético
```

Espacio de trabajo recomendado para los datos, fuera del código:

```
$env:USERPROFILE\Desktop\Ajara\structura-data\
  incoming\<project_id>\    archivos originales tal como llegan (no se modifican)
  work\raw\                 PNG canónicos (lo que se anota)
  work\plans.csv            registro de planos
  work\masks\               máscaras de plano completo + <id>.report.json
  annotations\              <source_plan_id>.json de LabelMe
  dataset\                  salida final (images, masks, metadata, plans, splits)
```

---

## 3. Flujo de trabajo

Todos los comandos se ejecutan desde la carpeta del paquete con el venv activado. Abajo,
`$D` es la carpeta de datos: `$D = "$env:USERPROFILE\Desktop\Ajara\structura-data"`.

### 3.1 Importar planos
```powershell
python -m tools.import_plans --input "$D\incoming\proyecto_001" --project-id proyecto_001 `
    --source-type digital --output-dir "$D\work\raw" --registry "$D\work\plans.csv"
```
- Los PDF se renderizan a `--dpi 200` (por defecto) y se registra `dpi_source=pdf_render`.
  Hay que usar el mismo DPI en todo el dataset.
- En los raster se aplica la orientación EXIF, la transparencia se compone sobre blanco y los
  16 bits se pasan a 8 bits. El DPI de cabecera se registra como `file_header` (no verificado).
- El ID de cada plano se deriva del nombre del archivo (`Planta Baja (año).pdf` →
  `Planta_Baja_ano_p001`).
- Si se importa un archivo ya importado con otro ID, se rechaza: evita duplicados que se
  filtrarían entre splits.
- `--source-type`: `digital` | `scanned` | `photo` | `unknown`. `--pages 1,3-4` limita las
  páginas del PDF.

### 3.2 Anotar
```powershell
C:\labelme-env\Scripts\labelme "$D\work\raw" --config .\config\labelme_config.yaml --output "$D\annotations"
```
Seguir `docs/MANUAL_ANOTACION.md`. La bandera de imagen `needs_review` excluye el plano del
dataset hasta que se quite.

### 3.3 (Opcional) Escala verificada
Solo si se midió una cota real: completar en `plans.csv` las columnas `units`,
`scale_px_per_unit` y `scale_verified=true`. Si falta cualquiera de las tres, el pipeline
rechaza `scale_verified=true`. Por defecto queda `false`.

### 3.4 Construir el dataset
```powershell
python -m tools.build_dataset --registry "$D\work\plans.csv" --annotations "$D\annotations" `
    --work "$D\work" --output "$D\dataset" --overwrite
```
Salida: `dataset\{images,masks,metadata,plans,splits}`, `validation_report.json` y
`dataset_manifest.json` (planos incluidos, pendientes y excluidos, parámetros).

Parámetros por defecto: `--tile 512 --overlap 64 --train 0.70 --validation 0.15 --test 0.15
--group-by project_id --seed 42 --overlap-policy priority`.

### 3.5 Revisar visualmente
```powershell
python -m tools.make_overlay --image-dir "$D\work\raw" --mask-dir "$D\work\masks" --output "$D\review"
```

### 3.6 Entrenar (paquete CORE)
```powershell
python -m core.train --dataset "$D\dataset" --epochs 40 --batch-size 4 --output .\artifacts
```
Ver en `docs/AUDITORIA_v0.2.md` los cambios pendientes en CORE antes de un entrenamiento
real: PyTorch con CUDA 12.8 para la RTX 5070, AMP, métricas y rutas Unicode.

---

## 4. Herramientas individuales

Cada etapa se puede ejecutar por separado. Las opciones de la v0.2 siguen funcionando.

```powershell
# LabelMe → máscaras (carpeta o archivo)
python -m tools.labelme_to_mask --input "$D\annotations" --image-dir "$D\work\raw" --output "$D\work\masks"

# Tiles de un plano (CLI v0.2) o de todo el registro
python -m tools.make_dataset_tiles --image "$D\work\raw\plan_001.png" --mask "$D\work\masks\plan_001.png" `
    --output "$D\dataset" --source-plan-id plan_001 --project-id proyecto_001 --source-type digital
python -m tools.make_dataset_tiles --registry "$D\work\plans.csv" --masks-dir "$D\work\masks" --output "$D\dataset"

# Validación (todo el dataset, o carpetas sueltas como en v0.2)
python -m tools.validate_dataset --dataset "$D\dataset" --report "$D\dataset\validation_report.json"

# Splits
python -m tools.make_splits --metadata "$D\dataset\metadata" --output "$D\dataset\splits" --group-by project_id

# Demo sintética de punta a punta (para inspeccionar o abrir en LabelMe)
python -m tests.synthetic_demo --output .\demo_sintetico
```

Códigos de salida: `0` = OK, `1` = error de datos (el mensaje indica plano, archivo y causa).

---

## 5. Garantías verificadas por los tests

| Garantía | Cómo se verifica |
|---|---|
| Máscaras PNG de 1 canal, uint8, IDs 0..5, mismo tamaño que la imagen | tests de conversor y de integración |
| IDs de clase exactos | máscara generada = máscara esperada calculada de forma independiente, píxel a píxel |
| Compatibilidad con LabelMe 7.11 real | fixture escrito por `write_label_file` de LabelMe y comparado con su rasterizador |
| Tiles sincronizados, sin pérdida de coordenadas | la reconstrucción desde tiles es igual bit a bit a la imagen y la máscara fuente |
| Relleno: imagen blanca, máscara clase 0 | verificado por tile en tests y en el validador |
| Ningún proyecto ni plano en más de un split | test de integración y validador |
| Determinismo | reconstruir con la misma semilla produce los mismos splits y hashes |
| Detección de defectos | 22 tests inyectan un defecto cada uno (corrupto, multicanal, ID inválido, editado después del tiling, fuga entre splits, etc.) |
| Rutas Unicode en Windows | todos los tests corren en carpetas con `ñ` y espacios |

---

## 6. Limitaciones conocidas

- La validación es **estructural**. Que un muro esté bien dibujado lo decide una persona.
- El split es por grupos con una heurística (LPT). Con pocos proyectos las proporciones
  reales difieren de las pedidas (ver `split_manifest.json`). No estratifica por clase, pero
  avisa si una clase falta en validation o test.
- Coordenadas fraccionarias y círculos pueden diferir ±1 px en el contorno respecto de otras
  herramientas de rasterización (precisión de anotación esperada: ±2 px).
- `line`/`linestrip`/`point` requieren grosor explícito. Los trazos oblicuos tienen ±1 px de
  discretización.
- Los PDF se rasterizan. No se extrae geometría vectorial (fuera del alcance de Vision AI 0.1).
- Un dataset generado con v0.2 no pasa la validación v0.3 (faltan metadatos): hay que
  regenerarlo con `build_dataset`.
- Python 3.11 no estaba instalado en la PC de desarrollo cuando se hizo esta entrega. Los
  tests corrieron en 3.14 y se verificó que el código no usa sintaxis posterior a 3.11.
