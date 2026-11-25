/// Afinado geométrico determinista del Building Model (modo "detallado").
///
/// La detección (clásica o IA) entrega muros como rectángulos sueltos: espesores que
/// varían un píxel, fachadas en escalón, esquinas abiertas, tramos cortados y aberturas
/// que no calzan con el muro. Este paso los regulariza para que el 3D quede cerrado y
/// limpio. Todo en píxeles del plano; no inventa medidas, solo ajusta lo detectado con
/// tolerancias proporcionales al espesor del muro.
///
/// Orden: espesores → alineación → aberturas (anfitrión y encaje) → unión de tramos →
/// esquinas y uniones en T → limpieza de fragmentos.
library;

import 'dart:math' as math;

import 'package:structura_model/structura_model.dart';

class RefineConfig {
  /// Tolerancia relativa para agrupar espesores (0,22 = ±22 %).
  final double thicknessTolerance;

  /// Muros paralelos a menos de este múltiplo del espesor se alinean en un mismo eje.
  final double alignFactor;

  /// Huecos (entre tramos o hasta un muro perpendicular) de hasta este múltiplo del
  /// espesor se cierran si no hay una abertura en el medio.
  final double gapFactor;

  const RefineConfig({this.thicknessTolerance = 0.22, this.alignFactor = 0.5, this.gapFactor = 1.6});
}

class RefineReport {
  int thicknessUnified = 0;
  int wallsAligned = 0;
  int segmentsJoined = 0;
  int junctionsClosed = 0;
  int openingsFitted = 0;
  int openingsHosted = 0;
  int fragmentsRemoved = 0;
  int slicesReoriented = 0;

  int get total =>
      thicknessUnified +
      wallsAligned +
      segmentsJoined +
      junctionsClosed +
      openingsFitted +
      openingsHosted +
      fragmentsRemoved +
      slicesReoriented;

  /// Frases para la UI ("6 esquinas cerradas", ...), solo las que ocurrieron.
  List<String> summary() => [
        if (junctionsClosed > 0) '$junctionsClosed ${junctionsClosed == 1 ? 'esquina cerrada' : 'esquinas y uniones cerradas'}',
        if (wallsAligned > 0) '$wallsAligned ${wallsAligned == 1 ? 'muro alineado' : 'muros alineados'}',
        if (segmentsJoined > 0) '$segmentsJoined ${segmentsJoined == 1 ? 'tramo unido' : 'tramos unidos'}',
        if (thicknessUnified > 0) '$thicknessUnified ${thicknessUnified == 1 ? 'espesor unificado' : 'espesores unificados'}',
        if (openingsFitted > 0) '$openingsFitted ${openingsFitted == 1 ? 'abertura encajada' : 'aberturas encajadas'} en su muro',
        if (openingsHosted > 0) '$openingsHosted ${openingsHosted == 1 ? 'abertura asignada' : 'aberturas asignadas'} a un muro',
        if (fragmentsRemoved > 0) '$fragmentsRemoved ${fragmentsRemoved == 1 ? 'fragmento eliminado' : 'fragmentos eliminados'}',
        if (slicesReoriented > 0) '$slicesReoriented ${slicesReoriented == 1 ? 'pieza reorientada' : 'piezas reorientadas'}',
      ];

  Map<String, Object?> toJson() => {
        'thickness_unified': thicknessUnified,
        'walls_aligned': wallsAligned,
        'segments_joined': segmentsJoined,
        'junctions_closed': junctionsClosed,
        'openings_fitted': openingsFitted,
        'openings_hosted': openingsHosted,
        'fragments_removed': fragmentsRemoved,
        'slices_reoriented': slicesReoriented,
        'summary': summary(),
      };
}

class RefineResult {
  final List<BuildingElement> elements;
  final List<Relation> relations;
  final RefineReport report;
  const RefineResult(this.elements, this.relations, this.report);
}

