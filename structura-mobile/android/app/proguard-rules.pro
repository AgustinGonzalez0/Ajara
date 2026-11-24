# ONNX Runtime: el código nativo (JNI) busca clases y métodos Java por nombre
# (ai/onnxruntime/TensorInfo, OnnxTensor, ...). Si R8 los ofusca o elimina, la
# inferencia aborta en release con "JNI DETECTED ERROR: java_class == null".
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
# Puentes de STRUCTURA invocados por MethodChannel.
-keep class com.structura.structura_mobile.** { *; }
