/// Vectorización determinista: máscara de segmentación → elementos del Building Model.
///
/// Muros: descomposición greedy en rectángulos máximos (en cada semilla se
/// prueba la extensión horizontal-primero y vertical-primero y se queda la de
/// mayor área). Cada rectángulo es un segmento de muro: eje a lo largo del lado
/// mayor y espesor = lado menor. Pensado para plantas ortogonales; los muros
/// oblicuos se aproximan con escalones (limitación documentada).
///
/// Puertas/ventanas/columnas/escaleras: componentes conexas (4-vecindad) con
/// su rectángulo envolvente. Las aberturas se asocian al muro que más contacto
/// tiene con su huella.
///
/// Ninguna medida real se genera aquí: todo queda en píxeles del plano.
library;

import 'dart:typed_data';

import 'package:structura_model/structura_model.dart';

import 'segmentation.dart';

class VectorizerConfig {
  /// Área mínima (px²) de una componente de puerta/ventana/columna/escalera.
  final int minComponentArea;

  /// Espesor mínimo (px) para aceptar un rectángulo de muro.
  final int minWallThickness;

  /// Área mínima (px²) de un rectángulo de muro.
  final int minWallArea;

  /// Distancia (px) para considerar que una abertura toca un muro.
  final int hostTolerance;

  const VectorizerConfig(
      {this.minComponentArea = 16, this.minWallThickness = 2, this.minWallArea = 12, this.hostTolerance = 2});
}

/// Componente conexa de una clase.
class Component {
  final int classId;
  final int minX, minY, maxX, maxY; // inclusivos
  final int pixels;
  final double? meanConfidence;
  const Component(this.classId, this.minX, this.minY, this.maxX, this.maxY, this.pixels, this.meanConfidence);

  /// Rectángulo en coordenadas continuas (bordes de píxel: max + 1).
  Rect2 get rect => Rect2(minX.toDouble(), minY.toDouble(), maxX + 1.0, maxY + 1.0);
}

/// Rectángulo de muro en píxeles enteros [x, x+w) × [y, y+h).
class WallRect {
  final int x, y, w, h;
  final double? meanConfidence;
  const WallRect(this.x, this.y, this.w, this.h, this.meanConfidence);
  int get area => w * h;
  bool get horizontal => w >= h;
  Rect2 get rect => Rect2(x.toDouble(), y.toDouble(), (x + w).toDouble(), (y + h).toDouble());
}

class VectorizationResult {
  final List<BuildingElement> elements;
  final List<Relation> relations;
  final List<WallRect> wallRects;
  final List<Component> components;
  final List<String> warnings;
  const VectorizationResult(this.elements, this.relations, this.wallRects, this.components, this.warnings);
}

class Vectorizer {
  final VectorizerConfig config;
  const Vectorizer([this.config = const VectorizerConfig()]);

  VectorizationResult run(SegmentationResult seg, {required Source source}) {
    final warnings = <String>[];
    final rects = mergeFragments(decomposeWalls(seg));
    final comps = <Component>[];
    for (final c in [ClassId.door, ClassId.window, ClassId.column, ClassId.stairs]) {
      comps.addAll(connectedComponents(seg, c).where((k) => k.pixels >= config.minComponentArea));
    }
    final elements = <BuildingElement>[];
    final relations = <Relation>[];
    final walls = <Wall>[];
    for (var i = 0; i < rects.length; i++) {
      final r = rects[i];
      final Wall wall;
      if (r.horizontal) {
        final cy = r.y + r.h / 2;
        wall = Wall(
            id: 'w${(i + 1).toString().padLeft(4, '0')}',
            source: source,
            confidence: r.meanConfidence,
            start: Point2(r.x.toDouble(), cy),
            end: Point2((r.x + r.w).toDouble(), cy),
            thicknessPx: r.h.toDouble());
      } else {
        final cx = r.x + r.w / 2;
        wall = Wall(
            id: 'w${(i + 1).toString().padLeft(4, '0')}',
            source: source,
            confidence: r.meanConfidence,
            start: Point2(cx, r.y.toDouble()),
            end: Point2(cx, (r.y + r.h).toDouble()),
            thicknessPx: r.w.toDouble());
      }
      walls.add(wall);
      elements.add(wall);
    }
    var nd = 0, nw = 0, nc = 0, ns = 0;
    for (final c in comps) {
      switch (c.classId) {
        case ClassId.door:
        case ClassId.window:
          final isDoor = c.classId == ClassId.door;
          final id = isDoor ? 'd${(++nd).toString().padLeft(4, '0')}' : 'n${(++nw).toString().padLeft(4, '0')}';
          final host = _hostWall(c.rect, rects, walls);
          if (host == null) warnings.add('$id sin muro anfitrión detectado');
          elements.add(Opening(
              id: id,
              source: source,
              confidence: c.meanConfidence,
              type: isDoor ? OpeningType.door : OpeningType.window,
              footprint: c.rect,
              hostWallId: host?.id));
          if (host != null) {
            relations.add(Relation(RelationType.hosts, host.id, id, const Source(Provenance.derived)));
          }
        case ClassId.column:
          final r = c.rect;
          final aspect = r.width > r.height ? r.width / r.height : r.height / r.width;
          final fill = c.pixels / (r.width * r.height);
          elements.add(ColumnElement(
              id: 'c${(++nc).toString().padLeft(4, '0')}',
              source: source,
              confidence: c.meanConfidence,
              footprint: r,
              // Un disco llena ~78,5 % de su caja; un cuadrado ~100 %.
              round: aspect < 1.2 && fill < 0.85 && fill > 0.65));
        case ClassId.stairs:
          elements.add(Stairs(
              id: 's${(++ns).toString().padLeft(4, '0')}',
              source: source,
              confidence: c.meanConfidence,
              footprint: c.rect));
      }
    }
    return VectorizationResult(elements, relations, rects, comps, warnings);
  }

