/// Prolonga muros según la evidencia de la segmentación.
///
/// La vectorización corta un muro donde el trazo cambia de grosor, donde lo toca una
/// escalera o una columna, o cerca de una esquina; el afinado solo cierra huecos de hasta
/// ~1,6 espesores. Si la imagen muestra que el muro sigue, se lo prolonga a lo largo de su
/// eje mientras la franja central siga siendo muro (o columna). Se detiene en puertas y
/// ventanas (deben quedar como vano), en el fondo y en escaleras.
library;

import 'dart:math' as math;

import 'package:structura_model/structura_model.dart';

import 'segmentation.dart';

class EvidenceResult {
  final List<BuildingElement> elements;

  /// Extremos de muro prolongados.
  final int extended;
  const EvidenceResult(this.elements, this.extended);
}

/// [maxReachFactor] limita cuánto puede crecer cada extremo (en espesores de muro).
EvidenceResult extendWallsAlongEvidence(List<BuildingElement> elements, SegmentationResult seg,
    {double maxReachFactor = 8, double minWallFraction = 0.6}) {
  var extended = 0;
  final out = <BuildingElement>[];
  for (final e in elements) {
    if (e is! Wall || e.lengthPx <= 0) {
      out.add(e);
      continue;
    }
    final dx = (e.end.x - e.start.x) / e.lengthPx, dy = (e.end.y - e.start.y) / e.lengthPx;
    final half = math.max(1.0, e.thicknessPx * 0.3); // franja central: tolera bordes irregulares
    final maxReach = maxReachFactor * e.thicknessPx;
    final maxMiss = math.max(2, (0.5 * e.thicknessPx).round());

    bool isWallAt(double cx, double cy) {
      var good = 0, n = 0;
      for (var k = -half; k <= half; k += 1) {
        final x = (cx - dy * k).round(), y = (cy + dx * k).round();
        if (x < 0 || y < 0 || x >= seg.width || y >= seg.height) return false;
        final l = seg.labelAt(x, y);
        if (l == ClassId.door || l == ClassId.window) return false; // un vano corta el muro
        n++;
        if (l == ClassId.wall || l == ClassId.column) good++;
      }
      return n > 0 && good / n >= minWallFraction;
    }

    // Avanza desde [p] en la dirección (ux, uy); devuelve cuánto se puede prolongar.
    double reach(Point2 p, double ux, double uy) {
      var last = 0.0;
      var miss = 0;
      for (var s = 1.0; s <= maxReach; s += 1) {
        if (isWallAt(p.x + ux * s, p.y + uy * s)) {
          last = s;
          miss = 0;
        } else if (++miss > maxMiss) {
          break;
        }
      }
      return last;
    }

    final r0 = reach(e.start, -dx, -dy), r1 = reach(e.end, dx, dy);
    // Prolongar menos de medio espesor no cambia nada (el afinado ya llega a las caras).
    final g0 = r0 >= e.thicknessPx * 0.5 ? r0 : 0.0, g1 = r1 >= e.thicknessPx * 0.5 ? r1 : 0.0;
    if (g0 == 0 && g1 == 0) {
      out.add(e);
      continue;
    }
    extended += (g0 > 0 ? 1 : 0) + (g1 > 0 ? 1 : 0);
    out.add(Wall(
      id: e.id,
      source: e.source,
      confidence: e.confidence,
      start: Point2(e.start.x - dx * g0, e.start.y - dy * g0),
      end: Point2(e.end.x + dx * g1, e.end.y + dy * g1),
      thicknessPx: e.thicknessPx,
      heightM: e.heightM,
    ));
  }
  return EvidenceResult(out, extended);
}
