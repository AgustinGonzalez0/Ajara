/// Cómputo métrico preliminar a partir del Building Model con escala verificada.
///
/// Lo que un maestro mayor de obra arma a mano al empezar un presupuesto: superficies
/// (cubierta y por ambiente), metros de muro por espesor, superficie neta de mampostería
/// descontando aberturas, volumen, revoques, aberturas por medida y densidad de muros.
///
/// Es una **estimación desde el plano detectado**: largos por eje de muro (los encuentros
/// se cuentan una vez en cada muro), alturas declaradas por el usuario y superficies de
/// ambiente aproximadas a una grilla de medio espesor de muro. Sirve para pre-dimensionar;
/// no reemplaza el cómputo sobre el proyecto definitivo.
library;

import 'dart:math' as math;

import 'package:structura_model/structura_model.dart';

import 'mesh.dart';

/// Alturas declaradas (no salen del plano).
class TakeoffParams {
  final double wallHeightM;
  final double doorHeightM;
  final double windowHeightM;
  const TakeoffParams({this.wallHeightM = 2.60, this.doorHeightM = 2.05, this.windowHeightM = 1.10});

  Map<String, Object?> toJson() =>
      {'wall_height_m': wallHeightM, 'door_height_m': doorHeightM, 'window_height_m': windowHeightM};
}

/// Muros de un mismo espesor (redondeado a 5 cm, como se especifican en obra).
class WallGroup {
  final double thicknessM;
  final int count;
  final double lengthM;
  final double grossAreaM2;
  final double openingsAreaM2;
  const WallGroup(this.thicknessM, this.count, this.lengthM, this.grossAreaM2, this.openingsAreaM2);
  double get netAreaM2 => math.max(0, grossAreaM2 - openingsAreaM2);
  double get volumeM3 => netAreaM2 * thicknessM;

  Map<String, Object?> toJson() => {
        'thickness_m': thicknessM,
        'count': count,
        'length_m': lengthM,
        'gross_area_m2': grossAreaM2,
        'openings_area_m2': openingsAreaM2,
        'net_area_m2': netAreaM2,
        'volume_m3': volumeM3,
      };
}

/// Aberturas del mismo tipo y ancho (redondeado a 5 cm).
class OpeningGroup {
  final OpeningType type;
  final double widthM;
  final int count;
  const OpeningGroup(this.type, this.widthM, this.count);
  Map<String, Object?> toJson() => {'type': type.name, 'width_m': widthM, 'count': count};
}

class RoomArea {
  final int number;
  final double areaM2;
  final Point2 labelPx;
  const RoomArea(this.number, this.areaM2, this.labelPx);
  String get name => 'A$number';
  Map<String, Object?> toJson() => {'name': name, 'area_m2': areaM2, 'label_px': labelPx.toJson()};
}

class QuantityTakeoff {
  final double pxPerM;
  final TakeoffParams params;

  /// Superficie cubierta: interior más muros (si el contorno no cierra, rectángulo envolvente).
  final double coveredAreaM2;
  final bool contourClosed;
  final List<RoomArea> rooms;
  final List<WallGroup> walls;
  final List<OpeningGroup> openings;
  final int columns;
  final int stairs;

  /// Σ(largo × espesor) de muros en cada dirección / superficie cubierta, en %.
  final double wallDensityXPct;
  final double wallDensityYPct;

  const QuantityTakeoff({
    required this.pxPerM,
    required this.params,
    required this.coveredAreaM2,
    required this.contourClosed,
    required this.rooms,
    required this.walls,
    required this.openings,
    required this.columns,
    required this.stairs,
    required this.wallDensityXPct,
    required this.wallDensityYPct,
  });

  double get usefulAreaM2 => rooms.fold(0, (s, r) => s + r.areaM2);
  double get wallLengthM => walls.fold(0, (s, w) => s + w.lengthM);
  double get netWallAreaM2 => walls.fold(0, (s, w) => s + w.netAreaM2);
  double get wallVolumeM3 => walls.fold(0, (s, w) => s + w.volumeM3);

