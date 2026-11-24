/// Primitivas geométricas, procedencia, confianza y unidades.
///
/// Convención de coordenadas: TODAS las geometrías del Building Model se
/// guardan en píxeles del plano rasterizado (origen arriba-izquierda, x hacia
/// la derecha, y hacia abajo). Las medidas reales solo existen si hay una
/// [PlanScale] verificada; si no, son `null` (desconocidas).
library;

import 'dart:math' as math;

/// Punto 2D en píxeles del plano.
class Point2 {
  final double x;
  final double y;
  const Point2(this.x, this.y);

  Point2 operator +(Point2 o) => Point2(x + o.x, y + o.y);
  Point2 operator -(Point2 o) => Point2(x - o.x, y - o.y);
  Point2 operator *(double k) => Point2(x * k, y * k);
  double distanceTo(Point2 o) => math.sqrt((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y));
  bool get isFinite => x.isFinite && y.isFinite;

  List<double> toJson() => [x, y];
  factory Point2.fromJson(Object? json) {
    final l = json as List;
    return Point2((l[0] as num).toDouble(), (l[1] as num).toDouble());
  }

  @override
  bool operator ==(Object other) => other is Point2 && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => 'Point2($x, $y)';
}

/// Rectángulo alineado a ejes (píxeles).
class Rect2 {
  final double left, top, right, bottom;
  const Rect2(this.left, this.top, this.right, this.bottom);
  double get width => right - left;
  double get height => bottom - top;
  Point2 get center => Point2((left + right) / 2, (top + bottom) / 2);
  bool get isValid => width > 0 && height > 0 && [left, top, right, bottom].every((v) => v.isFinite);
  List<Point2> get corners => [Point2(left, top), Point2(right, top), Point2(right, bottom), Point2(left, bottom)];
  List<double> toJson() => [left, top, right, bottom];
  factory Rect2.fromJson(Object? json) {
    final l = (json as List).map((e) => (e as num).toDouble()).toList();
    return Rect2(l[0], l[1], l[2], l[3]);
  }
}

/// Origen de un dato. Separa explícitamente IA, usuario, derivación geométrica y desconocido.
enum Provenance {
  /// Detectado por un modelo de IA (ver [Source.modelId]).
  aiDetected,

  /// Detectado por un algoritmo clásico de visión por computadora (sin IA, determinista).
  /// No tiene confianza probabilística calibrada.
  classicDetected,

  /// Detectado por IA y luego corregido por el usuario.
  userCorrected,

  /// Creado manualmente por el usuario.
  userCreated,

  /// Calculado de forma determinista por el Geometry Engine a partir de otros datos.
  derived,

  /// Leído de un archivo (p. ej., metadatos de importación).
  imported,

  /// Origen no registrado.
  unknown;

  static Provenance parse(String? s) =>
      Provenance.values.firstWhere((p) => p.name == s, orElse: () => Provenance.unknown);
}

/// Detalle de procedencia: qué produjo el dato y cuándo.
class Source {
  final Provenance provenance;
  final String? modelId;
  final String? modelVersion;

  /// Datos con los que se entrenó el modelo: `real`, `synthetic`, `untrained` o null.
  final String? modelTrainingData;
  final DateTime? timestamp;
  final String? note;

  const Source(this.provenance,
      {this.modelId, this.modelVersion, this.modelTrainingData, this.timestamp, this.note});

  const Source.unknown() : this(Provenance.unknown);

  Map<String, Object?> toJson() => {
        'provenance': provenance.name,
        'model_id': modelId,
        'model_version': modelVersion,
        'model_training_data': modelTrainingData,
        'timestamp': timestamp?.toUtc().toIso8601String(),
        'note': note,
      };

  factory Source.fromJson(Map<String, Object?> j) => Source(
        Provenance.parse(j['provenance'] as String?),
        modelId: j['model_id'] as String?,
        modelVersion: j['model_version'] as String?,
        modelTrainingData: j['model_training_data'] as String?,
        timestamp: j['timestamp'] == null ? null : DateTime.parse(j['timestamp'] as String),
        note: j['note'] as String?,
      );

  Source copyWith({Provenance? provenance, String? note}) => Source(provenance ?? this.provenance,
      modelId: modelId,
      modelVersion: modelVersion,
      modelTrainingData: modelTrainingData,
      timestamp: timestamp,
      note: note ?? this.note);
}

/// Unidades de longitud reales.
enum LengthUnit {
  mm(0.001),
  cm(0.01),
  m(1.0),
  inch(0.0254),
  ft(0.3048);

  final double meters;
  const LengthUnit(this.meters);

  static LengthUnit? tryParse(String? s) {
    for (final u in LengthUnit.values) {
      if (u.name == s) return u;
    }
    return null;
  }
}

/// Escala del plano: píxeles por unidad real. Solo se usa para medidas reales
/// si [verified] es true (medida contra una cota por una persona o un proceso validado).
class PlanScale {
  final double pxPerUnit;
  final LengthUnit unit;
  final bool verified;
  final Source source;

  const PlanScale({required this.pxPerUnit, required this.unit, required this.verified, required this.source});

  /// Convierte píxeles a metros, o null si la escala no está verificada.
  double? pxToMeters(double px) => verified ? px / pxPerUnit * unit.meters : null;

  Map<String, Object?> toJson() =>
      {'px_per_unit': pxPerUnit, 'unit': unit.name, 'verified': verified, 'source': source.toJson()};

  factory PlanScale.fromJson(Map<String, Object?> j) => PlanScale(
        pxPerUnit: (j['px_per_unit'] as num).toDouble(),
        unit: LengthUnit.tryParse(j['unit'] as String?) ?? LengthUnit.m,
        verified: j['verified'] == true,
        source: Source.fromJson((j['source'] as Map).cast<String, Object?>()),
      );
}

double? _toDouble(Object? v) => v == null ? null : (v as num).toDouble();

/// Lee un double opcional de JSON (null = desconocido).
double? readOptionalDouble(Map<String, Object?> j, String key) => _toDouble(j[key]);
