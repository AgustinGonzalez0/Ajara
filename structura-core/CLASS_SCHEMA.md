# Esquema de clases

| ID | Clase | Regla de anotación inicial |
|---:|---|---|
| 0 | background | Todo lo que no pertenece a las clases objetivo |
| 1 | wall | Cuerpo visible de paredes interiores y exteriores |
| 2 | door | Hoja de puerta y, según convención elegida, su símbolo |
| 3 | window | Abertura/elemento de ventana representado en planta |
| 4 | column | Sección visible de columna o pilar |
| 5 | stairs | Huella y representación de escalera |

Antes de etiquetar miles de planos, crear un manual visual con ejemplos positivos,
negativos y casos ambiguos. Mantener una convención consistente: por ejemplo,
decidir si el hueco de una puerta se etiqueta como puerta o como fondo y aplicarlo
en todo el dataset. Las clases deben ser mutuamente excluyentes en la máscara.
