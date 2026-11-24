/// Rectificación de fotos de planos: detección de la hoja + corrección de perspectiva.
///
/// 1. [detectPaperQuad]: la hoja es la región clara más grande (Otsu sobre una
///    versión reducida); sus esquinas se toman por los extremos de x+y y x−y.
///    Si no se encuentra una hoja convincente se devuelve el marco completo y la
///    UI deja que el usuario ajuste las 4 esquinas a mano.
/// 2. [warpPerspective]: homografía (DLT, 4 puntos) y muestreo bilineal inverso.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'image_ops.dart';

class Pt {
  final double x, y;
  const Pt(this.x, this.y);
  double dist(Pt o) => math.sqrt((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y));
  @override
  String toString() => '(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

/// Cuadrilátero en orden: arriba-izq, arriba-der, abajo-der, abajo-izq.
class Quad {
  final Pt tl, tr, br, bl;
  const Quad(this.tl, this.tr, this.br, this.bl);
  factory Quad.full(int w, int h) => Quad(const Pt(0, 0), Pt(w - 1.0, 0), Pt(w - 1.0, h - 1.0), Pt(0, h - 1.0));
  List<Pt> get points => [tl, tr, br, bl];
  Quad scaled(double k) => Quad(Pt(tl.x * k, tl.y * k), Pt(tr.x * k, tr.y * k), Pt(br.x * k, br.y * k), Pt(bl.x * k, bl.y * k));

  /// Tamaño de salida que conserva la proporción real de la hoja.
  (int, int) outputSize({int maxSide = 2400}) {
    final w = math.max(tl.dist(tr), bl.dist(br));
    final h = math.max(tl.dist(bl), tr.dist(br));
    final k = math.min(1.0, maxSide / math.max(w, h));
    return (math.max(1, (w * k).round()), math.max(1, (h * k).round()));
  }

  double get area {
    final p = points;
    double a = 0;
    for (var i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      a += p[i].x * p[j].y - p[j].x * p[i].y;
    }
    return a.abs() / 2;
  }
}

class PaperDetection {
  final Quad quad;

  /// Fracción de la imagen ocupada por la hoja; 1.0 si no se detectó (marco completo).
  final double coverage;
  final bool detected;
  const PaperDetection(this.quad, this.coverage, this.detected);
}

PaperDetection detectPaperQuad(GrayImage g, {double minCoverage = 0.2, double maxCoverage = 0.985}) {
  final factor = math.max(1, (math.max(g.width, g.height) / 480).ceil());
  final s = g.downscale(factor);
  final thr = otsu(s);
  final w = s.width, h = s.height;
  final bright = Uint8List(w * h);
  for (var i = 0; i < bright.length; i++) {
    bright[i] = s.data[i] > thr ? 1 : 0;
  }
  // Componente clara más grande (4-vecindad).
  final label = Int32List(w * h);
  var bestLabel = 0, bestSize = 0, cur = 0;
  final stack = <int>[];
  for (var i = 0; i < w * h; i++) {
    if (bright[i] == 0 || label[i] != 0) continue;
    cur++;
    var size = 0;
    stack.add(i);
    label[i] = cur;
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      size++;
      final x = p % w, y = p ~/ w;
      for (final q in [if (x > 0) p - 1, if (x < w - 1) p + 1, if (y > 0) p - w, if (y < h - 1) p + w]) {
        if (bright[q] == 1 && label[q] == 0) {
          label[q] = cur;
          stack.add(q);
        }
      }
    }
    if (size > bestSize) {
      bestSize = size;
      bestLabel = cur;
    }
  }
  final coverage = bestSize / (w * h);
  if (bestLabel == 0 || coverage < minCoverage || coverage > maxCoverage) {
    return PaperDetection(Quad.full(g.width, g.height), 1.0, false);
  }
  double minS = double.infinity, maxS = -double.infinity, minD = double.infinity, maxD = -double.infinity;
  Pt? tl, br, tr, bl;
  for (var i = 0; i < w * h; i++) {
    if (label[i] != bestLabel) continue;
    final x = (i % w).toDouble(), y = (i ~/ w).toDouble();
    final sum = x + y, diff = x - y;
    if (sum < minS) {
      minS = sum;
      tl = Pt(x, y);
    }
    if (sum > maxS) {
      maxS = sum;
      br = Pt(x, y);
    }
    if (diff > maxD) {
      maxD = diff;
      tr = Pt(x, y);
    }
    if (diff < minD) {
      minD = diff;
      bl = Pt(x, y);
    }
  }
  // Centro del píxel reducido → coordenadas originales.
  Pt up(Pt p) => Pt((p.x + 0.5) * factor, (p.y + 0.5) * factor);
  final quad = Quad(up(tl!), up(tr!), up(br!), up(bl!));
  if (quad.area < 0.1 * g.width * g.height) return PaperDetection(Quad.full(g.width, g.height), 1.0, false);
  return PaperDetection(quad, coverage, true);
}

