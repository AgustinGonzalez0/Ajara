/// Operaciones de imagen básicas en Dart puro (sin OpenCV ni modelos).
///
/// Todo opera sobre buffers `Uint8List` fila-mayor. Pensado para ejecutarse en un
/// isolate en cualquier celular: complejidad lineal o casi lineal en píxeles.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class GrayImage {
  final int width;
  final int height;
  final Uint8List data;
  GrayImage(this.width, this.height, this.data) {
    if (data.length != width * height) throw ArgumentError('tamaño de buffer inválido');
  }
  factory GrayImage.filled(int w, int h, int v) => GrayImage(w, h, Uint8List(w * h)..fillRange(0, w * h, v));

  int at(int x, int y) => data[y * width + x];

  /// Luminancia (BT.601) desde RGB intercalado.
  factory GrayImage.fromRgb(int w, int h, Uint8List rgb) {
    final out = Uint8List(w * h);
    for (var i = 0, j = 0; i < out.length; i++, j += 3) {
      out[i] = (rgb[j] * 299 + rgb[j + 1] * 587 + rgb[j + 2] * 114) ~/ 1000;
    }
    return GrayImage(w, h, out);
  }

  Uint8List toRgb() {
    final out = Uint8List(width * height * 3);
    for (var i = 0, j = 0; i < data.length; i++, j += 3) {
      out[j] = out[j + 1] = out[j + 2] = data[i];
    }
    return out;
  }

  /// Reducción por promedio de bloques (rápida, para análisis global).
  GrayImage downscale(int factor) {
    if (factor <= 1) return this;
    final w = width ~/ factor, h = height ~/ factor;
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var s = 0;
        for (var dy = 0; dy < factor; dy++) {
          final base = (y * factor + dy) * width + x * factor;
          for (var dx = 0; dx < factor; dx++) {
            s += data[base + dx];
          }
        }
        out[y * w + x] = s ~/ (factor * factor);
      }
    }
    return GrayImage(w, h, out);
  }
}

/// Imagen integral (sumas acumuladas) de tamaño (w+1)·(h+1).
Float64List integral(GrayImage g) {
  final w = g.width, h = g.height;
  final s = Float64List((w + 1) * (h + 1));
  for (var y = 0; y < h; y++) {
    double row = 0;
    for (var x = 0; x < w; x++) {
      row += g.data[y * w + x];
      s[(y + 1) * (w + 1) + x + 1] = s[y * (w + 1) + x + 1] + row;
    }
  }
  return s;
}

double _boxMean(Float64List s, int w, int h, int x0, int y0, int x1, int y1) {
  x0 = x0.clamp(0, w);
  x1 = x1.clamp(0, w);
  y0 = y0.clamp(0, h);
  y1 = y1.clamp(0, h);
  final area = (x1 - x0) * (y1 - y0);
  if (area <= 0) return 0;
  final W = w + 1;
  return (s[y1 * W + x1] - s[y0 * W + x1] - s[y1 * W + x0] + s[y0 * W + x0]) / area;
}

/// Umbral de Otsu sobre el histograma de grises.
int otsu(GrayImage g) {
  final hist = List<int>.filled(256, 0);
  for (final v in g.data) {
    hist[v]++;
  }
  final total = g.data.length;
  double sum = 0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  double sumB = 0, best = -1;
  var wB = 0, thr = 127;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB, mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      thr = t;
    }
  }
  return thr;
}

/// Normaliza la iluminación de una foto: divide por el fondo estimado (media local
/// amplia) para que el papel quede blanco uniforme y la tinta conserve contraste.
GrayImage normalizeIllumination(GrayImage g, {int? window}) {
  final w = g.width, h = g.height;
  final r = (window ?? math.max(15, math.min(w, h) ~/ 12)) ~/ 2;
  final s = integral(g);
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final bg = _boxMean(s, w, h, x - r, y - r, x + r + 1, y + r + 1);
      final v = bg <= 1 ? 255.0 : g.data[y * w + x] / bg * 255.0;
      out[y * w + x] = v >= 255 ? 255 : v.toInt();
    }
  }
  return GrayImage(w, h, out);
}

/// Binarización adaptativa (media local). Devuelve máscara 1 = tinta.
/// Robusta a sombras e iluminación despareja típica de una foto con el celular.
Uint8List adaptiveInk(GrayImage g, {int? window, double offset = 12, int globalMax = 200}) {
  final w = g.width, h = g.height;
  final r = (window ?? math.max(7, math.min(w, h) ~/ 30)) ~/ 2;
  final s = integral(g);
  final out = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = g.data[y * w + x];
      if (v > globalMax) continue; // papel claro: nunca tinta
      final mean = _boxMean(s, w, h, x - r, y - r, x + r + 1, y + r + 1);
      if (v < mean - offset) out[y * w + x] = 1;
    }
  }
  return out;
}

/// Erosión/dilatación binaria separable con un cuadrado de lado 2k+1.
Uint8List morph(Uint8List mask, int w, int h, int k, {required bool dilate}) {
  if (k <= 0) return Uint8List.fromList(mask);
  final tmp = Uint8List(w * h), out = Uint8List(w * h);
  final target = dilate ? 1 : 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = 1 - target;
      for (var d = -k; d <= k; d++) {
        final xx = x + d;
        final m = (xx < 0 || xx >= w) ? 0 : mask[y * w + xx];
        if (m == target) {
          v = target;
          break;
        }
      }
      tmp[y * w + x] = v;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = 1 - target;
      for (var d = -k; d <= k; d++) {
        final yy = y + d;
        final m = (yy < 0 || yy >= h) ? 0 : tmp[yy * w + x];
        if (m == target) {
          v = target;
          break;
        }
      }
      out[y * w + x] = v;
    }
  }
  return out;
}
