# PROGRESS — STRUCTURA AI (actualizado 2026-11-24)

## Qué funciona hoy (probado en emulador Android 17 con el APK de release)
1. **Una foto → 3D**: cámara o galería del sistema, hoja detectada automáticamente,
   esquinas ajustables, corrección de perspectiva e iluminación.
2. **Motor clásico sin IA (por defecto)**: en la foto de prueba detectó muros, 1 puerta y
   1 ventana en **106 ms** (detección) + 15 ms (vectorización).
3. **Vision AI opcional** (ONNX Runtime nativo, modelo INT8 de prueba de 1,92 MB).
4. **Editor 2D, modelo 3D y GLB**.
5. **Evaluación preliminar**: calibración con 2 puntos sobre una cota, pisos, material y
   espesor declarado, sismo, tsunami y viento con semáforo y supuestos; **simulación 3D** con
   mapa de calor, vaivén sísmico (exagerado) y agua de tsunami.
6. **Privacidad**: release sin permiso de internet y sin telemetría de ONNX Runtime.

## Tests (último run: todos OK)
| Suite | Comando | Resultado |
|---|---|---|
| structura-data | `python -m unittest discover -s tests -t .` | 85 OK |
| structura-core | idem | 18 OK (incluye AMP CUDA, paridad ONNX y cuantización INT8) |
| structura_model / vision / geometry / pipeline / sim | `dart test` | 5 / 6 / 8 / 9 / 9 OK |
| structura-mobile | `flutter test` | 24 OK (incluye foto → modelo y flujo análisis → escala → evaluación → 3D) |
| Android E2E | `flutter test integration_test\device_e2e_test.dart -d emulator-5554` | 1 OK (INT8 en el dispositivo) |
| Release | `powershell -File tool\verify_release.ps1` | sin red · sin telemetría · clases ONNX conservadas |

**Total: 164 tests automatizados más la prueba E2E en Android.**

## Mediciones
| Medida | Valor | Dónde |
|---|---|---|
| Detección clásica (foto 1007×797) | 106 ms | emulador x86_64, release |
| Vision AI INT8 por tile 512² | ~596 ms (debug) | emulador x86_64; en la CPU de la PC 29,7 ms frente a 53,5 ms de FP32 |
| Modelo IA | 7,41 MB → 1,92 MB (INT8), acuerdo de argmax 100 % | PC |
| APK release arm64 | 56,5 MB | — |
| Arranque en frío (release) | 1,33 s | emulador |
| Memoria tras el análisis con IA (release) | 160 MB PSS | emulador |

> Los tiempos del emulador **no representan** un teléfono ARM real. En el emulador x86 el
> INT8 fue más lento que el FP32; hay que medirlo en un dispositivo ARM (S26 Ultra y uno de gama baja).

## Defectos encontrados y corregidos en esta etapa
1. `Isolate.run` capturaba contexto no enviable: el análisis clásico habría fallado siempre en el dispositivo.
2. La cuantización de ONNX Runtime fallaba con rutas Unicode en Windows.
3. Fotos: muros fragmentados (28 → 11) y una puerta falsa junto a una columna adosada.
4. Desbordes de layout en teléfono (desplegable de suelo, leyenda 3D, píldoras de estado).
5. Calibración por muro inviable cuando la cota abarca varios muros: se agregó la calibración por 2 puntos.
6. El espesor detectado en una foto producía relaciones de flexión engañosas: ahora es declarable y visible.

## Limitaciones conocidas (honestas)
- Motor clásico: **no detecta escaleras ni muros dibujados con línea simple**. Las columnas
  adosadas a un muro se toman como muro. Funciona mejor con plantas ortogonales.
- El modelo de IA empaquetado está entrenado **solo con planos sintéticos** (IoU 0 en
  puertas, ventanas y columnas). Falta un dataset real.
- Evaluación: métodos simplificados. No reemplaza el cálculo ni la verificación normativa.
- No se probó en un teléfono físico (ninguno conectado).

## Pendientes (prioridad)
1. **Decisiones del responsable**: convención de anotación de puertas (D-17), función de
   pérdida (D-18, ver `EVALUACION_LOSS.md`), tipos de plano y edificio, anotación manual o asistida.
2. **Dataset real** y re-entrenamiento de Vision AI (para cubrir escaleras y muros de línea simple).
3. Probar en el S26 Ultra y en un celular de gama baja: tiempos, memoria, temperatura.
4. Corrección manual de detecciones en el editor (la procedencia `userCorrected` ya está modelada).
5. Exportar y compartir el GLB y un informe PDF de la evaluación para clientes y empresas.
6. Red: acceso a pub.dev para poder sumar paquetes.

## Para continuar
```powershell
cd $env:USERPROFILE\Desktop\STRUCTURA; git checkout develop; git log --oneline | Select-Object -First 8
C:\Users\Agusr\AppData\Local\Android\sdk\emulator\emulator.exe -avd Pixel_9
cd structura-mobile; flutter run -d emulator-5554
```