  /// Revoque: las dos caras de la mampostería neta.
  double get plasterAreaM2 => 2 * netWallAreaM2;
  int count(OpeningType t) => openings.where((o) => o.type == t).fold(0, (s, o) => s + o.count);

  List<String> get notes => [
        'Largos por eje de muro; cada encuentro se cuenta en ambos muros (criterio conservador).',
        'Alturas declaradas: muros ${_es(params.wallHeightM)} m, puertas ${_es(params.doorHeightM)} m, '
            'ventanas ${_es(params.windowHeightM)} m.',
        if (!contourClosed)
          'El contorno no cierra: superficie cubierta estimada con el rectángulo envolvente y sin ambientes.',
        'Superficies de ambientes aproximadas a la cara de los muros (grilla de medio espesor).',
        'Estimación desde el plano detectado: no reemplaza el cómputo sobre el proyecto definitivo.',
      ];

  Map<String, Object?> toJson() => {
        'format': 'structura.takeoff/1',
        'px_per_m': pxPerM,
        'params': params.toJson(),
        'covered_area_m2': coveredAreaM2,
        'useful_area_m2': usefulAreaM2,
        'contour_closed': contourClosed,
        'rooms': [for (final r in rooms) r.toJson()],
        'walls': [for (final w in walls) w.toJson()],
        'openings': [for (final o in openings) o.toJson()],
        'columns': columns,
        'stairs': stairs,
        'wall_density_x_pct': wallDensityXPct,
        'wall_density_y_pct': wallDensityYPct,
        'plaster_area_m2': plasterAreaM2,
        'notes': notes,
      };

  /// Planilla para Excel/LibreOffice en español: `;` como separador y coma decimal.
  String toCsv({String project = ''}) {
    final b = StringBuffer('﻿'); // BOM: Excel reconoce UTF-8 (acentos)
    void row(List<Object> cells) => b.writeln(cells.map((c) => '$c'.contains(';') ? '"$c"' : '$c').join(';'));
    row(['Cómputo métrico preliminar', project]);
    row(['Sección', 'Concepto', 'Cantidad', 'Unidad']);
    row(['Superficies', 'Superficie cubierta', _es(coveredAreaM2), 'm²']);
    if (rooms.isNotEmpty) row(['Superficies', 'Superficie útil (suma de ambientes)', _es(usefulAreaM2), 'm²']);
    for (final r in rooms) {
      row(['Ambientes', r.name, _es(r.areaM2), 'm²']);
    }
    for (final w in walls) {
      final t = 'Muro ${_es(w.thicknessM * 100, 0)} cm';
      row(['Mampostería', '$t: largo', _es(w.lengthM), 'm']);
      row(['Mampostería', '$t: superficie neta', _es(w.netAreaM2), 'm²']);
      row(['Mampostería', '$t: volumen', _es(w.volumeM3), 'm³']);
    }
    row(['Mampostería', 'Total superficie neta', _es(netWallAreaM2), 'm²']);
    row(['Mampostería', 'Total volumen', _es(wallVolumeM3), 'm³']);
    row(['Revoques', 'Revoque (2 caras)', _es(plasterAreaM2), 'm²']);
    if (rooms.isNotEmpty) row(['Pisos', 'Contrapiso y piso (superficie útil)', _es(usefulAreaM2), 'm²']);
    for (final o in openings) {
      row(['Aberturas', '${o.type == OpeningType.door ? 'Puerta' : 'Ventana'} ${_es(o.widthM)} m', o.count, 'u']);
    }
    if (columns > 0) row(['Estructura', 'Columnas', columns, 'u']);
    if (stairs > 0) row(['Estructura', 'Escaleras', stairs, 'u']);
    row(['Indicadores', 'Densidad de muros dirección X', _es(wallDensityXPct), '%']);
    row(['Indicadores', 'Densidad de muros dirección Y', _es(wallDensityYPct), '%']);
    for (final n in notes) {
      row(['Notas', n, '', '']);
    }
    return b.toString();
  }
}

/// Número con coma decimal.
String _es(num v, [int decimals = 2]) => v.toStringAsFixed(decimals).replaceAll('.', ',');

double _round05(double m) => math.max(0.05, (m / 0.05).round() * 0.05);

