/// Segmentación por tiles con recomposición por bandas (memoria acotada).
///
/// Misma rejilla y misma ponderación que `structura-core/core/tiling.py`
/// (tile 512, overlap 64, último tile alineado al borde, relleno blanco,
/// ventana con rampa lineal 0.1→1 en las franjas de solape). Diferencia: en
/// lugar de acumular probabilidades para TODO el plano (C·H·W floats, cientos
/// de MB en planos grandes), acumula una banda de `tile` filas y finaliza las
/// filas que ningún tile posterior puede tocar. Memoria ≈ (C+1)·tile·W·4 bytes.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:structura_geometry/structura_geometry.dart';

import 'contracts.dart';

List<int> tileStarts(int length, int tile, int stride) {
  if (length <= tile) return [0];
  final values = <int>[for (var v = 0; v <= length - tile; v += stride) v];
  if (values.last != length - tile) values.add(length - tile);
  return values;
}

Float32List blendWindow1D(int tile, int overlap) {
  final w = Float32List(tile)..fillRange(0, tile, 1.0);
  if (overlap > 0) {
    for (var i = 0; i < overlap; i++) {
      final v = overlap == 1 ? 0.1 : 0.1 + (1.0 - 0.1) * i / (overlap - 1);
      w[i] = v;
      w[tile - 1 - i] = v;
    }
  }
  return w;
}

class TiledSegmenter {
  /// Aumento en inferencia (TTA): cada tile se analiza original y espejado en
  /// horizontal, vertical y ambos ejes; las probabilidades se promedian. ~4× más lento,
  /// corrige errores aislados (el modelo se entrenó con esos mismos espejos).
  final bool tta;
  const TiledSegmenter({this.tta = false});

  static const _identity = [(false, false)];
  static const _flips = [(false, false), (true, false), (false, true), (true, true)];

  Future<SegmentationResult> segment(
    PlanRaster raster,
    TileInferencer inferencer, {
    CancellationToken? token,
    void Function(int done, int total)? onTile,
  }) async {
    final d = inferencer.descriptor;
    final tile = d.tile, overlap = d.overlap, c = d.numClasses;
    if (overlap < 0 || overlap >= tile) throw ArgumentError('overlap inválido');
    final w = raster.width, h = raster.height, stride = tile - overlap;
    final xs = tileStarts(w, tile, stride), ys = tileStarts(h, tile, stride);
    final total = xs.length * ys.length;
    final win = blendWindow1D(tile, overlap);

    final labels = Uint8List(w * h);
    final confidence = Float32List(w * h);
    // Banda: filas [bandTop, bandTop + tile) del plano.
    final acc = Float32List(c * tile * w);
    final wsum = Float32List(tile * w);
    var bandTop = 0;
    var done = 0;
    final input = Float32List(3 * tile * tile);
    final flipped = Float32List(3 * tile * tile);
    final plane = tile * tile;
    final tileProb = Float32List(c * plane);
    final variants = tta ? _flips : _identity;

    void finalizeRows(int from, int to) {
      for (var y = from; y < to; y++) {
        final by = y - bandTop;
        for (var x = 0; x < w; x++) {
          final wi = by * w + x;
          final ws = wsum[wi];
          var best = 0;
          var bestV = -1.0;
          for (var k = 0; k < c; k++) {
            final v = acc[k * tile * w + wi];
            if (v > bestV) {
              bestV = v;
              best = k;
            }
          }
          labels[y * w + x] = best;
          confidence[y * w + x] = ws > 0 ? bestV / ws : 0;
        }
      }
    }

    void shiftBand(int rows) {
      if (rows <= 0) return;
      final keep = tile - rows;
      for (var k = 0; k < c; k++) {
        final base = k * tile * w;
        if (keep > 0) acc.setRange(base, base + keep * w, acc, base + rows * w);
        acc.fillRange(base + math.max(0, keep) * w, base + tile * w, 0);
      }
      if (keep > 0) wsum.setRange(0, keep * w, wsum, rows * w);
      wsum.fillRange(math.max(0, keep) * w, tile * w, 0);
      bandTop += rows;
    }

    for (var yi = 0; yi < ys.length; yi++) {
      final y = ys[yi];
      if (y > bandTop) shiftBand(y - bandTop);
      for (final x in xs) {
        token?.throwIfCancelled();
        // Entrada CHW con relleno blanco.
        input.fillRange(0, input.length, 1.0);
        final ch = math.min(tile, h - y), cw = math.min(tile, w - x);
        for (var ty = 0; ty < ch; ty++) {
          var src = ((y + ty) * w + x) * 3;
          final row = ty * tile;
          for (var tx = 0; tx < cw; tx++) {
            input[row + tx] = raster.rgb[src] / 255.0;
            input[plane + row + tx] = raster.rgb[src + 1] / 255.0;
            input[2 * plane + row + tx] = raster.rgb[src + 2] / 255.0;
            src += 3;
          }
        }
        tileProb.fillRange(0, tileProb.length, 0);
        for (final (fx, fy) in variants) {
          final Float32List inp;
          if (!fx && !fy) {
            inp = input;
          } else {
            for (var ch2 = 0; ch2 < 3; ch2++) {
              final base = ch2 * plane;
              for (var ty = 0; ty < tile; ty++) {
                final sy = fy ? tile - 1 - ty : ty;
                for (var tx = 0; tx < tile; tx++) {
                  flipped[base + ty * tile + tx] = input[base + sy * tile + (fx ? tile - 1 - tx : tx)];
                }
              }
            }
            inp = flipped;
          }
          final logits = await inferencer.infer(inp);
          if (logits.length != c * plane) {
            throw StateError('El modelo devolvió ${logits.length} valores; se esperaban ${c * plane}');
          }
          final share = 1.0 / variants.length;
          for (var vy = 0; vy < tile; vy++) {
            final oy = fy ? tile - 1 - vy : vy;
            for (var vx = 0; vx < tile; vx++) {
              final ox = fx ? tile - 1 - vx : vx;
              final p = vy * tile + vx;
              var mx = logits[p];
              for (var k = 1; k < c; k++) {
                final v = logits[k * plane + p];
                if (v > mx) mx = v;
              }
              var sum = 0.0;
              for (var k = 0; k < c; k++) {
                sum += math.exp(logits[k * plane + p] - mx);
              }
              final q = oy * tile + ox;
              for (var k = 0; k < c; k++) {
                tileProb[k * plane + q] += math.exp(logits[k * plane + p] - mx) / sum * share;
              }
            }
          }
        }
        for (var ty = 0; ty < ch; ty++) {
          final by = y + ty - bandTop;
          final wy = win[ty];
          for (var tx = 0; tx < cw; tx++) {
            final p = ty * tile + tx;
            final wv = wy * win[tx];
            final wi = by * w + x + tx;
            for (var k = 0; k < c; k++) {
              acc[k * tile * w + wi] += tileProb[k * plane + p] * wv;
            }
            wsum[wi] += wv;
          }
        }
        done++;
        onTile?.call(done, total);
      }
      final next = yi + 1 < ys.length ? ys[yi + 1] : h;
      finalizeRows(y, math.min(next, h));
    }
    return SegmentationResult(width: w, height: h, labels: labels, confidence: confidence);
  }
}
