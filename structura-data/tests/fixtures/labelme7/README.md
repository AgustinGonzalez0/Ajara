# Fixture LabelMe 7.11

- `plan_lm7.json`: escrito con `labelme._label_file.write_label_file` de **LabelMe 7.11.0**
  y reabierto con `read_label_file` sin errores (2026-11-24). Contiene: `rectangle`
  (entero y subpíxel), `polygon`, `oriented_rectangle`, `circle`, `mask`, banderas de imagen
  (`needs_review`, `partial`) y una bandera de forma (`ambiguous`).
- `plan_lm7.png`: imagen anotada (120x90).
- `plan_lm7_reference.png`: máscara de referencia rasterizada con el rasterizador interno de
  LabelMe (`_automation._suppression.rasterize_shape`) y la prioridad de `config/classes.yaml`.

Resultado medido: coincidencia exacta en el rectángulo entero, el polígono y la forma `mask`.
26 píxeles distintos, todos en el contorno (rectángulo con coordenada 58.6 y círculo), por las
distintas convenciones de redondeo subpíxel. No regenerar sin volver a verificar con LabelMe real.
