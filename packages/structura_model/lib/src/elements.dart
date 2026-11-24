/// Elementos del edificio. Geometría en píxeles del plano; medidas reales
/// opcionales (null = desconocido) y nunca inferidas sin escala verificada.
library;

import 'primitives.dart';

enum ElementKind {
  wall,
  door,
  window,
  column,
  stairs,
  room;

  static ElementKind parse(String s) => ElementKind.values.byName(s);
}

/// Base común: identidad, procedencia y confianza.
abstract class BuildingElement {
  final String id;
  final Source source;

  /// Confianza 0..1 del detector (p. ej., probabilidad media del segmentador).
  /// null si no aplica (dato del usuario) o no se midió.
  final double? confidence;

  const BuildingElement({required this.id, required this.source, this.confidence});

  ElementKind get kind;

  /// Rectángulo envolvente en píxeles del plano.
  Rect2 get bounds;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'source': source.toJson(),
        'confidence': confidence,
        ...geometryJson(),
      };

  Map<String, Object?> geometryJson();

  static BuildingElement fromJson(Map<String, Object?> j) {
    final kind = ElementKind.parse(j['kind'] as String);
    final id = j['id'] as String;
    final source = Source.fromJson((j['source'] as Map).cast<String, Object?>());
    final confidence = readOptionalDouble(j, 'confidence');
    switch (kind) {
      case ElementKind.wall:
        return Wall(
          id: id,
          source: source,
          confidence: confidence,
          start: Point2.fromJson(j['start']),
          end: Point2.fromJson(j['end']),
          thicknessPx: (j['thickness_px'] as num).toDouble(),
          heightM: readOptionalDouble(j, 'height_m'),
        );
      case ElementKind.door:
      case ElementKind.window:
        return Opening(
          id: id,
          source: source,
          confidence: confidence,
          type: kind == ElementKind.door ? OpeningType.door : OpeningType.window,
          footprint: Rect2.fromJson(j['footprint']),
          hostWallId: j['host_wall_id'] as String?,
          heightM: readOptionalDouble(j, 'height_m'),
          sillHeightM: readOptionalDouble(j, 'sill_height_m'),
        );
      case ElementKind.column:
        return ColumnElement(
          id: id,
          source: source,
          confidence: confidence,
          footprint: Rect2.fromJson(j['footprint']),
          round: j['round'] == true,
        );
      case ElementKind.stairs:
        return Stairs(
            id: id, source: source, confidence: confidence, footprint: Rect2.fromJson(j['footprint']));
      case ElementKind.room:
        return Room(
          id: id,
          source: source,
          confidence: confidence,
          polygon: (j['polygon'] as List).map(Point2.fromJson).toList(),
          name: j['name'] as String?,
        );
    }
  }
}

/// Muro: segmento de eje (centerline) con espesor en píxeles.
class Wall extends BuildingElement {
  final Point2 start;
  final Point2 end;
  final double thicknessPx;

  /// Altura real en metros. null = desconocida (los planos 2D rara vez la indican).
  final double? heightM;

  const Wall({
    required super.id,
    required super.source,
    super.confidence,
    required this.start,
    required this.end,
    required this.thicknessPx,
    this.heightM,
  });

  @override
  ElementKind get kind => ElementKind.wall;

  double get lengthPx => start.distanceTo(end);

  @override
  Rect2 get bounds {
    final h = thicknessPx / 2;
    return Rect2(
      (start.x < end.x ? start.x : end.x) - h,
      (start.y < end.y ? start.y : end.y) - h,
      (start.x > end.x ? start.x : end.x) + h,
      (start.y > end.y ? start.y : end.y) + h,
    );
  }

  @override
  Map<String, Object?> geometryJson() =>
      {'start': start.toJson(), 'end': end.toJson(), 'thickness_px': thicknessPx, 'height_m': heightM};
}

enum OpeningType { door, window }

/// Puerta o ventana: huella rectangular sobre el plano y muro anfitrión (si se determinó).
class Opening extends BuildingElement {
  final OpeningType type;
  final Rect2 footprint;
  final String? hostWallId;
  final double? heightM;
  final double? sillHeightM;