/// Calcula el cómputo. Requiere escala verificada: sin ella las medidas no significan nada.
QuantityTakeoff computeTakeoff(BuildingModel model, {TakeoffParams params = const TakeoffParams()}) {
  final scale = model.scale;
  if (scale == null || !scale.verified) {
    throw ArgumentError('El cómputo necesita una escala verificada.');
  }
  final ppm = scale.pxPerUnit / scale.unit.meters;
  double m(double px) => px / ppm;

  final walls = model.allElements.whereType<Wall>().where((w) => w.lengthPx > 0).toList();
  final openings = model.allElements.whereType<Opening>().toList();
  final floor = analyzeFloor(model);

  // Muros por espesor.
  final byT = <double, List<Wall>>{};
  for (final w in walls) {
    byT.putIfAbsent(_round05(m(w.thicknessPx)), () => []).add(w);
  }
  // Grupos ínfimos (restos de la detección) se suman al espesor principal más cercano.
  double groupLen(List<Wall> ws) => ws.fold(0, (s, w) => s + m(w.lengthPx));
  final total = groupLen(walls);
  final minor = [for (final e in byT.entries) if (groupLen(e.value) < math.max(0.5, 0.03 * total)) e.key];
  if (minor.length < byT.length) {
    for (final t in minor) {
      final ws = byT.remove(t)!;
      final target = byT.keys.reduce((a, b) => (a - t).abs() <= (b - t).abs() ? a : b);
      byT[target]!.addAll(ws);
    }
  }
  final groupOf = {for (final e in byT.entries) for (final w in e.value) w.id: e.key};
  final mostCommon = byT.isEmpty
      ? null
      : byT.entries.reduce((a, b) => a.value.fold<double>(0, (s, w) => s + w.lengthPx) >=
              b.value.fold<double>(0, (s, w) => s + w.lengthPx)
          ? a
          : b).key;
  final openArea = <double, double>{};
  final openGroups = <(OpeningType, double), int>{};
  for (final o in openings) {
    final width = m(math.max(o.footprint.width, o.footprint.height));
    final h = o.heightM ?? (o.type == OpeningType.door ? params.doorHeightM : params.windowHeightM);
    final g = groupOf[o.hostWallId] ?? mostCommon;
    if (g != null) openArea[g] = (openArea[g] ?? 0) + width * h;
    final key = (o.type, _round05(width));
    openGroups[key] = (openGroups[key] ?? 0) + 1;
  }
  final wallGroups = [
    for (final e in byT.entries)
      () {
        final len = e.value.fold<double>(0, (s, w) => s + m(w.lengthPx));
        return WallGroup(e.key, e.value.length, len, len * params.wallHeightM, openArea[e.key] ?? 0);
      }(),
  ]..sort((a, b) => b.thicknessM.compareTo(a.thicknessM));
  final openingGroups = [for (final e in openGroups.entries) OpeningGroup(e.key.$1, e.key.$2, e.value)]
    ..sort((a, b) => a.type != b.type ? a.type.index - b.type.index : a.widthM.compareTo(b.widthM));

  final covered = floor.floor.fold<double>(0, (s, r) => s + r.width * r.height) / (ppm * ppm);
  var ax = 0.0, ay = 0.0;
  for (final w in walls) {
    final a = m(w.lengthPx) * m(w.thicknessPx);
    if ((w.end.x - w.start.x).abs() >= (w.end.y - w.start.y).abs()) {
      ax += a;
    } else {
      ay += a;
    }
  }
  return QuantityTakeoff(
    pxPerM: ppm,
    params: params,
    coveredAreaM2: covered,
    contourClosed: floor.closed,
    rooms: [for (final r in floor.rooms) RoomArea(r.number, r.areaM2(ppm), r.label)],
    walls: wallGroups,
    openings: openingGroups,
    columns: model.allElements.whereType<ColumnElement>().length,
    stairs: model.allElements.whereType<Stairs>().length,
    wallDensityXPct: covered > 0 ? 100 * ax / covered : 0,
    wallDensityYPct: covered > 0 ? 100 * ay / covered : 0,
  );
}
