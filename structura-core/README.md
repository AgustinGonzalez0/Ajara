# STRUCTURA CORE — primer prototipo ejecutable

Prototipo de investigación para segmentación semántica de planos arquitectónicos.
No es un sistema de ingeniería ni valida seguridad estructural.

## 1. Requisitos
- Python 3.10 o 3.11
- Para entrenar: PyTorch instalado según CPU/CUDA de tu equipo.
- Para inferencia: ONNX Runtime o PyTorch.

## 2. Instalar
```bash
python -m venv .venv
# Windows:
.venv\Scripts\activate
# Linux/macOS:
source .venv/bin/activate

pip install -r requirements.txt
```

Si `pip install torch` no instala una versión adecuada para tu GPU, instalá PyTorch
siguiendo el selector oficial de instalación de PyTorch. El prototipo también puede
entrenarse en CPU, aunque será más lento.

## 3. Dataset
Estructura:
```text
dataset/
  images/
    plan_0001.png
  masks/
    plan_0001.png
  splits/
    train.txt
    validation.txt
```

Cada imagen y máscara debe compartir el mismo nombre base y dimensiones.
La máscara debe ser PNG en escala de grises con IDs:
- 0 fondo
- 1 pared
- 2 puerta
- 3 ventana
- 4 columna
- 5 escalera

Los valores de la máscara son IDs, no colores RGB. No uses máscaras JPEG.

Los archivos `train.txt` y `validation.txt` contienen un nombre base por línea,
por ejemplo `plan_0001` (sin extensión). Separá por proyecto de origen: no pongas
recortes del mismo plano original en train y validation.

## 4. Entrenar
```bash
python -m core.train --dataset ./dataset --epochs 40 --batch-size 4 --output ./artifacts
```

El modelo espera imágenes RGB y máscaras con IDs de clase. Si el dataset es pequeño,
empezá con 10–20 épocas para verificar que todo funciona.

## 5. Inferencia de prueba
```bash
python -m core.predict --model ./artifacts/best.pt --input ./examples/plano.png --output ./artifacts/prediction
```
Genera `mask.png` y `overlay.png`.

## 6. Exportar a ONNX
```bash
python -m core.export_onnx --checkpoint ./artifacts/best.pt --output ./artifacts/vision_ai.onnx
```

## 7. Probar ONNX Runtime en escritorio
```bash
python -m core.predict_onnx --model ./artifacts/vision_ai.onnx --input ./examples/plano.png --output ./artifacts/onnx_prediction
```

## Alcance deliberado del prototipo
- Una U-Net compacta con seis clases.
- Entrada redimensionada a 512x512.
- Entrenamiento supervisado con máscaras dibujadas/validadas por personas.
- Exportación ONNX con tamaño fijo 512x512.
- No incluye todavía detección de escala, reconstrucción 3D, inferencia por teselas,
  segmentación vectorial de PDF ni ejecución Android.
