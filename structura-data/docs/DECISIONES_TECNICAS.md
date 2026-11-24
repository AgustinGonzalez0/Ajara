# Decisiones técnicas — Dataset Tools 0.3

Formato: decisión, motivo y si es reversible. Las decisiones que afectan al dataset y todavía
requieren aprobación están marcadas con **[PENDIENTE]**.

## DT-01 · PNG canónico como única fuente de píxeles
Todo plano se convierte una vez (`import_plans`) a PNG RGB de 8 bits. Se anota ese PNG y de
él salen la máscara y los tiles. El conversor y el tiler rechazan fuentes que no sean PNG.
- **Motivo**: si JPG/PDF/TIFF se decodificaran en cada herramienta, la orientación EXIF, la
  transparencia, los 16 bits o el DPI de render podrían desalinear máscara e imagen sin aviso.
- **Reversible**: sí.

## DT-02 · Solapamientos por prioridad de clase, no por orden de dibujo
`door > window > column > stairs > wall` (configurable en `classes.yaml`). La v0.2 hacía que
"la última forma gana".
- **Motivo**: con el orden de dibujo, un muro dibujado después de una ventana la borra sin
  aviso. Con prioridad, el anotador dibuja muros continuos y aberturas encima (más rápido y
  consistente), y los solapes inesperados se reportan como conflicto.
- **Reversible**: sí, sin re-anotar (`--overlap-policy order` o editar la prioridad y
  regenerar las máscaras).

## DT-03 · Puerta = vano dentro del muro **[PENDIENTE]**
Ver `MANUAL_ANOTACION.md §3.2`. Las herramientas no dependen de esta convención, pero
cambiarla después obliga a **re-anotar**. Debe confirmarse antes del primer lote.

## DT-04 · Sin geometría inventada
`line`/`linestrip`/`point`/`points` se rechazan si no se da un grosor explícito (la v0.2 usaba
10 px por defecto). Los polígonos degenerados son error (la v0.2 los descartaba en silencio).
`scale_verified=true` exige `units` y `scale_px_per_unit`. El DPI de cabecera de un raster se
marca `file_header`, no se presenta como medido.

## DT-05 · Rasterización OpenCV subpíxel (`shift=4`)
Con vértices enteros coincide píxel a píxel con PIL/LabelMe. Con coordenadas fraccionarias o
círculos difiere ±1 px en el contorno (medido contra LabelMe 7.11). Los trazos se construyen
como polígonos porque `cv2.line` no respeta el grosor (3 px → 5 px, medido).
- **Reversible**: sí, regenerando las máscaras.

## DT-06 · Rejilla de tiles alineada al borde
Paso de `tile − overlap` (448 px). El último tile de cada eje se alinea al borde del plano, así
que su solape puede superar 64 px. Solo se rellena (imagen blanca, máscara 0) cuando el plano
es más chico que el tile en ese eje.
- **Motivo**: minimiza el relleno artificial y cubre el plano completo.
- **Reversible**: sí.

## DT-07 · Manifiesto por plano y verificación por reconstrucción
`plans/<id>.json` guarda la rejilla, los tiles, los descartados y el hash del contenido
decodificado de la imagen y la máscara fuente. El validador recompone el plano desde los tiles,
comprueba que los solapes coincidan y que el resultado sea igual bit a bit al original.
- **Motivo**: es la única forma de demostrar que no se perdieron ni se desplazaron coordenadas
  y que imagen y máscara siguen sincronizadas, sin necesitar las fuentes.

## DT-08 · Hashes en metadata
Hash SHA-256 de cada tile, de la imagen fuente y del registro. Detecta ediciones posteriores
al tiling y el mismo plano importado con dos IDs (fuga entre splits).

## DT-09 · Splits por grupo con LPT por déficit
Los grupos se ordenan por tamaño (la semilla solo desempata) y cada uno va al split con mayor
déficit. Si un split queda vacío y hay grupos de sobra, se le pasa el grupo más chico del split
con más excedente. Se avisa si una clase no aparece en validation o test.
- **Motivo**: con grupos de tamaño desigual el orden aleatorio de la v0.2 desequilibraba
  bastante más las proporciones.

## DT-10 · Reconstrucción completa en cada build
`build_dataset` borra y regenera `dataset/` (con `--overwrite`).
- **Motivo**: evita mezclar tiles de ejecuciones con otros parámetros. Con 50–500 planos el
  costo es de segundos a minutos.

## DT-11 · Dependencias
OpenCV, NumPy, PyMuPDF, Pillow y PyYAML, todas ya estaban en la v0.2. Se quitó `tqdm` (no se
usaba). Los tests usan `unittest` (biblioteca estándar). LabelMe va en un entorno separado:
solo hace falta para anotar y trae Qt.

## DT-12 · Identificadores
`[A-Za-z0-9][A-Za-z0-9_-]{0,63}`: sin espacios ni acentos, seguros como nombre de archivo en
Windows. El sistema de archivos de Windows no distingue mayúsculas; el validador detecta
nombres que solo difieren en mayúsculas.

## DT-13 · CSV compatible con Excel en español
`plans.csv` se escribe en UTF-8 con BOM. La lectura detecta `,` o `;` porque Excel con
configuración regional en español guarda con `;`.
