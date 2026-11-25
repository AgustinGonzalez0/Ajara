/// Exportación del plano detectado a DXF (AutoCAD R12, ASCII): lo abre cualquier CAD
/// (AutoCAD, BricsCAD, LibreCAD, DraftSight, QCAD) sin conversiones.
///
/// Con escala verificada el dibujo queda **en metros**; sin escala, en píxeles del plano
/// (y lo avisa el rótulo). La Y se invierte: en el plano crece hacia abajo, en CAD hacia
/// arriba. Capas:
///
/// | Capa | Contenido |
/// |---|---|
/// | MUROS | contorno de cada muro |
/// | MUROS-RELLENO | relleno sólido de los muros (se puede apagar) |
/// | PUERTAS | hoja y arco de giro |
/// | VENTANAS | vano con línea central |
/// | COLUMNAS | contorno con cruz |
/// | ESCALERAS | contorno y pedadas |
/// | AMBIENTES | número y superficie de cada ambiente |
/// | ROTULO | origen y unidades |
library;

import 'dart:math' as math;

import 'package:structura_model/structura_model.dart';

import 'mesh.dart';

class DxfExport {
  final String content;
  final bool inMeters;
  final int entities;
  const DxfExport(this.content, {required this.inMeters, required this.entities});
}

class _Dxf {
  final StringBuffer b = StringBuffer();
  int entities = 0;
  double minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;

  void g(int code, Object value) {
    b
      ..write(code)
      ..write('\r\n')
      ..write(value is double ? _num(value) : '$value')
      ..write('\r\n');
  }

  static String _num(double v) {
    final s = v.toStringAsFixed(6);
    return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '.0') : s;
  }

  void _ext(double x, double y) {
    minX = math.min(minX, x);
    minY = math.min(minY, y);
    maxX = math.max(maxX, x);
    maxY = math.max(maxY, y);
  }

  void polyline(String layer, List<(double, double)> pts, {bool closed = true}) {
    entities++;
    g(0, 'POLYLINE');
    g(8, layer);
    g(66, 1);
    g(10, 0.0);
    g(20, 0.0);
    g(30, 0.0);
    g(70, closed ? 1 : 0);
    for (final (x, y) in pts) {
      _ext(x, y);
      g(0, 'VERTEX');
      g(8, layer);
      g(10, x);
      g(20, y);
      g(30, 0.0);
    }
    g(0, 'SEQEND');
    g(8, layer);
  }

  void line(String layer, double x1, double y1, double x2, double y2) {
    entities++;
    _ext(x1, y1);
    _ext(x2, y2);
    g(0, 'LINE');
    g(8, layer);
    g(10, x1);
    g(20, y1);
    g(30, 0.0);
    g(11, x2);
    g(21, y2);
    g(31, 0.0);
  }

  /// Cuadrilátero relleno. DXF ordena los vértices del SOLID en "Z": 1, 2, 4, 3.
  void solid(String layer, List<(double, double)> q) {
    entities++;
    g(0, 'SOLID');
    g(8, layer);
    for (final (i, k) in [(0, 0), (1, 1), (2, 3), (3, 2)]) {
      g(10 + i, q[k].$1);
      g(20 + i, q[k].$2);
      g(30 + i, 0.0);
    }
  }

  void arc(String layer, double cx, double cy, double r, double startDeg, double endDeg) {
    entities++;
    _ext(cx - r, cy - r);
    _ext(cx + r, cy + r);
    g(0, 'ARC');
    g(8, layer);
    g(10, cx);
    g(20, cy);
    g(30, 0.0);
    g(40, r);
    g(50, startDeg);
    g(51, endDeg);
  }

  void text(String layer, double x, double y, double h, String s, {bool center = false}) {
    entities++;
    g(0, 'TEXT');
    g(8, layer);
    g(10, x);
    g(20, y);
    g(30, 0.0);
    g(40, h);
    g(1, _ascii(s));
    if (center) {
      g(72, 1);
      g(73, 2);
      g(11, x);
      g(21, y);
      g(31, 0.0);
    }
  }

  /// R12 usa la página de códigos del sistema: solo ASCII para que se lea igual en todos.
  static String _ascii(String s) {
    const map = {'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ñ': 'n', 'Á': 'A', 'É': 'E', 'Í': 'I', 'Ó': 'O',
      'Ú': 'U', 'Ñ': 'N', '²': '2', '³': '3', '·': '-', '—': '-', '–': '-'};
    final out = StringBuffer();
    for (final r in s.runes) {
      final c = String.fromCharCode(r);
      out.write(map[c] ?? (r >= 32 && r < 127 ? c : '?'));
    }
    return out.toString();
  }
}

