# STRUCTURA AI — Manual de anotación v0.2

Aplica a: Vision AI 0.1 (segmentación semántica, 6 clases). Herramienta: LabelMe.
Reemplaza al manual v0.1. Los puntos marcados **[PENDIENTE DE APROBACIÓN]** son convenciones
propuestas que deben confirmarse antes de anotar el primer lote: cambiarlas después obliga a
re-anotar, no solo a re-convertir.

---

## 1. Principios

1. **Anotar lo dibujado, no lo inferido.** Solo geometría visible y sustentada por el plano.
   No inferir materiales, función portante, alturas ni dimensiones.
2. **Un píxel, una clase.** Las clases son mutuamente excluyentes en la máscara final.
3. **Consistencia antes que perfección.** Una convención mediocre aplicada siempre es mejor que
   una perfecta aplicada a veces. Ante la duda: bandera `ambiguous`, nunca improvisar.
4. **Background es el valor por defecto.** Nunca se dibuja una forma `background`
   (el conversor la rechaza).
5. **Precisión objetivo: ±2 px** sobre el contorno del elemento a la resolución importada.

| ID | Etiqueta LabelMe | Clase |
|---:|---|---|
| 0 | *(no se dibuja)* | background |
| 1 | `wall` | muro / tabique |
| 2 | `door` | puerta |
| 3 | `window` | ventana |
| 4 | `column` | columna / pilar |
| 5 | `stairs` | escalera |

Las etiquetas van exactamente así, en inglés y en minúsculas. `config/labelme_config.yaml`
impide escribir otras.

---

## 2. Cómo se resuelven los solapamientos

El conversor usa la **política de prioridad** definida en `config/classes.yaml`:

```
wall  <  stairs  <  column  <  window  <  door      (la de la derecha gana)
```

Por eso el flujo recomendado y más rápido es:

1. Dibujar los **muros como regiones continuas**, de punta a punta, **ignorando** puertas y ventanas.
2. Dibujar encima un rectángulo por cada puerta, ventana y columna. Ganan sobre el muro
   automáticamente, sin importar el orden en que se dibujaron.

Los solapamientos esperados (muro con puerta, ventana, columna o escalera) no generan aviso.
Cualquier otro solape (por ejemplo, puerta con ventana) aparece en `<id>.report.json` como
**conflicto** para revisar.

---

## 3. Convenciones por clase

### 3.1 `wall` — muros y tabiques
- **Incluir**: el cuerpo completo del muro con el espesor representado, incluido su relleno
  (negro, gris o rayado). Exteriores, interiores y tabiques.
- **Cruces y encuentros (L, T, X)**: una sola región continua que cubra todo el encuentro.
  Sin huecos ni superposiciones de muros distintos con huecos entre sí. Se pueden dibujar varios
  polígonos que se solapen: entre `wall` y `wall` el solape no importa.
- **Tabiques dibujados con una sola línea**: polígono con el grosor real de esa línea.
  No usar la forma `line` (LabelMe no guarda grosor; el conversor la rechaza salvo que se pase
  `--line-width` explícito y documentado para todo el lote).
- **Muretes y parapetos** dibujados como muro: `wall`.
- **Excluir**: barandas, cercos o medianeras dibujadas solo como línea de lote, líneas de
  terreno, revestimientos dibujados aparte del muro, mobiliario adosado y líneas de cota.
- **Cotas o textos que cruzan un muro**: los píxeles dentro del cuerpo del muro siguen siendo
  `wall`. No recortar el muro para excluir una cota.

### 3.2 `door` — puertas **[PENDIENTE DE APROBACIÓN]**
Convención propuesta: **etiquetar solo el vano**, es decir el rectángulo de la abertura dentro
del espesor del muro, desde una jamba hasta la otra.

- El **arco de giro y la hoja quedan como background.**
- Motivo: el Geometry Engine necesita saber dónde está la abertura dentro del muro (posición y
  ancho). Etiquetar el interior del arco enseñaría al modelo que una zona blanca del ambiente es
  "puerta", y su área varía con el ancho de la hoja. Además basta un rectángulo por puerta:
  rápido y consistente.
- **Puertas dobles, corredizas, plegadizas y de garaje**: un rectángulo que cubra todo el vano.
- **Puerta abierta dibujada en otro ángulo**: se etiqueta igual, solo el vano en el muro.
- **Vano libre (paso sin puerta, arco sin hoja)**: **background**. No es una puerta. Como el
  muro se dibuja continuo (§2), hay que **cortar el polígono del muro** en ese vano.
- **Puerta-ventana (balcón)**: si tiene arco u hoja de giro → `door`; si solo tiene las líneas
  paralelas de la carpintería → `window`. Si no se distingue: `door` con bandera `ambiguous`.

> Alternativa que se descartó (manual v0.1): etiquetar la hoja y el arco y dejar el vano como
> background. Si se prefiere esa opción hay que decidirlo antes del primer lote.

### 3.3 `window` — ventanas
- Rectángulo del símbolo de ventana **dentro del espesor del muro**, de jamba a jamba.
- Incluye las líneas de carpintería y de vidrio que están dentro del muro.
- **Excluir** los alféizares y antepechos que sobresalen del muro, y las cotas cercanas.
- **Ventanas en esquina**: un rectángulo por cada muro.
- **Ventanas altas o banderolas** dibujadas con línea discontinua dentro del muro: `window`.
  Si la línea discontinua está fuera del muro (proyección), es background.