/// Muro mutable en coordenadas de eje: [a] = coordenada transversal (y si es horizontal),
/// [s0, s1] = rango a lo largo, [t] = espesor.
class _W {
  final String id;
  bool horizontal;
  double a, s0, s1, t;
  final double? confidence;
  final Source source;
  final double? heightM;
  bool removed = false;

  /// Era una rebanada transversal y se convirtió en trozo de línea: no es un bulto.
  bool reoriented = false;
  _W(this.id, this.horizontal, this.a, this.s0, this.s1, this.t, this.confidence, this.source, this.heightM);

  double get length => s1 - s0;

  Wall toWall() => horizontal
      ? Wall(id: id, source: source, confidence: confidence, start: Point2(s0, a), end: Point2(s1, a), thicknessPx: t, heightM: heightM)
      : Wall(id: id, source: source, confidence: confidence, start: Point2(a, s0), end: Point2(a, s1), thicknessPx: t, heightM: heightM);
}

class GeometryRefiner {
  final RefineConfig config;
  const GeometryRefiner([this.config = const RefineConfig()]);

  RefineResult refine(List<BuildingElement> elements) {
    final report = RefineReport();
    final walls = <_W>[];
    final others = <BuildingElement>[];
    final oblique = <Wall>[];
    for (final e in elements) {
      if (e is Wall) {
        final dx = (e.end.x - e.start.x).abs(), dy = (e.end.y - e.start.y).abs();
        if (dy <= 1e-6 && dx > 0) {
          walls.add(_W(e.id, true, e.start.y, math.min(e.start.x, e.end.x), math.max(e.start.x, e.end.x), e.thicknessPx,
              e.confidence, e.source, e.heightM));
        } else if (dx <= 1e-6 && dy > 0) {
          walls.add(_W(e.id, false, e.start.x, math.min(e.start.y, e.end.y), math.max(e.start.y, e.end.y), e.thicknessPx,
              e.confidence, e.source, e.heightM));
        } else {
          oblique.add(e); // se conserva tal cual
        }
      } else {
        others.add(e);
      }
    }
    if (walls.isEmpty) return RefineResult(elements, _relations(elements), report);

    // Primero rebanadas, bultos y muñones: si no, desplazan ejes y espesores de los muros reales.
    _reorientSlices(walls, report);
    _removeStubs(walls, report);
    _unifyThickness(walls.where((w) => !w.removed).toList(), report);
    _align(walls.where((w) => !w.removed).toList(), report);
    final openings = others.whereType<Opening>().toList();
    final fitted = _fitOpenings(openings, walls.where((w) => !w.removed).toList(), report);
    final merged = _joinSegments(walls, fitted, report);
    _removeStubs(walls, report);
    _closeJunctions(walls, others.whereType<ColumnElement>().toList(), fitted, report);
    _removeFragments(walls, report);
    _removeStubs(walls, report);

    final alive = {for (final w in walls.where((w) => !w.removed)) w.id};
    final out = <BuildingElement>[
      for (final w in walls)
        if (!w.removed) w.toWall(),
      ...oblique,
      for (final e in others)
        if (e is Opening) _withHost(fitted[e.id]!, alive, merged) else e,
    ];
    return RefineResult(out, _relations(out), report);
  }

  // ------------------------------------------------------------ 0. rebanadas