  const Opening({
    required super.id,
    required super.source,
    super.confidence,
    required this.type,
    required this.footprint,
    this.hostWallId,
    this.heightM,
    this.sillHeightM,
  });

  @override
  ElementKind get kind => type == OpeningType.door ? ElementKind.door : ElementKind.window;

  @override
  Rect2 get bounds => footprint;

  @override
  Map<String, Object?> geometryJson() => {
        'footprint': footprint.toJson(),
        'host_wall_id': hostWallId,
        'height_m': heightM,
        'sill_height_m': sillHeightM,
      };
}

class ColumnElement extends BuildingElement {
  final Rect2 footprint;
  final bool round;
  const ColumnElement({required super.id, required super.source, super.confidence, required this.footprint, this.round = false});
  @override
  ElementKind get kind => ElementKind.column;
  @override
  Rect2 get bounds => footprint;
  @override
  Map<String, Object?> geometryJson() => {'footprint': footprint.toJson(), 'round': round};
}

class Stairs extends BuildingElement {
  final Rect2 footprint;
  const Stairs({required super.id, required super.source, super.confidence, required this.footprint});
  @override
  ElementKind get kind => ElementKind.stairs;
  @override
  Rect2 get bounds => footprint;
  @override
  Map<String, Object?> geometryJson() => {'footprint': footprint.toJson()};
}

/// Ambiente. Reservado para Spatial AI (todavía no implementado).
class Room extends BuildingElement {
  final List<Point2> polygon;
  final String? name;
  const Room({required super.id, required super.source, super.confidence, required this.polygon, this.name});
  @override
  ElementKind get kind => ElementKind.room;
  @override
  Rect2 get bounds {
    final xs = polygon.map((p) => p.x), ys = polygon.map((p) => p.y);
    return Rect2(xs.reduce((a, b) => a < b ? a : b), ys.reduce((a, b) => a < b ? a : b),
        xs.reduce((a, b) => a > b ? a : b), ys.reduce((a, b) => a > b ? a : b));
  }

  @override
  Map<String, Object?> geometryJson() => {'polygon': polygon.map((p) => p.toJson()).toList(), 'name': name};
}

/// Relación espacial explícita entre elementos.
enum RelationType { hosts, adjacent, connects }

class Relation {
  final RelationType type;
  final String a;
  final String b;
  final Source source;
  const Relation(this.type, this.a, this.b, this.source);
  Map<String, Object?> toJson() => {'type': type.name, 'a': a, 'b': b, 'source': source.toJson()};
  factory Relation.fromJson(Map<String, Object?> j) => Relation(RelationType.values.byName(j['type'] as String),
      j['a'] as String, j['b'] as String, Source.fromJson((j['source'] as Map).cast<String, Object?>()));
}

/// Cota leída del plano (Dimension AI, futura). El valor numérico solo se
/// guarda si fue interpretado; [verified] indica revisión humana.
class DimensionAnnotation {
  final String id;
  final Point2 from;
  final Point2 to;
  final String? rawText;
  final double? value;
  final LengthUnit? unit;
  final bool verified;
  final Source source;
  const DimensionAnnotation(
      {required this.id,
      required this.from,
      required this.to,
      this.rawText,
      this.value,
      this.unit,
      this.verified = false,
      required this.source});
  Map<String, Object?> toJson() => {
        'id': id,
        'from': from.toJson(),
        'to': to.toJson(),
        'raw_text': rawText,
        'value': value,
        'unit': unit?.name,
        'verified': verified,
        'source': source.toJson(),
      };
  factory DimensionAnnotation.fromJson(Map<String, Object?> j) => DimensionAnnotation(
        id: j['id'] as String,
        from: Point2.fromJson(j['from']),
        to: Point2.fromJson(j['to']),
        rawText: j['raw_text'] as String?,
        value: readOptionalDouble(j, 'value'),
        unit: LengthUnit.tryParse(j['unit'] as String?),
        verified: j['verified'] == true,
        source: Source.fromJson((j['source'] as Map).cast<String, Object?>()),
      );
}