/// Homografía 3x3 (h33 = 1) que lleva src[i] → dst[i]. Resuelve el sistema 8x8 (DLT).
List<double> homography(List<Pt> src, List<Pt> dst) {
  final a = List.generate(8, (_) => List<double>.filled(9, 0));
  for (var i = 0; i < 4; i++) {
    final x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y;
    a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u];
    a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v];
  }
  for (var c = 0; c < 8; c++) {
    var piv = c;
    for (var r = c + 1; r < 8; r++) {
      if (a[r][c].abs() > a[piv][c].abs()) piv = r;
    }
    if (a[piv][c].abs() < 1e-12) throw StateError('Esquinas degeneradas (colineales)');
    final t = a[c];
    a[c] = a[piv];
    a[piv] = t;
    for (var r = 0; r < 8; r++) {
      if (r == c) continue;
      final f = a[r][c] / a[c][c];
      for (var k = c; k < 9; k++) {
        a[r][k] -= f * a[c][k];
      }
    }
  }
  return [for (var i = 0; i < 8; i++) a[i][8] / a[i][i], 1.0];
}

Pt applyH(List<double> h, double x, double y) {
  final d = h[6] * x + h[7] * y + h[8];
  return Pt((h[0] * x + h[1] * y + h[2]) / d, (h[3] * x + h[4] * y + h[5]) / d);
}

/// Corrige la perspectiva: devuelve RGB de (outW x outH) con la hoja rectificada.
(int, int, Uint8List) warpPerspective(int srcW, int srcH, Uint8List rgb, Quad quad, {int maxSide = 2400}) {
  final (w, h) = quad.outputSize(maxSide: maxSide);
  final dstPts = [const Pt(0, 0), Pt(w - 1.0, 0), Pt(w - 1.0, h - 1.0), Pt(0, h - 1.0)];
  final hInv = homography(dstPts, quad.points); // destino → origen (muestreo inverso)
  final out = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = applyH(hInv, x.toDouble(), y.toDouble());
      final o = (y * w + x) * 3;
      if (p.x < 0 || p.y < 0 || p.x > srcW - 1 || p.y > srcH - 1) {
        out[o] = out[o + 1] = out[o + 2] = 255;
        continue;
      }
      final x0 = p.x.floor(), y0 = p.y.floor();
      final x1 = math.min(x0 + 1, srcW - 1), y1 = math.min(y0 + 1, srcH - 1);
      final fx = p.x - x0, fy = p.y - y0;
      for (var c = 0; c < 3; c++) {
        final v00 = rgb[(y0 * srcW + x0) * 3 + c], v10 = rgb[(y0 * srcW + x1) * 3 + c];
        final v01 = rgb[(y1 * srcW + x0) * 3 + c], v11 = rgb[(y1 * srcW + x1) * 3 + c];
        final v = (v00 * (1 - fx) + v10 * fx) * (1 - fy) + (v01 * (1 - fx) + v11 * fx) * fy;
        out[o + c] = v.round().clamp(0, 255);
      }
    }
  }
  return (w, h, out);
}