  /// Rebanadas: piezas cortas que cubren de cara a cara la banda de una línea de muro
  /// perpendicular (la descomposición en rectángulos parte en tajadas un tramo de borde
  /// irregular). Pasan a ser un trozo de esa línea, con su eje y su espesor, y después la
  /// unión de tramos las junta en un muro continuo.
  void _reorientSlices(List<_W> walls, RefineReport r) {
    // Espesor típico del plano (mediana ponderada por largo): una "línea" de muro tiene que
    // ser larga respecto de su espesor Y del espesor típico (una rebanada fina no lo es).
    final byT = [...walls]..sort((a, b) => a.t.compareTo(b.t));
    final half = byT.fold<double>(0, (s, w) => s + w.length) / 2;
    var acc = 0.0, typical = byT.isEmpty ? 0.0 : byT.last.t;
    for (final w in byT) {
      acc += w.length;
      if (acc >= half) {
        typical = w.t;
        break;
      }
    }
    final lines = walls.where((w) => w.length >= 3 * math.max(w.t, typical)).toList();
    for (final w in walls) {
      if (lines.any((l) => identical(l, w))) continue;
      _W? best;
      var bestD = double.infinity;
      final mid = (w.s0 + w.s1) / 2;
      for (final o in lines) {
        if (o.horizontal == w.horizontal) continue;
        if (w.length < 0.6 * o.t || w.length > 1.6 * o.t) continue; // abarca la banda, no mucho más
        final d = (mid - o.a).abs();
        if (d > 0.35 * o.t) continue; // centrada en el eje de la línea
        if (w.a < o.s0 - 6 * o.t || w.a > o.s1 + 6 * o.t) continue; // sobre la línea o cerca de su extremo (hasta un vano de puerta)
        if (d < bestD) {
          bestD = d;
          best = o;
        }
      }
      if (best == null) continue;
      final pos = w.a, half = w.t / 2;
      w
        ..horizontal = best.horizontal
        ..a = best.a
        ..s0 = pos - half
        ..s1 = pos + half
        ..t = best.t
        ..reoriented = true;
      r.slicesReoriented++;
    }
  }

  // ------------------------------------------------------------ 1. espesores

  void _unifyThickness(List<_W> walls, RefineReport r) {
    final sorted = [...walls]..sort((a, b) => a.t.compareTo(b.t));
    final groups = <List<_W>>[];
    for (final w in sorted) {
      if (groups.isNotEmpty) {
        final g = groups.last;
        final ref = g.first.t;
        if (w.t <= ref * (1 + config.thicknessTolerance) + 0.5) {
          g.add(w);
          continue;
        }
      }
      groups.add([w]);
    }
    for (final g in groups) {
      // Mediana ponderada por largo: el espesor "típico" del grupo.
      final byT = [...g]..sort((a, b) => a.t.compareTo(b.t));
      final half = byT.fold<double>(0, (s, w) => s + w.length) / 2;
      var acc = 0.0;
      var value = byT.last.t;
      for (final w in byT) {
        acc += w.length;
        if (acc >= half) {
          value = w.t;
          break;
        }
      }
      for (final w in g) {
        if ((w.t - value).abs() > 0.5) r.thicknessUnified++;
        w.t = value;
      }
    }
  }

  // ------------------------------------------------------------ 2. alineación

  void _align(List<_W> walls, RefineReport r) {
    for (final horizontal in [true, false]) {
      final ws = walls.where((w) => w.horizontal == horizontal).toList()..sort((a, b) => a.a.compareTo(b.a));
      var i = 0;
      while (i < ws.length) {
        var j = i + 1;
        while (j < ws.length && ws[j].a - ws[j - 1].a <= config.alignFactor * math.max(ws[j].t, ws[j - 1].t)) {
          j++;
        }
        if (j - i > 1) {
          final group = ws.sublist(i, j);
          final total = group.fold<double>(0, (s, w) => s + w.length);
          final mean = group.fold<double>(0, (s, w) => s + w.a * w.length) / total;
          for (final w in group) {
            if ((w.a - mean).abs() > 0.5) r.wallsAligned++;
            w.a = mean;
          }
        }
        i = j;
      }
    }
  }

  // ------------------------------------------------------------ 3. aberturas

