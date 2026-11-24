# Evaluación: desbalance de clases y función de pérdida (Vision AI 0.1)

**Estado: PROPUESTA — requiere aprobación.** La especificación 0.1 fija `CrossEntropy`
sin pesos y el código actual la respeta (`structura-core/core/train.py`).

## 1. Evidencia medida (no teórica)

Entrenamiento de 40 épocas con la especificación exacta (U-Net Small, base 16, AdamW 1e-3,
batch 4, AMP FP16, RTX 5070) sobre el **dataset sintético** de structura-data (47 tiles).
Evaluación en `test`:

| Clase | % de píxeles | IoU test |
|---|---:|---:|
| background | ~93 % | 0.998 |
| wall | ~5.5 % | 0.992 |
| stairs | ~0.9 % | 0.988 |
| door | ~0.45 % (train) | **0.000** |
| window | ~0.07 % | **0.000** |
| column | ~0.04 % | **0.000** |

mIoU 0.496. El modelo **nunca predice** puertas, ventanas ni columnas: con CE sin pesos,
el gradiente de las clases minoritarias es despreciable frente al de fondo y muros.
Es un dataset sintético y chico: el número exacto no es representativo, pero el
mecanismo sí lo es. En planos reales la proporción de ventanas y columnas es igual o
menor (son elementos pequeños).

En el dispositivo se confirmó lo mismo: el modelo de prueba detectó 7 muros y 1 escalera
y ninguna puerta en una planta con puerta.

## 2. Alternativas

| Opción | Cambio | Ventajas | Riesgos |
|---|---|---|---|
| A. CE sin pesos (actual) | ninguno | especificación original | clases minoritarias ignoradas (medido) |
| **B. CE ponderada** | pesos por clase `w_c = 1 / log(1.02 + f_c)` (ENet), calculados del split train y guardados en el checkpoint | cambio mínimo; misma loss; interpretable; sin hiperparámetros nuevos salvo la fórmula | puede aumentar falsos positivos de clases raras (se mide con precision) |
| C. CE + Dice | `CE + λ·Dice` (Dice por clase, promedio sobre clases presentes) | optimiza solapamiento directamente; robusta a desbalance | un hiperparámetro (λ); curvas menos estables con batch 4 |
| D. Focal loss | `(1-p)^γ · CE` | enfatiza píxeles difíciles | γ a ajustar; con desbalance extremo suele necesitar además pesos |
| E. Muestreo de tiles | sobre-muestrear tiles con clases raras | no cambia la loss | altera la distribución vista; riesgo de sobreajuste con pocos planos |

## 3. Recomendación

1. **Adoptar B (CE ponderada)** como Vision AI 0.1.1. Es el cambio mínimo que ataca el
   problema medido y se puede revertir con un flag (`--class-weights none`).
2. Mantener A como línea base y **comparar A vs B en el mismo split real**, usando IoU,
   precision, recall y Boundary F1 por clase (todo ya implementado en `core.evaluate`).
3. Probar C solo si B no supera IoU 0.3 en puertas y ventanas con datos reales.

No se implementó ningún cambio de loss: hace falta aprobación.

## 4. Qué decidir
- [ ] Aprobar B como experimento (con A como línea base), o
- [ ] Mantener A hasta tener el primer lote real, o
- [ ] Otra opción (C/D/E).
