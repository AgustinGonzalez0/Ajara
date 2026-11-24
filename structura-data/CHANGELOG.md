# Changelog

## 0.3.0 — 2026-11-24
### Nuevo
- `tools.import_plans`: PDF/PNG/JPG/TIFF → PNG canónico, registro `plans.csv`, DPI con su origen,
  detección de duplicados.
- `tools.build_dataset`: pipeline completo con corte ante errores. No genera splits sin
  validación.
- `tools.make_overlay`: revisión visual máscara/imagen.
- `tools.common`: E/S Unicode-safe y atómica, esquema de clases desde `classes.yaml`,
  validación estricta de IDs, booleanos, unidades y escala.
- Manifiesto por plano (`plans/<id>.json`) y verificación por reconstrucción exacta.
- `config/labelme_config.yaml` (verificada con LabelMe 7.11), `config/plans_template.csv`.
- 85 tests (`unittest`), generador sintético y demo de punta a punta, fixture de LabelMe 7.11 real.
- Documentación: manual de anotación v0.2, decisiones técnicas, esquema de metadatos, auditoría.

### Cambiado
- `labelme_to_mask`: solapamientos por prioridad de clase (antes: última forma gana; sigue
  disponible con `--overlap-policy order`), rasterización subpíxel, `mask`/`oriented_rectangle`/
  `points`, trazos de ancho exacto, reporte por plano, controles de imagen y dimensiones.
- `make_dataset_tiles`: metadata v1 (resolución, hashes, relleno, conteos de clase), protección
  contra tiles obsoletos, verificación después de escribir, modo batch `--registry`.
- `validate_dataset`: controles de huérfanos, duplicados, ediciones posteriores, relleno,
  coherencia entre planos, reconstrucción, splits. Informe JSON. Opción `--dataset`.
- `make_splits`: heurística LPT por déficit, controles de fuga, píxeles por clase en cada split.

### Corregido
- `scale_verified: "false"` se interpretaba como `true`.
- Polígonos degenerados se descartaban sin aviso.
- Rutas Unicode en Windows.
- PNG con transparencia se leían con fondo negro.
- `units: "meters"` (ejemplo del README v0.2) se normaliza a `m`.
- El tiler en modo `--registry` omite los planos con `needs_review`, igual que `build_dataset`.
- Los TIFF multipágina se rechazan en lugar de importar solo la primera página.

### Eliminado
- Dependencia `tqdm` (no se usaba).

## 0.2.0
Versión inicial auditada (ver `docs/AUDITORIA_v0.2.md`).
