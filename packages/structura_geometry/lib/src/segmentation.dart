/// Resultado de segmentación semántica sobre el plano completo.
library;

import 'dart:typed_data';

/// IDs de clase de Vision AI 0.1 (config/classes.yaml de structura-data).
abstract final class ClassId {
  static const background = 0;
  static const wall = 1;
  static const door = 2;
  static const window = 3;
  static const column = 4;
  static const stairs = 5;
  static const names = ['background', 'wall', 'door', 'window', 'column', 'stairs'];
}

class SegmentationResult {
  final int width;
  final int height;

  /// Etiqueta por píxel, fila mayor (y * width + x).
  final Uint8List labels;

  /// Probabilidad de la clase elegida por píxel (0..1); null si no se dispone.
  final Float32List? confidence;

  SegmentationResult({required this.width, required this.height, required this.labels, this.confidence}) {
    if (width <= 0 || height <= 0) throw ArgumentError('dimensiones inválidas $width x $height');
    if (labels.length != width * height) {
      throw ArgumentError('labels tiene ${labels.length} valores; se esperaban ${width * height}');
    }
    if (confidence != null && confidence!.length != width * height) {
      throw ArgumentError('confidence con longitud incorrecta');
    }
  }

  int labelAt(int x, int y) => labels[y * width + x];

  /// Píxeles por clase.
  List<int> classHistogram([int numClasses = 6]) {
    final h = List<int>.filled(numClasses, 0);
    for (final v in labels) {
      if (v < numClasses) h[v]++;
    }
    return h;
  }
}
