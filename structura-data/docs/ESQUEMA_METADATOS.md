# Esquema de metadatos (schema_version 1)

## 1. `plans.csv` — registro de planos
Lo genera `tools.import_plans`. Las columnas de escala y anotación se pueden editar a mano.

| Columna | Obligatoria | Descripción |
|---|---|---|
| `source_plan_id` | sí | ID del plano/página. Nombre del PNG y del JSON. |
| `project_id` | sí | Proyecto u obra de origen. **Unidad de división entre splits.** |
| `source_type` | sí | `digital` \| `scanned` \| `photo` \| `unknown` |
| `image` | sí | Ruta al PNG canónico, relativa a `plans.csv` |
| `annotation` | no | JSON de LabelMe; vacío = `<annotations>/<source_plan_id>.json` |
| `units` | no | `mm` \| `cm` \| `m` \| `in` \| `ft` \| `unknown` (por defecto). Acepta alias como `meters` o `metros`. |
| `scale_verified` | no | `true`/`false` (por defecto `false`). `true` requiere `units` y `scale_px_per_unit`. |
| `scale_px_per_unit` | no | Píxeles por unidad, **medidos** sobre una cota. Vacío si no se midió. |
| `dpi` | no | DPI de render (PDF) o de cabecera (raster). Vacío si se desconoce. |
| `dpi_source` | no | `pdf_render` \| `file_header` \| `manual` \| `unknown` |
| `source_file`, `source_page` | — | Archivo original y página (PDF, 1-based) |
| `source_sha256` | — | Hash del archivo original (detecta duplicados al importar) |
| `image_sha256` | — | Hash del PNG canónico (detecta ediciones después de anotar) |
| `width`, `height` | — | Tamaño del PNG canónico en píxeles |
| `notes` | — | Libre. Para PDF guarda el tamaño de página en puntos y la rotación. |

## 2. `dataset/metadata/<tile_id>.json` — un archivo por tile
`tile_id = <source_plan_id>_x<XXXXXX>_y<YYYYYY>` (origen del recorte en píxeles del plano).

| Campo | Tipo | Descripción |
|---|---|---|
| `schema_version`, `tool_version` | int, str | Versionado |
| `tile_id`, `source_plan_id`, `project_id`, `source_type` | str | Procedencia |
| `source_image`, `source_mask` | str | Nombres de archivo fuente |
| `source_image_sha256`, `source_mask_sha256` | str | Hash de los archivos fuente |
| `source_width`, `source_height` | int | Tamaño del plano completo (px) |
| `x`, `y` | int | Origen del recorte en el plano (px) |
| `width`, `height` | int | Zona válida del tile (≤ `tile_size`). El resto es relleno. |
| `tile_size`, `overlap` | int | 512 y 64 por defecto |
| `pad_right`, `pad_bottom` | int | Relleno: `width + pad_right = tile_size` |
| `foreground_ratio` | float | Píxeles no background / zona válida |
| `class_pixel_counts` | int[6] | Píxeles por clase en el tile (relleno incluido como clase 0) |
| `image_sha256`, `mask_sha256` | str | Hash de los archivos del tile |
| `units`, `scale_verified`, `scale_px_per_unit`, `dpi`, `dpi_source` | | Copiados del plano. Los tiles no se reescalan, así que siguen valiendo. |

Para pasar coordenadas de un píxel `(u, v)` del tile al plano: `(x + u, y + v)`, válido si
`u < width` y `v < height`.

## 3. `dataset/plans/<source_plan_id>.json` — manifiesto por plano
Los campos de procedencia del plano, más: `grid_x`, `grid_y` (orígenes de la rejilla), `stride`,
`tiles` (IDs generados), `skipped` (descartados por `min_foreground_ratio`, con coordenadas),
`class_pixel_counts` del plano completo y `source_image_digest`/`source_mask_digest`. Estos
dos son hashes del contenido decodificado y sirven para verificar la reconstrucción exacta.

## 4. `work/masks/<source_plan_id>.report.json` — reporte de conversión
Píxeles por clase, formas por etiqueta y tipo, solapamientos entre clases (esperados o
conflicto, y cuál gana), banderas de imagen (`needs_review`, `partial`), formas con banderas o
descripción, avisos, hashes del JSON y de la imagen, versión de LabelMe.

## 5. `dataset/splits/split_manifest.json`
`group_by`, `seed`, proporciones pedidas y logradas, tiles y grupos por split, planos por split,
píxeles por clase en cada split y avisos (por ejemplo, una clase ausente en test).