### 3.4 `column` — columnas y pilares
- Contorno completo de la sección, esté rellena, rayada o vacía.
- **Columnas embebidas en muros**: etiquetarlas igual. Ganan sobre `wall` por prioridad.
- **Columnas circulares**: forma `circle` (centro + punto del borde).
- **Excluir** objetos cuadrados sin evidencia de ser columnas (mobiliario, conductos, símbolos
  de instalaciones). Ante la duda: no etiquetar y poner bandera `ambiguous` en la imagen.

### 3.5 `stairs` — escaleras
- Polígono del **contorno exterior** de la escalera: tramos y descansos dentro de ese contorno.
  Todo lo que queda dentro (huellas, flecha, texto "SUBE", numeración) es `stairs`.
- **Escalera cortada por el plano de corte** (línea de quiebre): solo la parte dibujada.
- **Escaleras de caracol**: polígono o `circle` que cubra la planta circular.
- **Rampas, escaleras mecánicas y ascensores**: background en v0.1. Usar bandera `ambiguous`
  si la rampa es escalonada.

### 3.6 background (no se dibuja)
Mobiliario, sanitarios, artefactos, textos, cotas, ejes, grillas, solados y rayados de piso,
norte, rótulo, sellos, líneas de terreno, vegetación, autos y símbolos de instalaciones.

---

## 4. Casos especiales

| Caso | Regla |
|---|---|
| Elemento cortado por el borde de la imagen | Anotar solo la parte visible. Bandera de forma `partial`. |
| Plano incompleto (falta un sector) | Bandera de imagen `partial`. |
| Símbolo que no se puede clasificar | Bandera de forma `ambiguous` y descripción breve. Si afecta la consistencia del plano: bandera de imagen `needs_review`. |
| Muros de menos de 3 px de espesor | Resolución insuficiente: volver a importar el PDF con más `--dpi` o descartar el plano. No adivinar. |
| Planos con varias plantas en una hoja | Anotar todas. Separar páginas o recortes es una decisión de importación, no de anotación. |
| Escaneos torcidos o con manchas | Anotar sobre la imagen tal como está. No corregir mentalmente la perspectiva. |
| Elementos "existentes / a demoler" con otra trama | Anotar según lo dibujado: un muro a demoler sigue siendo `wall`. |

**Banderas de imagen** (en el panel *Flags* de LabelMe):
- `needs_review`: el pipeline **excluye** el plano del dataset hasta que se quite la bandera.
- `partial`: queda registrada en el reporte de conversión.

**Banderas por forma** (`ambiguous`, `partial`): no cambian la máscara, pero quedan listadas
en `flagged_shapes` del reporte para la revisión.

---

## 5. Flujo de trabajo en LabelMe

```powershell
# 1. Importar los planos (PDF/JPG → PNG canónico + registro)
python -m tools.import_plans --input .\incoming\proyecto_001 --project-id proyecto_001 `
    --source-type digital --output-dir .\work\raw --registry .\work\plans.csv

# 2. Anotar sobre los PNG canónicos (nunca sobre el PDF o JPG original)
labelme .\work\raw --config .\config\labelme_config.yaml --output .\annotations
```

- El JSON debe llamarse `<source_plan_id>.json`. LabelMe usa el nombre de la imagen, así que
  esto se cumple solo si se anota el PNG de `work\raw`.
- No renombrar ni editar los PNG de `work\raw` después de anotar. El pipeline lo detecta por
  hash y se detiene.
- Guardado automático activado. No se incrusta la imagen en el JSON (`with_image_data: false`).

---

## 6. Control de calidad

**Antes de dar por terminado un plano:**
- [ ] Se revisaron todas las instancias visibles de las 5 clases.
- [ ] Los muros son continuos en cruces y encuentros, y están cortados solo en vanos libres.
- [ ] Hay un rectángulo por cada puerta y ventana, dentro del espesor del muro.
- [ ] No se etiquetaron cotas, textos ni mobiliario.
- [ ] Las dudas están marcadas con `ambiguous` o `needs_review`.

**Después de convertir** (`tools.labelme_to_mask` o `tools.build_dataset`):
- Revisar los avisos de `work\masks\<id>.report.json`: conflictos entre clases, formas fuera
  de la imagen, formas duplicadas.
- Abrir la máscara superpuesta sobre la imagen en una muestra de planos (ver README §7).

**Para el lote inicial:**
- Los 10 primeros planos se revisan dos veces (anotación + revisión). Cada corrección de
  criterio se agrega a este manual con un ejemplo.
- Cada 20 planos, re-anotar uno ya hecho sin mirar el original y comparar. Un IoU por clase
  bajo indica que la convención no es clara.

---

## 7. Historial
- v0.2 (2026-11): prioridad de clases, vano como puerta (propuesta), banderas de revisión,
  configuración LabelMe, casos especiales, control de calidad.
- v0.1: versión inicial (hoja y arco como puerta, el último dibujado gana).