const _layers = [
  ('MUROS', 7),
  ('MUROS-RELLENO', 8),
  ('PUERTAS', 3),
  ('VENTANAS', 5),
  ('COLUMNAS', 1),
  ('ESCALERAS', 4),
  ('AMBIENTES', 2),
  ('ROTULO', 7),
];

/// Genera el DXF del plano detectado. [title] va en el rótulo (se pasa a ASCII).
DxfExport buildDxf(BuildingModel model, {String title = 'STRUCTURA AI'}) {
  final scale = model.scale;
  final meters = scale != null && scale.verified;
  final k = meters ? scale.unit.meters / scale.pxPerUnit : 1.0; // px → unidades del dibujo
  final h = model.plan.heightPx.toDouble();
  double X(double x) => x * k;
  double Y(double y) => (h - y) * k; // Y hacia arriba
  (double, double) P(double x, double y) => (X(x), Y(y));

  final e = _Dxf();
  final walls = model.allElements.whereType<Wall>().where((w) => w.lengthPx > 0).toList();
  final tMed = walls.isEmpty ? 10.0 : (walls.map((w) => w.thicknessPx).toList()..sort())[walls.length ~/ 2];

  for (final w in walls) {
    final dx = w.end.x - w.start.x, dy = w.end.y - w.start.y;
    final len = math.sqrt(dx * dx + dy * dy);
    final nx = -dy / len * w.thicknessPx / 2, ny = dx / len * w.thicknessPx / 2;
    final q = [
      P(w.start.x + nx, w.start.y + ny),
      P(w.end.x + nx, w.end.y + ny),
      P(w.end.x - nx, w.end.y - ny),
      P(w.start.x - nx, w.start.y - ny),
    ];
    e.solid('MUROS-RELLENO', q);
    e.polyline('MUROS', q);
  }

  for (final o in model.allElements.whereType<Opening>()) {
    final r = o.footprint;
    final horizontal = r.width >= r.height;
    if (o.type == OpeningType.window) {
      e.polyline('VENTANAS', [P(r.left, r.top), P(r.right, r.top), P(r.right, r.bottom), P(r.left, r.bottom)]);
      if (horizontal) {
        e.line('VENTANAS', X(r.left), Y(r.center.y), X(r.right), Y(r.center.y));
      } else {
        e.line('VENTANAS', X(r.center.x), Y(r.top), X(r.center.x), Y(r.bottom));
      }
      continue;
    }
    // Puerta: bisagra en un extremo del vano, hoja perpendicular y arco de 90°.
    final width = (horizontal ? r.width : r.height) * k;
    if (horizontal) {
      final (hx, hy) = P(r.left, r.center.y);
      e.line('PUERTAS', hx, hy, hx, hy - width);
      e.arc('PUERTAS', hx, hy, width, 270, 360);
      e.line('PUERTAS', X(r.left), Y(r.top), X(r.left), Y(r.bottom));
      e.line('PUERTAS', X(r.right), Y(r.top), X(r.right), Y(r.bottom));
    } else {
      final (hx, hy) = P(r.center.x, r.top);
      e.line('PUERTAS', hx, hy, hx + width, hy);
      e.arc('PUERTAS', hx, hy, width, 270, 360);
      e.line('PUERTAS', X(r.left), Y(r.top), X(r.right), Y(r.top));
      e.line('PUERTAS', X(r.left), Y(r.bottom), X(r.right), Y(r.bottom));
    }
  }

  for (final c in model.allElements.whereType<ColumnElement>()) {
    final r = c.footprint;
    e.polyline('COLUMNAS', [P(r.left, r.top), P(r.right, r.top), P(r.right, r.bottom), P(r.left, r.bottom)]);
    e.line('COLUMNAS', X(r.left), Y(r.top), X(r.right), Y(r.bottom));
    e.line('COLUMNAS', X(r.left), Y(r.bottom), X(r.right), Y(r.top));
  }

  for (final s in model.allElements.whereType<Stairs>()) {
    final r = s.footprint;
    e.polyline('ESCALERAS', [P(r.left, r.top), P(r.right, r.top), P(r.right, r.bottom), P(r.left, r.bottom)]);
    final along = r.width >= r.height ? r.width : r.height;
    final tread = meters ? 0.28 / k : along / 10; // pedada típica de 28 cm
    final n = math.max(2, math.min(40, (along / tread).round()));
    for (var i = 1; i < n; i++) {
      final f = i / n;
      if (r.width >= r.height) {
        final x = r.left + r.width * f;
        e.line('ESCALERAS', X(x), Y(r.top), X(x), Y(r.bottom));
      } else {
        final y = r.top + r.height * f;
        e.line('ESCALERAS', X(r.left), Y(y), X(r.right), Y(y));
      }
    }
  }

  final textH = math.max(tMed * k * 1.2, meters ? 0.12 : 8.0);
  for (final room in analyzeFloor(model).rooms) {
    final (x, y) = P(room.label.x, room.label.y);
    e.text('AMBIENTES', x, y + textH * 0.6, textH, 'A${room.number}', center: true);
    if (meters) {
      final a = room.areaM2(scale.pxPerUnit / scale.unit.meters);
      e.text('AMBIENTES', x, y - textH * 0.8, textH * 0.8, '${a.toStringAsFixed(2).replaceAll('.', ',')} m2', center: true);
    }
  }

  if (e.minX.isFinite) {
    final y0 = e.minY - textH * 3;
    e.text('ROTULO', e.minX, y0, textH, title);
    e.text('ROTULO', e.minX, y0 - textH * 1.6, textH * 0.7,
        meters ? 'Plano detectado - unidades: metros (escala verificada)' : 'Plano detectado - unidades: pixeles del plano (sin escala)');
    e.text('ROTULO', e.minX, y0 - textH * 2.9, textH * 0.7, 'Revisar antes de usar: deteccion automatica desde imagen');
  }

  final out = _Dxf();
  out.g(0, 'SECTION');
  out.g(2, 'HEADER');
  out.g(9, r'$ACADVER');
  out.g(1, 'AC1009');
  out.g(9, r'$INSBASE');
  out.g(10, 0.0);
  out.g(20, 0.0);
  out.g(30, 0.0);
  out.g(9, r'$EXTMIN');
  out.g(10, e.minX.isFinite ? e.minX : 0.0);
  out.g(20, e.minY.isFinite ? e.minY - textH * 4 : 0.0);
  out.g(30, 0.0);
  out.g(9, r'$EXTMAX');
  out.g(10, e.maxX.isFinite ? e.maxX : 1.0);
  out.g(20, e.maxY.isFinite ? e.maxY : 1.0);
  out.g(30, 0.0);
  out.g(0, 'ENDSEC');
  out.g(0, 'SECTION');
  out.g(2, 'TABLES');
  out.g(0, 'TABLE');
  out.g(2, 'LTYPE');
  out.g(70, 1);
  out.g(0, 'LTYPE');
  out.g(2, 'CONTINUOUS');
  out.g(70, 0);
  out.g(3, 'Solid line');
  out.g(72, 65);
  out.g(73, 0);
  out.g(40, 0.0);
  out.g(0, 'ENDTAB');
  out.g(0, 'TABLE');
  out.g(2, 'LAYER');
  out.g(70, _layers.length);
  for (final (name, color) in _layers) {
    out.g(0, 'LAYER');
    out.g(2, name);
    out.g(70, 0);
    out.g(62, color);
    out.g(6, 'CONTINUOUS');
  }
  out.g(0, 'ENDTAB');
  out.g(0, 'ENDSEC');
  out.g(0, 'SECTION');
  out.g(2, 'ENTITIES');
  out.b.write(e.b);
  out.g(0, 'ENDSEC');
  out.g(0, 'EOF');
  return DxfExport(out.b.toString(), inMeters: meters, entities: e.entities);
}
