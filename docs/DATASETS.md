# Datasets: fuentes, licencias y uso

Vision AI necesita planos con máscaras exactas. Todavía no hay planos reales anotados del
producto (la convención de puertas D-17 sigue pendiente). Mientras tanto se usan **geometrías
vectoriales reales con licencia abierta**, dibujadas por STRUCTURA con estilos variados.

## Fuentes evaluadas

| Fuente | Contenido | Licencia | Uso comercial | Estado en STRUCTURA |
|---|---|---|---|---|
| **Swiss Dwellings v3.0.0** (Zenodo 7788422) | ~45 000 departamentos, polígonos en metros: muros, columnas, barandas, puertas, ventanas, escaleras, artefactos, ambientes | **CC BY 4.0** (registro de Zenodo) | Sí, con atribución | **Usado** (dataset vectorial v1) |
| ResPlan (github.com/m-agour/ResPlan) | 17 000 plantas residenciales (Asia del Sur), muros, puertas, ventanas, ambientes; 685 con escalera | **En conflicto**: el `LICENSE` del repo dice CC BY 4.0, pero el `croissant.json` del mismo repo y Kaggle dicen **CC BY-NC-SA 4.0**. Autores no publicados; geometría derivada de renders de avisos inmobiliarios | Incierto | **No usado** (D-29, pendiente) |
| CubiCasa5K | 5 000 planos raster anotados (Finlandia) | CC BY-NC-SA 4.0 | No | No usado |
| FloorPlanCAD | Dibujos CAD | CC BY-NC | No | No usado |

ResPlan tiene lector propio (`tools/vector_sources.py`, con *unpickler* restringido: un pickle
arbitrario puede ejecutar código), pero `build_vector_dataset` lo rechaza salvo
`--allow-source resplan`. Antes de usarlo en un modelo comercial hay que aclarar la licencia
con sus autores o con asesoría legal.

## Atribución (obligatoria por CC BY 4.0)

> Standfest, M., Franzen, M., Schröder, Y., Gonzalez Medina, L., Villanueva Hernandez, Y.,
> Buck, J. H., Tan, Y.-L., Niedzwiecka, M., Colmegna, R. (2022). *Swiss Dwellings: A large
> dataset of apartment models including aggregated geolocation-based simulation results
> covering viewshed, natural light, traffic noise, centrality and geometric analysis*
> (v3.0.0). Zenodo. https://doi.org/10.5281/zenodo.7788422 — CC BY 4.0.
> Cambios: geometría alineada, re-escalada y dibujada con estilos aleatorios; máscaras
> rasterizadas desde los polígonos originales.

Cada dataset generado incluye `ATTRIBUTION.md` y la atribución en `dataset_manifest.json`.
Si un modelo entrenado con estos datos se distribuye en la app, la atribución debe figurar en
"Configuración → Acerca de / licencias".

## Dataset vectorial v1 (`data/dataset_vector_v1`, no versionado)

| Medida | Valor |
|---|---|
| Plantas | 1 499 de 1 183 sitios distintos (1 omitida por tamaño) |
| Tiles 512×512 | 28 511 · train 19 958 · validación 4 277 · test 4 276 |
| Splits | por **sitio** (`project_id = sd_site_<id>`): ningún edificio aparece en dos splits |
| Píxeles por clase | fondo 90,1 % · muro 6,4 % · puerta 0,76 % · ventana 1,42 % · columna 0,13 % · escalera 1,24 % |
| Columnas | 583 plantas con columnas reales; 521 con **columnas sintéticas** (aumento declarado, D-30) |
| Convención de puertas | `vano` (rectángulo dentro del muro, como vienen las fuentes). `--door-label vano_y_barrido` regenera con el sector de giro. **D-17 sigue pendiente**: cambiarla no obliga a re-anotar |

### Cómo se dibuja (variedad de estilos por plano)
Escala 38–115 px/m; muros macizos, grises, rayados, en contorno o mixtos; puertas con arco,
arco punteado, dobles, corredizas o solo vano; ventanas de 1 o 2 líneas o rellenas; escaleras
con huellas, flecha y línea de corte; artefactos sanitarios y de cocina; nombres de ambientes
en castellano (o inglés) con superficie; cadenas de cotas; ejes estructurales; títulos; tinta
negra, gris o azul; papel con tono; desenfoque, baja resolución, gradiente de iluminación,
JPEG y leve inclinación.

La **máscara sale de los polígonos**, no del dibujo: no hay error de anotación.

### Qué mide y qué no
El test mide la generalización a **edificios y estilos no vistos**. **No** mide el desempeño
con fotos de planos argentinos reales: para eso hace falta un lote real anotado (pendiente de
D-17 y de tu decisión sobre anotación manual o asistida).

## Planos CAD reales del usuario (`data/cad_ft_v1`, privado, no versionado)

49 DWG → DXF (LibreDWG) → láminas con máscara desde las capas (`tools.cad_extract`) →
tiles con píxeles dudosos en 255 y splits por obra (`tools.build_cad_dataset`). Uso: ajuste
fino del modelo v0.3.0 y prueba en obras no vistas. **No se redistribuye.** Detalle en
[`EVALUACION_CAD.md`](EVALUACION_CAD.md).

## Reproducir
```powershell
$R = "$env:USERPROFILE\Desktop\Ajara"
cd $R\structura-data
..\.venv\Scripts\python.exe -m tools.vector_sources swiss --zip $R\data\external\swiss_dwellings\swiss-dwellings-v3.0.0.zip --cache $R\data\vector_cache\swiss --limit 1500
..\.venv\Scripts\python.exe -m tools.build_vector_dataset --cache $R\data\vector_cache\swiss --output $R\data\dataset_vector_v1 --workers 8 --overwrite
```
Descarga del ZIP (932 MB): `https://zenodo.org/records/7788422/files/swiss-dwellings-v3.0.0.zip`.