  Map<String, Opening> _fitOpenings(List<Opening> openings, List<_W> walls, RefineReport r) {
    final byId = {for (final w in walls) w.id: w};
    final out = <String, Opening>{};
    for (final o in openings) {
      final f = o.footprint;
      final horizontal = f.width >= f.height;
      final across = horizontal ? f.center.y : f.center.x;
      final s0 = horizontal ? f.left : f.top, s1 = horizontal ? f.right : f.bottom;
      var host = o.hostWallId == null ? null : byId[o.hostWallId];
      if (host != null && host.horizontal != horizontal) host = null;
      if (host == null) {
        // El muro paralelo más cercano que pase junto a la abertura.
        double best = double.infinity;
        for (final w in walls) {
          if (w.horizontal != horizontal) continue;
          final d = (w.a - across).abs();
          final gap = math.max(0.0, math.max(w.s0 - s1, s0 - w.s1));
          if (d <= math.max(w.t, horizontal ? f.height : f.width) && gap <= config.gapFactor * w.t && d < best) {
            best = d;
            host = w;
          }
        }
        if (host != null) r.openingsHosted++;
      }
      if (host == null) {
        out[o.id] = o;
        continue;
      }
      // Encaje: espesor y eje del muro; extremos pegados a los tramos vecinos.
      var n0 = s0, n1 = s1;
      for (final w in walls) {
        if (w.horizontal != horizontal || (w.a - host.a).abs() > 0.5 * w.t) continue;
        if ((w.s1 - s0).abs() <= 0.6 * w.t) n0 = w.s1;
        if ((w.s0 - s1).abs() <= 0.6 * w.t) n1 = w.s0;
      }
      if (n1 <= n0) {
        n0 = s0;
        n1 = s1;
      }
      final half = host.t / 2;
      final rect = horizontal ? Rect2(n0, host.a - half, n1, host.a + half) : Rect2(host.a - half, n0, host.a + half, n1);
      if ((rect.left - f.left).abs() > 0.5 ||
          (rect.top - f.top).abs() > 0.5 ||
          (rect.right - f.right).abs() > 0.5 ||
          (rect.bottom - f.bottom).abs() > 0.5) {
        r.openingsFitted++;
      }
      out[o.id] = Opening(
          id: o.id,
          source: o.source,
          confidence: o.confidence,
          type: o.type,
          footprint: rect,
          hostWallId: host.id,
          heightM: o.heightM,
          sillHeightM: o.sillHeightM);
    }
    return out;
  }

  bool _openingIn(Map<String, Opening> openings, bool horizontal, double a, double s0, double s1, double t) {
    for (final o in openings.values) {
      final f = o.footprint;
      final oa = horizontal ? f.center.y : f.center.x;
      final os0 = horizontal ? f.left : f.top, os1 = horizontal ? f.right : f.bottom;
      if ((oa - a).abs() <= t && os1 > s0 - 0.5 && os0 < s1 + 0.5) return true;
    }
    return false;
  }

  // ------------------------------------------------------------ 4. unión de tramos

  Map<String, String> _joinSegments(List<_W> walls, Map<String, Opening> openings, RefineReport r) {
    final merged = <String, String>{};
    for (final horizontal in [true, false]) {
      final ws = walls.where((w) => w.horizontal == horizontal && !w.removed).toList()
        ..sort((a, b) => a.a != b.a ? a.a.compareTo(b.a) : a.s0.compareTo(b.s0));
      for (var i = 0; i < ws.length; i++) {
        final a = ws[i];
        if (a.removed) continue;
        for (var j = i + 1; j < ws.length; j++) {
          final b = ws[j];
          if (b.removed) continue;
          // Mismo eje (hasta medio espesor) y espesores compatibles (hasta el doble): en una
          // foto un muro suele salir partido en tramos de espesor algo distinto.
          if ((b.a - a.a).abs() > 0.5 * math.max(a.t, b.t)) continue;
          if (math.max(a.t, b.t) > 2.0 * math.min(a.t, b.t)) continue;
          final gap = b.s0 - a.s1;
          if (gap > config.gapFactor * math.max(a.t, b.t)) continue;
          if (gap > 0 && _openingIn(openings, horizontal, a.a, a.s1, b.s0, math.max(a.t, b.t))) continue;
          final la = a.length, lb = b.length;
          a.t = (a.t * la + b.t * lb) / (la + lb);
          a.a = (a.a * la + b.a * lb) / (la + lb);
          a.s0 = math.min(a.s0, b.s0);
          a.s1 = math.max(a.s1, b.s1);
          b.removed = true;
          merged[b.id] = a.id;
          r.segmentsJoined++;
        }
      }
    }
    return merged;
  }

