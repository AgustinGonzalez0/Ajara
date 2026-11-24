# Evaluación preliminar de sismo, tsunami y viento

> **Qué es y qué no es.** STRUCTURA hace una *evaluación preliminar (screening)*: estima
> órdenes de magnitud de demanda frente a capacidad para priorizar riesgos y comunicarlos
> visualmente. **No es un cálculo estructural**, no verifica normas (CIRSOC, INPRES-CIRSOC
> 103, ASCE 7, Eurocódigo, etc.) y **nunca declara que una estructura es segura**. Un plano
> 2D o una foto no contienen armaduras, fundaciones, suelo de apoyo, calidad constructiva ni
> estado de conservación. Toda decisión requiere un profesional habilitado.

## Requisitos
1. **Escala verificada**: el profesional marca los dos extremos de una cota conocida y carga
   su valor (o usa el largo de un muro). Sin escala no hay evaluación: no se inventan metros.
2. **Datos declarados**: pisos, altura de piso, material de muros y, recomendado, el
   **espesor real de muros** (el detectado en una foto puede ser impreciso).

## Métodos (paquete `packages/structura_sim`, verificados con cálculos a mano en los tests)

### Sismo / terremoto: fuerza lateral estática equivalente
- Período: `T ≈ 0,05·H^0,75`.
- Espectro de meseta: `Sa = 2,5·PGA·S`; si `T > Tc`, se multiplica por `Tc/T`.
- Coeficiente sísmico: `Cs = Sa / R`.
- Peso: `W = pisos · (q_losa · A_planta + γ · Σ(L·t·h))`.
- Corte basal: `V = Cs · W`.
- Capacidad por dirección: `τ · ΣA_muros` (área de corte de los muros paralelos a la dirección).
- Torsión en planta (diafragma rígido, rigidez ∝ área de corte): centro de rigidez,
  excentricidad real más una accidental de ±5 %, y fuerza por muro `V·k/Σk + V·e·k·d/J`.
- Indicadores:
  - Demanda/capacidad en X e Y.
  - Muro más exigido.
  - Excentricidad e/L. Umbrales: 0,1 para revisar y 0,2 crítico.
  - Densidad de muros en cada dirección.

### Tsunami (FEMA P-646, simplificado)
- Presión hidrodinámica: `½·ρs·Cd·u²`, con `ρs = 1100 kg/m³` (agua con sedimentos) y `Cd = 2`.
- Presión hidrostática: `ρs·g·(h − z)` sobre la planta baja.
- Velocidad: `u` la declara el profesional o, si no, se estima como `√(g·h)` (simplificación declarada).
- Muros perpendiculares al flujo: flexión fuera del plano, como viga simple de luz igual a la
  altura de piso (integración numérica). La capacidad es `f·t²/6`.
- Muros paralelos al flujo: corte.
- Global: deslizamiento `F / (μ·W)`.
- Excluido: impacto de escombros, socavación y subpresión (flotación).

### Viento
- `q = 0,613·V²`, con coeficiente neto de 1,3 sobre las fachadas.
- Flexión fuera del plano de los muros exteriores perpendiculares al viento.
- Corte basal.
- Sin factores normativos de exposición, topografía ni ráfaga.

## Lectura de resultados
| Relación demanda/capacidad | Semáforo | Texto en la app |
|---|---|---|
| < 0,7 | verde | Dentro de lo esperable |
| 0,7 – 1,0 | amarillo | Revisar |
| > 1,0 | rojo | Demanda supera capacidad estimada |
| ≥ 10 | rojo | "> 10 ×" (no se muestra una precisión que el método no tiene) |

En 3D, cada muro se colorea con su relación. La animación sísmica exagera la
deformación solo para visualizar el modo de vibración, y la de tsunami muestra el agua
subiendo hasta la profundidad declarada.

## Materiales (valores indicativos, no de norma)
| Material | γ kN/m³ | τ MPa | f flexión MPa | R |
|---|---|---|---|---|
| Adobe | 16 | 0,03 | 0,02 | 1,5 |
| Ladrillo sin confinar | 18 | 0,10 | 0,10 | 1,5 |
| Mampostería confinada | 18 | 0,25 | 0,15 | 2,5 |
| Bloque de hormigón armado | 20 | 0,30 | 0,40 | 3,0 |
| Hormigón armado | 24 | 0,80 | 2,00 | 4,0 |

## Trazabilidad
Cada evaluación queda en `analysis/<run>/screening.json`. Incluye entradas, propiedades de
material, supuestos, indicadores, relaciones por muro y la advertencia. El historial del
proyecto registra la calibración de escala (método y puntos) y cada ejecución.
