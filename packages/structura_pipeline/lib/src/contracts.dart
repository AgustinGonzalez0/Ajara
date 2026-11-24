/// Contratos de integración entre la app y STRUCTURA CORE.
///
/// La app no conoce detalles del runtime de IA: obtiene un [TileInferencer]
/// desde un [InferenceRuntime] (ONNX Runtime en Android, ONNX Runtime de
/// escritorio en tests, etc.) y lo pasa al pipeline. Así se pueden sustituir o
/// actualizar modelos sin tocar la UI ni el Geometry Engine.
library;

import 'dart:typed_data';

/// Cancelación cooperativa.
class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void throwIfCancelled() {
    if (_cancelled) throw const CancelledException();
  }
}

class CancelledException implements Exception {
  const CancelledException();
  @override
  String toString() => 'Operación cancelada por el usuario';
}

/// Falla de una etapa con contexto para mostrar al usuario.
class StageFailure implements Exception {
  final String stageId;
  final String message;
  final Object? cause;
  const StageFailure(this.stageId, this.message, [this.cause]);
  @override
  String toString() => 'Etapa $stageId: $message${cause == null ? '' : ' ($cause)'}';
}

/// Evento de progreso de una etapa.
class ProgressEvent {
  final String stageId;
  final String stageLabel;
  final int stageIndex;
  final int stageCount;

  /// 0..1 dentro de la etapa, o null si es indeterminado.
  final double? fraction;
  final String? message;
  const ProgressEvent(this.stageId, this.stageLabel, this.stageIndex, this.stageCount, this.fraction, [this.message]);

  /// Progreso global aproximado 0..1.
  double get overall => (stageIndex + (fraction ?? 0)) / stageCount;
}

typedef ProgressSink = void Function(ProgressEvent event);

/// Descriptor de modelo (`<modelo>.model.json`, formato `structura-model/1`,
/// generado por `structura-core/core/export_onnx.py`).
class ModelDescriptor {
  final String id;
  final String version;
  final String task;
  final String file;
  final String? sha256;
  final List<int> inputShape;
  final List<String> classes;
  final int tile;
  final int overlap;

  /// `real`, `synthetic` o `untrained`.
  final String trainingData;
  final bool productionReady;
  final double? valMiou;
  final String notes;

  const ModelDescriptor({
    required this.id,
    required this.version,
    required this.task,
    required this.file,
    this.sha256,
    required this.inputShape,
    required this.classes,
    required this.tile,
    required this.overlap,
    required this.trainingData,
    required this.productionReady,
    this.valMiou,
    this.notes = '',
  });

  factory ModelDescriptor.fromJson(Map<String, Object?> j) {
    if (j['format'] != 'structura-model/1') {
      throw FormatException('Formato de modelo no soportado: ${j['format']}');
    }
    final input = (j['input'] as Map).cast<String, Object?>();
    final training = (j['training'] as Map? ?? const {}).cast<String, Object?>();
    final tiling = (j['tiling'] as Map? ?? const {}).cast<String, Object?>();
    final shape = (input['shape'] as List).map((e) => e as int).toList();
    if (shape.length != 4 || shape[0] != 1 || shape[1] != 3 || shape[2] != shape[3]) {
      throw FormatException('Entrada de modelo no soportada: $shape (se espera [1,3,T,T])');
    }
    final trainingData = training['data'] as String? ?? 'unknown';
    return ModelDescriptor(
      id: j['id'] as String,
      version: j['version'] as String,
      task: j['task'] as String,
      file: j['file'] as String,
      sha256: j['sha256'] as String?,
      inputShape: shape,
      classes: (j['classes'] as List).cast<String>(),
      tile: (tiling['tile'] as int?) ?? shape[2],
      overlap: (tiling['overlap'] as int?) ?? 64,
      trainingData: trainingData,
      // Solo se acepta "apto" si además se entrenó con datos reales.
      productionReady: training['production_ready'] == true && trainingData == 'real',
      valMiou: (training['val_miou'] as num?)?.toDouble(),
      notes: j['notes'] as String? ?? '',
    );
  }

  int get numClasses => classes.length;

  /// true salvo que el modelo esté entrenado con datos reales y marcado apto.
  bool get isTestModel => !productionReady;

  /// Etiqueta de confiabilidad para la UI.
  String get trustLabel => switch (trainingData) {
        'real' => productionReady ? 'Modelo entrenado con datos reales' : 'Modelo real en evaluación',
        'synthetic' => 'Modelo de prueba — entrenado solo con planos sintéticos',
        'untrained' => 'Modelo sin entrenar — solo para pruebas técnicas',
        _ => 'Procedencia de entrenamiento desconocida',
      };
}

/// Ejecuta un modelo sobre UN tile.
abstract interface class TileInferencer {
  ModelDescriptor get descriptor;

  /// [chw]: float32 de longitud 3·T·T, RGB normalizado a [0,1].
  /// Devuelve logits float32 de longitud C·T·T.
  Future<Float32List> infer(Float32List chw);

  Future<void> dispose();
}

/// Fábrica de inferencers (p. ej., ONNX Runtime Android).
abstract interface class InferenceRuntime {
  String get name;
  Future<TileInferencer> load(ModelDescriptor descriptor, String modelPath);
}

/// Imagen del plano en memoria: RGB intercalado, 3 bytes por píxel.
class PlanRaster {
  final int width;
  final int height;
  final Uint8List rgb;
  PlanRaster(this.width, this.height, this.rgb) {
    if (rgb.length != width * height * 3) {
      throw ArgumentError('rgb tiene ${rgb.length} bytes; se esperaban ${width * height * 3}');
    }
  }
}
