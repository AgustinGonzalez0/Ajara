# PROGRESS — STRUCTURA AI (actualizado 2026-11-24)

## Qué funciona hoy (probado en emulador Android 17 con el APK de release)

### Flujo con pocos toques
| Tarea | Toques | Antes |
|---|---|---|
| Foto de galería → modelo 3D | **3** (Galería · elegir foto · Generar modelo 3D) | ~8 y tipear un nombre |
| Modelo 3D → evaluación con resultados | **4** (Evaluar · 2 puntos de la cota · ✓ del teclado) + Evaluar | ~7 y varios scrolls |
| Resultados → informe PDF compartido | **1** (PDF, o el botón fijo del panel) | — |

- **Dashboard**: tarjeta principal "De una foto a un modelo 3D" con Fotografiar / Galería /
  PDF o imagen. El proyecto se crea solo con nombre automático (se renombra tocando el título)
  y se descarta si se cancela la foto.
- **Panel del proyecto**: el 3D gira en la vista previa, chips con lo detectado, 4 accesos
  (Modelo 3D, Plano, Evaluación, Informe PDF) y **la acción siguiente fija abajo**.
  Todo entra en una pantalla de teléfono.
- **Evaluación**: presets de edificio, zonas INPRES-CIRSOC 103, suelo en chips, tsunami y
  viento resumidos, pasos ±; "Evaluar" siempre visible; resultados arriba como semáforo
  desplegable; restaura la última evaluación. Sin escala, va directo a calibrar.
- **Calibración**: foco automático en la cota, manijas con lupa y chequeo de sensatez
  ("con esta escala: muros ≈ 15 cm · planta ≈ 12 × 9 m").
- **Visor 3D** a pantalla completa: cambio Modelo / Sismo / Tsunami / Viento sin volver
  atrás, leyenda y barra flotantes, capas e info en hojas inferiores, compartir GLB.
- **Plano y detecciones**: tocar un elemento para eliminarlo o cambiar puerta ↔ ventana,
  con deshacer. Queda como `userCorrected`, se regenera el GLB y se descarta la
  evaluación anterior.
- **Informe PDF** generado en el teléfono: resumen con semáforo, plano, datos declarados,
  mapa de calor por muro para cada peligro, supuestos, métodos, espacio para la revisión
  profesional y trazabilidad (SHA-256 del plano).

### Motores
1. **Clásico sin IA (por defecto)**: ~100 ms. Muy bueno con muros macizos negros;
   **flojo con muros rayados, en contorno o grises** (medido abajo).
2. **Vision AI**: ver "Modelo entrenado con plantas reales".

### Privacidad
Release sin permiso de internet y sin telemetría de ONNX Runtime (verificado).
`share_plus` no agrega permisos: entrega el archivo a la app que elija el usuario.

## Dataset y modelo
- **Dataset vectorial v1**: 1 499 plantas reales de Swiss Dwellings (CC BY 4.0) dibujadas con
  estilos variados → 28 511 tiles con máscara exacta, splits por sitio (1 183 sitios). Ver
  [`DATASETS.md`](DATASETS.md).
- **Experimento A vs B** (D-18): misma receta, 20 épocas, aumentos fotométricos en ambos;
  A = CrossEntropy (especificación 0.1), B = CrossEntropy ponderada ENet.
  Resultados: ver sección "Modelo entrenado con plantas reales".

## Tests (último run: todos OK)
| Suite | Comando | Resultado |
|---|---|---|
| structura-data | `python -m unittest discover -s tests -t .` | 93 OK |
| structura-core | idem | 22 OK |
| structura_model / vision / geometry / pipeline / sim | `dart test` | 5 / 6 / 8 / 9 / 9 OK |
| structura-mobile | `flutter test` | 34 OK (flujo rápido, cancelación, escala, evaluación, PDF, 3D, corrección) |
| Release | `powershell -File tool\verify_release.ps1` | sin red · sin telemetría · clases ONNX conservadas |

**Total: 186 tests automatizados.**

## Mediciones
| Medida | Valor | Dónde |
|---|---|---|
| Detección clásica (foto 1007×797) | 106 ms | emulador x86_64, release |
| APK release arm64 / armeabi-v7a | 57,6 MB / 45,7 MB | — |

> Los tiempos del emulador **no representan** un teléfono ARM real.

## Limitaciones conocidas (honestas)
- El modelo se entrenó con plantas **dibujadas por STRUCTURA** a partir de geometría real
  suiza. Falta validarlo con **fotos de planos argentinos reales**.
- Convención de puertas usada en el dataset: **vano** (D-17 sigue pendiente; regenerar con la
  otra convención lleva minutos).
- Evaluación: métodos simplificados. No reemplaza el cálculo ni la verificación normativa.
- No se probó en un teléfono físico.

## Pendientes (prioridad)
1. **Decisiones del responsable**: D-17 (puertas), D-18 (función de pérdida, con la evidencia
   del experimento), D-29 (ResPlan), motor por defecto (clásico o IA), anotación de un lote
   real (manual o asistida).
2. Probar en el S26 Ultra y en un celular de gama baja: tiempos, memoria, temperatura.
3. Lote de fotos reales anotadas para medir el desempeño verdadero.

## Para continuar
```powershell
cd $env:USERPROFILE\Desktop\Ajara; git checkout develop; git log --oneline | Select-Object -First 8
C:\Users\Agusr\AppData\Local\Android\sdk\emulator\emulator.exe -avd Pixel_9
cd structura-mobile; flutter run -d emulator-5554
```