  Wall? _hostWall(Rect2 opening, List<WallRect> rects, List<Wall> walls) {
    final t = config.hostTolerance.toDouble();
    Wall? best;
    var bestContact = 0.0;
    for (var i = 0; i < rects.length; i++) {
      final r = rects[i].rect;
      // Contacto = longitud de la arista compartida (o solape) entre la huella y el rectángulo del muro.
      final ox = _overlap(opening.left - t, opening.right + t, r.left, r.right);
      final oy = _overlap(opening.top - t, opening.bottom + t, r.top, r.bottom);
      if (ox <= 0 || oy <= 0) continue;
      final contact = ox > oy ? ox : oy;
      if (contact > bestContact) {
        bestContact = contact;
        best = walls[i];
      }
    }
    return best;
  }

  static double _overlap(double a0, double a1, double b0, double b1) {
    final lo = a0 > b0 ? a0 : b0, hi = a1 < b1 ? a1 : b1;
    return hi - lo;
  }

  /// Fusiona tramos colineales contiguos (misma franja de espesor) y descarta
  /// fragmentos chicos pegados a un muro mayor (los "escalones" que deja una foto o
  /// un plano levemente inclinado). Reduce decenas de rectángulos a los muros reales.
  static List<WallRect> mergeFragments(List<WallRect> input) {
    if (input.length < 2) return input;
    final ts = input.map((r) => r.w < r.h ? r.w : r.h).toList()..sort();
    final t = ts[ts.length ~/ 2].toDouble();
    final tol = (0.35 * t).clamp(2.0, 12.0);
    var rects = [...input];
    var changed = true;
    while (changed) {
      changed = false;
      outer:
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          final a = rects[i], b = rects[j];
          WallRect? m;
          if (a.horizontal && b.horizontal && a.w > 1.5 * t && b.w > 1.5 * t) {
            final touch = b.x <= a.x + a.w + 1 && a.x <= b.x + b.w + 1;
            if (touch && (a.y - b.y).abs() <= tol && ((a.y + a.h) - (b.y + b.h)).abs() <= tol) {
              final x0 = a.x < b.x ? a.x : b.x, x1 = (a.x + a.w) > (b.x + b.w) ? a.x + a.w : b.x + b.w;
              final y0 = a.y < b.y ? a.y : b.y, y1 = (a.y + a.h) > (b.y + b.h) ? a.y + a.h : b.y + b.h;
              m = WallRect(x0, y0, x1 - x0, y1 - y0, _avgConf(a, b));
            }
          } else if (!a.horizontal && !b.horizontal && a.h > 1.5 * t && b.h > 1.5 * t) {
            final touch = b.y <= a.y + a.h + 1 && a.y <= b.y + b.h + 1;
            if (touch && (a.x - b.x).abs() <= tol && ((a.x + a.w) - (b.x + b.w)).abs() <= tol) {
              final x0 = a.x < b.x ? a.x : b.x, x1 = (a.x + a.w) > (b.x + b.w) ? a.x + a.w : b.x + b.w;
              final y0 = a.y < b.y ? a.y : b.y, y1 = (a.y + a.h) > (b.y + b.h) ? a.y + a.h : b.y + b.h;
              m = WallRect(x0, y0, x1 - x0, y1 - y0, _avgConf(a, b));
            }
          }
          if (m != null) {
            rects[i] = m;
            rects.removeAt(j);
            changed = true;
            break outer;
          }
        }
      }
    }
    // Fragmentos chicos (ambos lados ≤ 1,6 t) que tocan un muro mayor: se descartan.
    bool touches(WallRect a, WallRect b) =>
        a.x <= b.x + b.w + 1 && b.x <= a.x + a.w + 1 && a.y <= b.y + b.h + 1 && b.y <= a.y + a.h + 1;
    return [
      for (final r in rects)
        if (!(r.w <= 1.6 * t && r.h <= 1.6 * t && rects.any((o) => !identical(o, r) && (o.w > 1.6 * t || o.h > 1.6 * t) && touches(r, o)))) r
    ];
  }

  static double? _avgConf(WallRect a, WallRect b) {
    if (a.meanConfidence == null || b.meanConfidence == null) return null;
    return (a.meanConfidence! * a.area + b.meanConfidence! * b.area) / (a.area + b.area);
  }

  /// Descomposición greedy de la clase muro en rectángulos.
  List<WallRect> decomposeWalls(SegmentationResult seg) {
    final w = seg.width, h = seg.height, labels = seg.labels;
    final used = Uint8List(w * h);
    bool free(int x, int y) {
      final i = y * w + x;
      return labels[i] == ClassId.wall && used[i] == 0;
    }

    final out = <WallRect>[];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (!free(x, y)) continue;
        // Horizontal primero
        var hw = 0;
        while (x + hw < w && free(x + hw, y)) {
          hw++;
        }
        var hh = 1;
        while (y + hh < h && _rowFree(free, x, y + hh, hw)) {
          hh++;
        }
        // Vertical primero
        var vh = 0;
        while (y + vh < h && free(x, y + vh)) {
          vh++;
        }
        var vw = 1;
        while (x + vw < w && _colFree(free, x + vw, y, vh)) {
          vw++;
        }
        final (rw, rh) = hw * hh >= vw * vh ? (hw, hh) : (vw, vh);
        double sum = 0;
        final conf = seg.confidence;
        for (var yy = y; yy < y + rh; yy++) {
          final base = yy * w;
          for (var xx = x; xx < x + rw; xx++) {
            used[base + xx] = 1;
            if (conf != null) sum += conf[base + xx];
          }
        }
        final thickness = rw < rh ? rw : rh;
        if (thickness >= config.minWallThickness && rw * rh >= config.minWallArea) {
          out.add(WallRect(x, y, rw, rh, conf == null ? null : sum / (rw * rh)));
        }
      }
    }
    return out;
  }

  static bool _rowFree(bool Function(int, int) free, int x, int y, int len) {
    for (var i = 0; i < len; i++) {
      if (!free(x + i, y)) return false;
    }
    return true;
  }

  static bool _colFree(bool Function(int, int) free, int x, int y, int len) {
    for (var i = 0; i < len; i++) {
      if (!free(x, y + i)) return false;
    }
    return true;
  }

  /// Componentes conexas (4-vecindad) de una clase; orden determinista de barrido.
  static List<Component> connectedComponents(SegmentationResult seg, int classId) {
    final w = seg.width, h = seg.height, labels = seg.labels, conf = seg.confidence;
    final seen = Uint8List(w * h);
    final out = <Component>[];
    final stack = <int>[];
    for (var start = 0; start < w * h; start++) {
      if (labels[start] != classId || seen[start] != 0) continue;
      var minX = w, minY = h, maxX = -1, maxY = -1, n = 0;
      double sum = 0;
      stack.add(start);
      seen[start] = 1;
      while (stack.isNotEmpty) {
        final i = stack.removeLast();
        final x = i % w, y = i ~/ w;
        n++;
        if (conf != null) sum += conf[i];
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        if (x > 0 && labels[i - 1] == classId && seen[i - 1] == 0) {
          seen[i - 1] = 1;
          stack.add(i - 1);
        }
        if (x < w - 1 && labels[i + 1] == classId && seen[i + 1] == 0) {
          seen[i + 1] = 1;
          stack.add(i + 1);
        }
        if (y > 0 && labels[i - w] == classId && seen[i - w] == 0) {
          seen[i - w] = 1;
          stack.add(i - w);
        }
        if (y < h - 1 && labels[i + w] == classId && seen[i + w] == 0) {
          seen[i + w] = 1;
          stack.add(i + w);
        }
      }
      out.add(Component(classId, minX, minY, maxX, maxY, n, conf == null ? null : sum / n));
    }
    return out;
  }
}
