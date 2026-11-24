# PROGRESS — STRUCTURA AI (actualizado 2026-11-24)

## Estado por etapa
| Etapa | Estado | Evidencia |
|---|---|---|
| 1. Auditoría y entorno | ✅ | `docs/ENTORNO.md`; red bloqueada hacia pub.dev/gradle documentada |
| 2. CORE (P0) | ✅ (entrenamiento real pendiente de datos) | 17 tests; AMP en RTX 5070; paridad ONNX 7,8e-6 |
| 3. App Flutter | ✅ base funcional | 23 tests; recorrido real en emulador (capturas verificadas) |
| 4. Building Model + Geometry | ✅ v0.1 | 5 + 8 tests; GLB válido |
| 5. Integración CORE ↔ app | ✅ con modelo de prueba | E2E Android con ONNX Runtime nativo |
| 6. Validación integral | ✅ emulador · ❌ dispositivo físico | APK debug y release probados en Pixel_9 (Android 17) |
| 7. Entrega | ✅ esta documentación + git `develop` | |

## Tests ejecutados (último run)
| Suite | Comando | Resultado |
|---|---|---|
| structura-data | `python -m unittest discover -s tests -t .` | 85 OK |
| structura-core | idem | 17 OK (incluye CUDA AMP) |
| structura_model | `dart test` | 5 OK |
| structura_geometry | `dart test` | 8 OK |
| structura_pipeline | `dart test` | 9 OK |
| structura-mobile | `flutter test` | 23 OK |
| Android E2E | `flutter test integration_test\device_e2e_test.dart -d emulator-5554` | 1 OK (2 corridas) |
| Release | `powershell -File tool\verify_release.ps1` | sin permisos de red · sin telemetría ORT · clases ORT conservadas |

## Mediciones (emulador x86_64 — NO representan al Galaxy S26 Ultra)
| Medida | Valor |
|---|---|
| Inferencia por tile 512² (ONNX Runtime CPU, debug) | ~438–454 ms |
| Inferencia por tile (release, PDF 9 tiles) | ~337 ms |
| Vectorización / malla (1100×800) | 57–63 ms / 13 ms |
| Arranque en frío (release, `am start -W`) | 1,33 s |
| Memoria tras análisis (release, PSS) | 160 MB |
| APK release arm64-v8a | 60,7 MB (universal: 164 MB) |
| PC: inferencia por tile RTX 5070 FP16 | 2,7 ms mediana |

## Defectos encontrados y corregidos en esta etapa
1. Checkpoint no cargable con `weights_only=True` (objeto `TorchVersion`).
2. `UnicodeEncodeError` al imprimir en consolas Windows cp1252.
3. Conflicto de nombre `Column` (Building Model vs. Flutter) → `ColumnElement`.
4. Desbordes de layout en teléfono y tablet (detectados por tests de widgets).
5. Isolate de análisis podía colgarse ante un error no capturado.
6. **Privacidad**: onnxruntime-android agrega `INTERNET`, `ACCESS_NETWORK_STATE` y un
   ContentProvider de telemetría que se ejecuta al arrancar → eliminados (D-05), verificado en el APK.
7. **Crash en release**: R8 ofuscaba las clases JNI de ONNX Runtime → reglas `keep`; verificado
   analizando un PDF en release.
8. Ícono y pantalla de arranque nativos eran los de Flutter → identidad STRUCTURA.

## Qué falta (prioridad)
1. **Decisiones del responsable** (bloquean el dataset real): convención de puertas (D-17) y
   función de pérdida (`docs/EVALUACION_LOSS.md`). Además: tipos de plano, tipos de construcción,
   anotación manual vs. asistida.
2. **Dataset real**: anotar el primer lote con LabelMe (manual en `structura-data/docs`).
3. **Dispositivo físico** (S26 Ultra): instalar `app-arm64-v8a-release.apk` y medir ms/tile,
   memoria y temperatura; luego evaluar XNNPACK / NNAPI-NPU con medición, no por suposición.
4. Red: resolver el acceso a pub.dev (otra red o proveedor) para poder sumar paquetes.
5. App: corrección manual de detecciones (la procedencia `userCorrected` ya está modelada),
   exportar/compartir GLB, ambientes (Spatial AI), cotas (Dimension AI).
6. Tamaño: build reducido de ONNX Runtime (solo operadores del modelo) para bajar ~30 MB.
7. Conocido: el APK **debug** lanzado sin `flutter run` queda en la pantalla nativa; usar
   `flutter run` en debug o el APK release/profile. No se investigó más (no afecta release).
8. Instalar Python 3.11 si se quiere respetar la versión de la especificación (opcional).

## Para continuar
```powershell
cd C:\STRUCTURA; git checkout develop; git log --oneline | Select-Object -First 5
# Emulador: C:\Users\Agusr\AppData\Local\Android\sdk\emulator\emulator.exe -avd Pixel_9
cd structura-mobile; flutter run -d emulator-5554
```