  // ------------------------------------------------------------ 5. esquinas

  void _closeJunctions(List<_W> walls, List<ColumnElement> columns, Map<String, Opening> openings, RefineReport r) {
    final alive = walls.where((w) => !w.removed).toList();
    for (final w in alive) {
      for (final end in [false, true]) {
        final s = end ? w.s1 : w.s0;
        _W? best;
        var bestD = double.infinity;
        for (final p in alive) {
          if (identical(p, w) || p.horizontal == w.horizontal) continue;
          final tol = config.gapFactor * math.max(w.t, p.t);
          final d = (p.a - s).abs();
          if (d > tol) continue;
          // El eje de w tiene que cruzar el tramo de p (con margen de un espesor).
          if (w.a < p.s0 - w.t || w.a > p.s1 + w.t) continue;
          // No cruzar una abertura para llegar al otro muro.
          final lo = math.min(s, p.a), hi = math.max(s, p.a);
          if (hi - lo > 0.5 && _openingIn(openings, w.horizontal, w.a, lo, hi, w.t)) continue;
          if (d < bestD) {
            bestD = d;
            best = p;
          }
        }
        double? target;
        if (best != null) {
          // Hasta la cara exterior del otro muro: las esquinas quedan macizas.
          target = end ? best.a + best.t / 2 : best.a - best.t / 2;
          // Extender p también si el extremo de w queda fuera de su tramo (esquina en L).
          if (w.a > best.s1) best.s1 = w.a + w.t / 2;
          if (w.a < best.s0) best.s0 = w.a - w.t / 2;
        } else {
          // Columna en el extremo: el muro llega hasta su centro.
          for (final c in columns) {
            final f = c.footprint;
            final ca = w.horizontal ? f.center.y : f.center.x;
            final cs = w.horizontal ? f.center.x : f.center.y;
            final size = math.max(f.width, f.height);
            if ((ca - w.a).abs() <= size / 2 + w.t / 2 && (cs - s).abs() <= config.gapFactor * w.t + size / 2) {
              target = cs;
              break;
            }
          }
        }
        if (target == null) continue;
        final changed = (target - s).abs() > 0.5;
        if (end) {
          if (target > w.s0 + w.t * 0.5) w.s1 = target;
        } else {
          if (target < w.s1 - w.t * 0.5) w.s0 = target;
        }
        if (changed) r.junctionsClosed++;
      }
    }
  }

  // ------------------------------------------------------------ 6. fragmentos

  void _removeFragments(List<_W> walls, RefineReport r) {
    final alive = walls.where((w) => !w.removed).toList();
    for (final w in alive) {
      if (w.length >= 0.8 * w.t) continue;
      // Un trozo más corto que su espesor y apoyado en otro muro es ruido de la detección.
      final touches = alive.any((o) =>
          !identical(o, w) &&
          !o.removed &&
          _rect(o).inflate(1).overlaps(_rect(w)));
      if (touches) {
        w.removed = true;
        r.fragmentsRemoved++;
      }
    }
    // Trozos cortos aislados (texto, símbolos o manchas confundidos con muro).
    for (final w in alive) {
      if (w.removed || w.length >= 3 * w.t) continue;
      final near = alive.any((o) => !identical(o, w) && !o.removed && _rect(o).inflate(w.t).overlaps(_rect(w)));
      if (!near) {
        w.removed = true;
        r.fragmentsRemoved++;
      }
    }
  }

