# Vision AI en planos CAD reales (2026-11-24)

Primera medición de la IA fuera de los planos generados por STRUCTURA, y ajuste fino con
planos reales. Los planos son **privados** (49 DWG del usuario): no se versionan ni se
redistribuyen; solo se publican las métricas.

## Datos

| Paso | Herramienta | Resultado |
|---|---|---|
| DWG → DXF | LibreDWG `dwg2dxf` (solo en la PC) | 49 archivos AC1032 |
| DXF → imagen + máscara | `tools.cad_extract` (capas Muros, Ventanas, Puertas, Columnas, Escalera…) | 55 láminas, 47 únicas, 4 archivos ilegibles |
| Dataset de ajuste | `tools.build_cad_dataset` | 47 láminas útiles: 34 train · 3 validación · 10 test |

**Etiquetas débiles.** Muchos archivos dibujan parte de los muros en capas que no se llaman
"Muros". Para no enseñar que un muro sin capa es fondo, se marcan como **ignorados (255)**:
las bandas entre líneas paralelas a un espesor de muro sin etiqueta y un anillo de 2 px
alrededor de cada etiqueta. El resto del fondo (papel, muebles, cotas, textos) sí cuenta.

**Splits por obra** (`group_of`): las versiones de una misma obra (p. ej. todo lo del
"edificio 72", o el centro cultural en sus tres archivos) van juntas. Test = 6 obras que
el modelo nunca vio: centro cultural, dos viviendas, un replanteo, un boceto y un plano de
estructuras.

## Ajuste fino

`core.train --init vec_v1_ce/best.pt --dataset cad_ft_v1 --mix-dataset dataset_vector_v1
--mix-tiles 3000 --lr 3e-4 --epochs 12 --photometric-aug`. Se mezclan 3 000 tiles Swiss
para no olvidar lo aprendido; la loss ignora los píxeles 255. RTX 5070, ~45 s por época.
Mejor época por validación: 11.

## Resultados (planos completos, modelo FP32)

**Test CAD con píxeles dudosos ignorados** (10 láminas de obras no vistas):

| Métrica | Antes (v0.2) | Después (v0.3) |
|---|---:|---:|
| IoU muros | 0,341 | **0,700** |
| Precisión / recall muros | 0,425 / 0,634 | **0,828 / 0,820** |
| IoU puertas | 0,117 | 0,204 |
| IoU columnas | 0,566 | 0,575 |
| IoU escaleras | 0,105 | 0,260 |
| mIoU | 0,351 | 0,457 |

Con la máscara original (sin ignorar), IoU muros 0,286 → 0,487: la precisión queda
subestimada porque los muros sin capa cuentan como errores.

**Plantas Swiss de prueba** (120 planos, control de olvido): mIoU 0,889 → 0,876
(muros 0,944 → 0,924). Pérdida chica frente a la ganancia en planos reales.

**Ventanas:** en CAD casi no hay píxeles etiquetados como ventana (IoU < 0,02 en ambos
modelos); la medición no es confiable y no se saca conclusión.

**INT8** (lo que corre en el teléfono): 1,92 MB, coincide con FP32 en el 99,85 % de los
píxeles (mínimo 99,1 %), calibrado con 120 tiles Swiss + 120 CAD.

## Lo que todavía no se sabe

- Desempeño en **fotos** de planos impresos (el test es CAD rasterizado, sin perspectiva ni
  sombras). Es la próxima medición.
- Las obras de train son pocas (la mayoría, un mismo edificio): más obras distintas mejorarían
  la generalización.

## Reproducir

```powershell
cd $env:USERPROFILE\Desktop\Ajara\structura-data
..\.venv\Scripts\python.exe -m tools.build_cad_dataset --cad ..\data\cad_soto --output ..\data\cad_ft_v1 `
  --test-groups "centro_cultural,casa_sistemas_copia,adaptacion_vivienda_i_a_a,proyecto_alsina_y_melo_bocetos_viejos,replajteo_pp,estrucutras" `
  --val-groups "inst_electrica"
cd ..\structura-core
..\.venv\Scripts\python.exe -m core.benchmark --plans ..\data\cad_ft_v1_test_ign `
  --checkpoint base=..\data\runs\vec_v1_ce\best.pt --checkpoint ft=..\data\runs\cad_ft_v1\best.pt --output ..\data\runs\bench_cad
```
