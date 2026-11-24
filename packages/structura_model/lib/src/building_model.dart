/// BuildingModel: contenedor versionado + validación.
library;

import 'elements.dart';
import 'primitives.dart';

const int buildingModelSchemaVersion = 1;

/// Imagen del plano sobre la que se expresan todas las coordenadas.
class PlanReference {
  final int widthPx;
  final int heightPx;
  final String? imageSha256;

  /// DPI de render (PDF) o de cabecera; null si se desconoce.
  final double? dpi;
  const PlanReference({required this.widthPx, required this.heightPx, this.imageSha256, this.dpi});
  Map<String, Object?> toJson() => {'width_px': widthPx, 'height_px': heightPx, 'image_sha256': imageSha256, 'dpi': dpi};
  factory PlanReference.fromJson(Map<String, Object?> j) => PlanReference(
        widthPx: j['width_px'] as int,
        heightPx: j['height_px'] as int,
        imageSha256: j['image_sha256'] as String?,
        dpi: readOptionalDouble(j, 'dpi'),
      );
}

class Level {
  final String id;
  final String? name;

  /// Cota del nivel en metros; null = desconocida.
  final double? elevationM;
  final List<BuildingElement> elements;
  const Level({required this.id, this.name, this.elevationM, this.elements = const []});

  Iterable<T> ofType<T extends BuildingElement>() => elements.whereType<T>();

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'elevation_m': elevationM,
        'elements': elements.map((e) => e.toJson()).toList(),
      };
  factory Level.fromJson(Map<String, Object?> j) => Level(
        id: j['id'] as String,
        name: j['name'] as String?,
        elevationM: readOptionalDouble(j, 'elevation_m'),
        elements: (j['elements'] as List).map((e) => BuildingElement.fromJson((e as Map).cast<String, Object?>())).toList(),
      );

  Level copyWith({List<BuildingElement>? elements}) =>
      Level(id: id, name: name, elevationM: elevationM, elements: elements ?? this.elements);
}

class BuildingModel {
  final int schemaVersion;
  final String id;
  final PlanReference plan;

  /// Escala del plano; null = desconocida (no hay medidas reales).
  final PlanScale? scale;
  final List<Level> levels;
  final List<Relation> relations;
  final List<DimensionAnnotation> dimensions;
  final Source source;

  const BuildingModel({
    this.schemaVersion = buildingModelSchemaVersion,
    required this.id,
    required this.plan,
    this.scale,
    required this.levels,
    this.relations = const [],
    this.dimensions = const [],
    required this.source,
  });

  Iterable<BuildingElement> get allElements => levels.expand((l) => l.elements);

