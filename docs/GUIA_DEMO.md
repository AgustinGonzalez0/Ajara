# Guía para presentar STRUCTURA AI a un maestro mayor de obra

Presentación (15 diapositivas, con notas para el orador):
https://claude.ai/artifact/7z9EE3JYxSP8DwZA281ehq — es privada hasta que se comparta desde
el menú **Compartir** de la página. Se puede exportar a PDF o PowerPoint desde ese mismo menú.

Material en `Ajara\entrega\` (no se versiona):

| Archivo | Para qué |
|---|---|
| `STRUCTURA-AI-celulares-modernos.apk` | Instalador para celulares de 64 bits (casi todos desde 2017) |
| `STRUCTURA-AI-celulares-32bits.apk` | Instalador para celulares viejos de 32 bits |
| `informe_evaluacion_ejemplo.pdf` | Informe de 3 páginas para mostrar o imprimir |
| `capturas/` | 11 capturas del flujo completo, por si falla la demo en vivo |

## El día anterior

1. Instalar el APK en el celular de la demo y abrir la app una vez.
2. **Configuración → Motor al importar un plano → IA** (de fábrica viene en *Clásico*, que no usa IA).
   Dejar activado **Modelo 3D detallado**.
3. Hacer una prueba completa con un plano impreso y **dejar ese proyecto guardado**: si en la
   reunión hay poca luz o el plano no se lee bien, se abre ese proyecto y se sigue desde ahí.
4. Imprimir `informe_evaluacion_ejemplo.pdf` y llevar un plano en papel simple (una planta,
   trazo nítido, sin muchas cotas encima).
5. Cargar el celular. No hace falta internet: la app no lo usa.

## Guion (unos 16 minutos)

| Min | Diapositivas | Qué hacer |
|---|---|---|
| 0–2 | 1–3 | Problema y propuesta en una frase: foto → 3D → evaluación, sin internet. |
| 2–7 | 4 (demo) | **En vivo**: *Fotografiar plano* → ajustar el recorte → *Generar modelo 3D* → girar el 3D con el dedo → *Evaluar* → marcar una medida conocida (por ejemplo un muro de 4,50 m) → elegir zona sísmica y suelo → ver resultados → abrir el 3D de sismo y de tsunami → *Compartir informe PDF*. |
| 7–9 | 5–6 | Explicar que la IA **solo lee** el plano y que los números salen de fórmulas. Mostrar el texto "Modelo afinado: …" en el panel del proyecto. |
| 9–11 | 7–9 | Métodos (INPRES-CIRSOC 103, FEMA P-646, q = 0,613·V²), el semáforo y el informe impreso. |
| 11–12 | 10 | **En vivo**: panel → *Cómputo* (m² por ambiente, muros por espesor, revoques; subir la altura con +) → *Compartir planilla*. Volver y tocar *Plano DXF*: es lo que más le sirve a un MMO para seguir en AutoCAD. |
| 12–14 | 11–13 | Números medidos y **límites**, dichos por nosotros antes de que pregunten. Privacidad. |
| 14–16 | 14–15 | Pedirle su opinión: datos de la evaluación, qué le falta al informe, planos reales para probar. |

Si la lectura sale mal (muro de más, puerta como ventana): abrir **Plano**, tocar el elemento y
borrarlo o cambiarle el tipo. Mostrar esto suma: se ve que el profesional tiene el control.

## Preguntas probables y respuestas honestas

- **¿Esto reemplaza el cálculo?** No. Es una evaluación preliminar para priorizar qué revisar.
  Lo dice cada informe y la app nunca declara que algo es "seguro".
- **¿De dónde salen los números?** De fórmulas publicadas y simplificadas. El informe lista cada
  supuesto y cada método. Con los mismos datos da siempre el mismo resultado.
- **¿La IA puede equivocarse?** Sí, sobre todo con fotos inclinadas o planos muy cargados. Por eso
  se ve lo que detectó y se corrige a mano antes de evaluar.
- **¿Qué tan precisa es?** En planos CAD reales de obras que nunca vio, acierta el 83 % de lo que
  marca como muro y encuentra el 82 % de los muros (IoU 0,70; antes del ajuste, 0,34). En planos
  generados por computadora, 0,89 de mIoU. Falta medirla con **fotos** de planos impresos.
- **¿El cómputo sirve para presupuestar?** Para pre-dimensionar: largos por eje, alturas
  declaradas y superficies aproximadas. El cómputo definitivo se hace sobre el proyecto.
- **¿El DXF queda listo?** Queda en metros y por capas (muros, puertas, ventanas, columnas,
  escaleras, ambientes). Es la detección automática: hay que revisarlo antes de usarlo.
- **¿Qué datos pide?** Una medida conocida del plano, zona sísmica, tipo de suelo y datos del
  edificio (pisos, altura de piso y material de los muros; hay modelos típicos para elegir). Para tsunami, altura de
  inundación y dirección; para viento, velocidad básica y dirección.
- **¿Conoce armaduras o fundaciones?** No. Solo evalúa lo que se ve en planta y lo que se declara.
- **¿Manda mis planos a algún lado?** No. La app no tiene permiso de internet.
- **¿En qué celulares anda?** Android 7 o superior. El motor sin IA anda en cualquiera; la IA en
  la mayoría de los celulares actuales. El tiempo en teléfonos de gama media todavía no se midió.

## Qué no decir

- Que el edificio "resiste" o "es seguro".
- Que la IA ya está validada con planos reales: está **en validación**.
- Que la IA calcula: solo lee el plano.