  /// Muñones: tramos cortos (< 2,5 espesores) que quedan en su mayor parte dentro de otro
  /// muro. Salen de protuberancias de la foto o de la máscara y, extruidos a altura completa,
  /// se ven como franjas. Una unión en T verdadera es larga y no se toca.
  void _removeStubs(List<_W> walls, RefineReport r) {
    final alive = walls.where((w) => !w.removed).toList()..sort((a, b) => a.length.compareTo(b.length));
    for (final w in alive) {
      if (w.removed || w.reoriented) continue;
      final shortSelf = w.length < 2.5 * w.t;
      final rw = _rect(w);
      final area = (rw.r - rw.l) * (rw.b - rw.t);
      if (area <= 0) continue;
      var covered = 0.0;
      var straddles = false;
      for (final o in alive) {
        if (identical(o, w) || o.removed || o.length <= w.length) continue;
        if (shortSelf) covered += _intersection(rw, _rect(o));
        // Atraviesa un muro perpendicular de lado a lado siendo corto: una T verdadera
        // nace en la cara del muro y entra al ambiente; esto es un artefacto.
        if (o.horizontal != w.horizontal &&
            w.length < 3 * o.t &&
            w.s0 < o.a - o.t / 4 &&
            w.s1 > o.a + o.t / 4 &&
            w.a > o.s0 &&
            w.a < o.s1) {
          straddles = true;
        }
        // Bulto: paralelo, sobre el mismo eje y pegado a un muro más largo (en una foto,
        // un ensanche local del trazo). Un tramo real sería largo o tendría su propio eje.
        final band = math.max(w.t, o.t) / 2;
        if (o.horizontal == w.horizontal &&
            (w.a - o.a).abs() <= band &&
            w.length < 2.5 * math.max(w.t, o.t) &&
            w.s1 >= o.s0 - o.t &&
            w.s0 <= o.s1 + o.t) {
          straddles = true;
        }
      }
      if (covered >= 0.5 * area || straddles) {
        w.removed = true;
        r.fragmentsRemoved++;
      }
    }
  }

  static double _intersection(_R a, _R b) {
    final w = math.min(a.r, b.r) - math.max(a.l, b.l);
    final h = math.min(a.b, b.b) - math.max(a.t, b.t);
    return w > 0 && h > 0 ? w * h : 0;
  }

  static _R _rect(_W w) => w.horizontal ? _R(w.s0, w.a - w.t / 2, w.s1, w.a + w.t / 2) : _R(w.a - w.t / 2, w.s0, w.a + w.t / 2, w.s1);

  /// Anfitrión final: si su muro se unió a otro, pasa al que quedó; si desapareció, ninguno.
  static Opening _withHost(Opening o, Set<String> alive, Map<String, String> merged) {
    var host = o.hostWallId;
    var guard = 0;
    while (host != null && merged.containsKey(host) && guard++ < 64) {
      host = merged[host];
    }
    if (host != null && !alive.contains(host)) host = null;
    if (host == o.hostWallId) return o;
    return Opening(
        id: o.id,
        source: o.source,
        confidence: o.confidence,
        type: o.type,
        footprint: o.footprint,
        hostWallId: host,
        heightM: o.heightM,
        sillHeightM: o.sillHeightM);
  }

  static List<Relation> _relations(List<BuildingElement> els) => [
        for (final e in els)
          if (e is Opening && e.hostWallId != null)
            Relation(RelationType.hosts, e.hostWallId!, e.id, const Source(Provenance.derived)),
      ];
}

class _R {
  final double l, t, r, b;
  const _R(this.l, this.t, this.r, this.b);
  _R inflate(double d) => _R(l - d, t - d, r + d, b + d);
  bool overlaps(_R o) => l < o.r && o.l < r && t < o.b && o.t < b;
}