  BuildingElement? elementById(String id) {
    for (final e in allElements) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// true si se pueden expresar medidas reales.
  bool get hasVerifiedScale => scale?.verified == true;

  Map<String, Object?> toJson() => {
        'schema_version': schemaVersion,
        'id': id,
        'plan': plan.toJson(),
        'scale': scale?.toJson(),
        'levels': levels.map((l) => l.toJson()).toList(),
        'relations': relations.map((r) => r.toJson()).toList(),
        'dimensions': dimensions.map((d) => d.toJson()).toList(),
        'source': source.toJson(),
      };

  factory BuildingModel.fromJson(Map<String, Object?> j) {
    final migrated = migrateBuildingModelJson(j);
    return BuildingModel(
      schemaVersion: migrated['schema_version'] as int,
      id: migrated['id'] as String,
      plan: PlanReference.fromJson((migrated['plan'] as Map).cast<String, Object?>()),
      scale: migrated['scale'] == null ? null : PlanScale.fromJson((migrated['scale'] as Map).cast<String, Object?>()),
      levels: (migrated['levels'] as List).map((e) => Level.fromJson((e as Map).cast<String, Object?>())).toList(),
      relations: ((migrated['relations'] as List?) ?? const [])
          .map((e) => Relation.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
      dimensions: ((migrated['dimensions'] as List?) ?? const [])
          .map((e) => DimensionAnnotation.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
      source: Source.fromJson((migrated['source'] as Map).cast<String, Object?>()),
    );
  }

  BuildingModel copyWith({List<Level>? levels, PlanScale? scale, List<Relation>? relations}) => BuildingModel(
        schemaVersion: schemaVersion,
        id: id,
        plan: plan,
        scale: scale ?? this.scale,
        levels: levels ?? this.levels,
        relations: relations ?? this.relations,
        dimensions: dimensions,
        source: source,
      );

  /// Valida coherencia interna. Una lista vacía significa modelo válido.
  List<ModelIssue> validate() {
    final issues = <ModelIssue>[];
    final ids = <String>{};
    for (final e in allElements) {
      if (!ids.add(e.id)) issues.add(ModelIssue.error(e.id, 'id duplicado'));
      final c = e.confidence;
      if (c != null && (c.isNaN || c < 0 || c > 1)) {
        issues.add(ModelIssue.error(e.id, 'confianza fuera de [0,1]: $c'));
      }
      if (e.source.provenance == Provenance.aiDetected && c == null) {
        issues.add(ModelIssue.warning(e.id, 'detección de IA sin confianza'));
      }
      final b = e.bounds;
      if (!b.isValid) issues.add(ModelIssue.error(e.id, 'geometría inválida o vacía'));
      if (b.right < 0 || b.bottom < 0 || b.left > plan.widthPx || b.top > plan.heightPx) {
        issues.add(ModelIssue.warning(e.id, 'fuera de los límites del plano'));
      }
      if (e is Wall) {
        if (!(e.thicknessPx > 0)) issues.add(ModelIssue.error(e.id, 'espesor de muro no positivo'));
        if (e.lengthPx <= 0) issues.add(ModelIssue.error(e.id, 'muro de longitud nula'));
      }
      final realMeasures = switch (e) {
        Wall w => [w.heightM],
        Opening o => [o.heightM, o.sillHeightM],
        _ => const <double?>[],
      };
      for (final v in realMeasures) {
        if (v != null && !(v > 0 && v.isFinite)) issues.add(ModelIssue.error(e.id, 'medida real inválida: $v'));
        if (v != null && e.source.provenance == Provenance.aiDetected) {
          issues.add(ModelIssue.error(e.id, 'medida real atribuida a la IA de segmentación (no puede medirla)'));
        }
      }
      if (e is Room && e.polygon.length < 3) issues.add(ModelIssue.error(e.id, 'ambiente con menos de 3 vértices'));
    }
    for (final e in allElements.whereType<Opening>()) {
      final host = e.hostWallId;
      if (host != null && elementById(host) is! Wall) {
        issues.add(ModelIssue.error(e.id, 'muro anfitrión inexistente: $host'));
      }
    }
    for (final r in relations) {
      if (elementById(r.a) == null || elementById(r.b) == null) {
        issues.add(ModelIssue.error('${r.a}-${r.b}', 'relación con elemento inexistente'));
      }
    }
    final s = scale;
    if (s != null && !(s.pxPerUnit > 0 && s.pxPerUnit.isFinite)) {
      issues.add(ModelIssue.error('scale', 'px_per_unit inválido'));
    }
    if (s != null && s.verified && s.source.provenance == Provenance.aiDetected) {
      issues.add(ModelIssue.warning('scale', 'escala marcada verificada pero proviene de IA sin revisión'));
    }
    return issues;
  }
}

enum IssueSeverity { error, warning }

class ModelIssue {
  final IssueSeverity severity;
  final String elementId;
  final String message;
  const ModelIssue(this.severity, this.elementId, this.message);
  const ModelIssue.error(this.elementId, this.message) : severity = IssueSeverity.error;
  const ModelIssue.warning(this.elementId, this.message) : severity = IssueSeverity.warning;
  @override
  String toString() => '[${severity.name}] $elementId: $message';
}

/// Migraciones de esquema. Hoy solo existe la versión 1.
Map<String, Object?> migrateBuildingModelJson(Map<String, Object?> json) {
  final version = (json['schema_version'] as int?) ?? 0;
  if (version > buildingModelSchemaVersion) {
    throw FormatException('BuildingModel schema_version $version es más nuevo que el soportado '
        '($buildingModelSchemaVersion). Actualizá la aplicación.');
  }
  if (version < 1) {
    throw FormatException('BuildingModel sin schema_version válido');
  }
  return json;
}
