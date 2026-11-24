/// Detector clásico de elementos arquitectónicos (sin IA, determinista).
///
/// Idea: en un plano los muros se dibujan con trazo grueso (relleno o poché) y casi
/// todo lo demás (cotas, textos, mobiliario, ejes) con trazo fino. Se mide el ancho
/// de trazo de cada píxel de tinta como min(corrida horizontal, corrida vertical);
/// el espesor de muro es la moda (ponderada) de los anchos ≥ 3 px y los píxeles con
/// ancho ≥ 55 % de esa moda forman la máscara de muros.
///
/// Aberturas: cierre por corridas — en cada fila/columna se marcan los huecos entre
/// dos tramos de muro de largo entre 1,5 y 16 espesores, y se aceptan solo las
/// regiones con el "espesor" de un muro (descarta pasillos). Si el hueco contiene
/// trazos finos (el símbolo de ventana) es ventana; si está vacío es puerta/vano.
/// Columnas: bloques macizos compactos y aislados del resto de los muros.
///
/// Limitaciones (documentadas en la UI): no detecta escaleras ni muros dibujados con
/// una sola línea fina; asume plantas mayormente ortogonales. Para esos casos está
/// Vision AI (cuando haya un modelo entrenado con datos reales).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:structura_geometry/structura_geometry.dart';

import 'image_ops.dart';

class ClassicConfig {
  /// Espesor mínimo (px) para considerar un trazo como muro.
  final int minWallPx;

  /// Rango de largo de hueco (en espesores de muro) para aberturas.
  final double minGap, maxGap;

  /// Proporción de tinta fina en el hueco a partir de la cual es ventana.
  final double windowInkRatio;
  const ClassicConfig({this.minWallPx = 4, this.minGap = 1.5, this.maxGap = 16, this.windowInkRatio = 0.06});
}

class ClassicDiagnostics {
  final int wallThicknessPx;
  final int wallThresholdPx;
  final int inkPixels;
  final int wallPixels;
  final int doors, windows, columns;
  final List<String> warnings;
  const ClassicDiagnostics(this.wallThicknessPx, this.wallThresholdPx, this.inkPixels, this.wallPixels, this.doors,
      this.windows, this.columns, this.warnings);
  Map<String, Object?> toJson() => {
        'wall_thickness_px': wallThicknessPx,
        'wall_threshold_px': wallThresholdPx,
        'ink_pixels': inkPixels,
        'wall_pixels': wallPixels,
        'doors': doors,
        'windows': windows,
        'columns': columns,
        'warnings': warnings,
      };
}

class ClassicResult {
  final SegmentationResult segmentation;
  final ClassicDiagnostics diagnostics;
  const ClassicResult(this.segmentation, this.diagnostics);
}

class ClassicDetector {
  final ClassicConfig config;
  const ClassicDetector([this.config = const ClassicConfig()]);

  /// Igual que [detect] pero procesa una versión reducida (lado mayor ≤ [maxSide]) y
  /// devuelve las etiquetas al tamaño original. Acota memoria y tiempo en celulares
  /// de gama baja con planos grandes (p. ej., A1 a 200 DPI ≈ 30 MP).
  ClassicResult detectScaled(GrayImage gray, {int maxSide = 3000, bool normalize = true}) {
    final long = math.max(gray.width, gray.height);
    final factor = (long / maxSide).ceil();
    if (factor <= 1) return detect(gray, normalize: normalize);
    final small = gray.downscale(factor);
    final r = detect(small, normalize: normalize);
    final w = gray.width, h = gray.height, sw = small.width, sh = small.height;
    final labels = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final sy = math.min(sh - 1, y ~/ factor);
      for (var x = 0; x < w; x++) {
        labels[y * w + x] = r.segmentation.labels[sy * sw + math.min(sw - 1, x ~/ factor)];
      }
    }
    final d = r.diagnostics;
    return ClassicResult(
      SegmentationResult(width: w, height: h, labels: labels),
      ClassicDiagnostics(d.wallThicknessPx * factor, d.wallThresholdPx * factor, d.inkPixels, d.wallPixels, d.doors,
          d.windows, d.columns, [...d.warnings, 'Procesado a escala 1/$factor por tamaño del plano.']),
    );
  }

  ClassicResult detect(GrayImage gray, {bool normalize = true}) {
    final g = normalize ? normalizeIllumination(gray) : gray;
    final w = g.width, h = g.height;
    final ink = adaptiveInk(g);
    final warnings = <String>[];

    // Ancho de trazo por píxel = min(corrida horizontal, corrida vertical).
    final hrun = Uint16List(w * h), vrun = Uint16List(w * h);
    for (var y = 0; y < h; y++) {
      var x = 0;
      while (x < w) {
        if (ink[y * w + x] == 0) {
          x++;
          continue;
        }
        var e = x;
        while (e < w && ink[y * w + e] == 1) {
          e++;
        }
        final len = math.min(e - x, 65535);
        for (var k = x; k < e; k++) {
          hrun[y * w + k] = len;
        }
        x = e;
      }
    }
    for (var x = 0; x < w; x++) {
      var y = 0;
      while (y < h) {
        if (ink[y * w + x] == 0) {
          y++;
          continue;
        }
        var e = y;
        while (e < h && ink[e * w + x] == 1) {
          e++;
        }
        final len = math.min(e - y, 65535);
        for (var k = y; k < e; k++) {
          vrun[k * w + x] = len;
        }
        y = e;
      }
    }
    final hist = List<int>.filled(257, 0);
    var inkCount = 0;
    for (var i = 0; i < w * h; i++) {
      if (ink[i] == 0) continue;
      inkCount++;
      hist[math.min(256, math.min(hrun[i], vrun[i]))]++;
    }
    // Moda ponderada de anchos >= minWallPx (suavizada con ventana de 3).
    var mode = 0, best = 0;
    for (var t = config.minWallPx; t < 256; t++) {
      final v = hist[t - 1] + hist[t] + hist[t + 1];
      if (v > best) {
        best = v;
        mode = t;
      }
    }
    final labels = Uint8List(w * h);
    if (mode == 0 || best < 50) {
      warnings.add('No se encontraron trazos gruesos (muros). ¿El plano dibuja los muros con línea simple?');
      return ClassicResult(SegmentationResult(width: w, height: h, labels: labels),
          ClassicDiagnostics(0, 0, inkCount, 0, 0, 0, 0, warnings));
    }
    final thr = math.max(config.minWallPx, (mode * 0.55).round());
    var wall = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      if (ink[i] == 1 && math.min(hrun[i], vrun[i]) >= thr) wall[i] = 1;
    }
    // Apertura morfológica: elimina espolones finos de cruces con líneas de cota.
    final k = math.max(1, thr ~/ 3);
    wall = morph(morph(wall, w, h, k, dilate: false), w, h, k, dilate: true);
    var wallCount = 0;
    for (var i = 0; i < w * h; i++) {
      if (wall[i] == 1) {
        labels[i] = ClassId.wall;
        wallCount++;
      }
    }

    final t = mode.toDouble();
    var doors = 0, windows = 0, columns = 0;

    // Columnas: componentes de muro compactas y aisladas.
    for (final c in Vectorizer.connectedComponents(SegmentationResult(width: w, height: h, labels: labels), ClassId.wall)) {
      final cw = c.maxX - c.minX + 1, ch = c.maxY - c.minY + 1;
      final aspect = math.max(cw, ch) / math.min(cw, ch);
      final fill = c.pixels / (cw * ch);
      if (math.max(cw, ch) <= 3.2 * t && math.min(cw, ch) >= 0.8 * t && aspect <= 1.5 && fill >= 0.75) {
        for (var y = c.minY; y <= c.maxY; y++) {
          for (var x = c.minX; x <= c.maxX; x++) {
            if (labels[y * w + x] == ClassId.wall) labels[y * w + x] = ClassId.column;
          }
        }
        columns++;
      }
    }

    // Aberturas por cierre de corridas: en cada fila (muros horizontales) o columna
    // (muros verticales) se marcan los huecos entre dos tramos de muro de largo
    // [minGap, maxGap]·t. Es robusto a la leve inclinación que deja una foto.
    final minL = (config.minGap * t).round(), maxL = (config.maxGap * t).round();
    for (final horizontal in [true, false]) {
      final gapMask = Uint8List(w * h);
      final outer = horizontal ? h : w, inner = horizontal ? w : h;
      int idx(int o, int i) => horizontal ? o * w + i : i * w + o;
      for (var o = 0; o < outer; o++) {
        var lastWallEnd = -1;
        for (var i = 0; i < inner; i++) {
          if (wall[idx(o, i)] == 1) {
            if (lastWallEnd >= 0) {
              final gap = i - lastWallEnd - 1;
              if (gap >= minL && gap <= maxL) {
                for (var k = lastWallEnd + 1; k < i; k++) {
                  gapMask[idx(o, k)] = 1;
                }
              }
            }
            lastWallEnd = i;
          }
        }
      }
      final seg = SegmentationResult(width: w, height: h, labels: gapMask);
      for (final c in Vectorizer.connectedComponents(seg, 1)) {
        final along = horizontal ? c.maxX - c.minX + 1 : c.maxY - c.minY + 1;
        final across = horizontal ? c.maxY - c.minY + 1 : c.maxX - c.minX + 1;
        // Un vano tiene el "espesor" de un muro; un pasillo entre muros paralelos no.
        if (across < 0.4 * t || across > 1.7 * t || along < minL) continue;
        // A ambos lados del vano debe haber un tramo de muro real (≥ 1,5 t), no una
        // columna adosada ni un fragmento: evita "puertas" falsas junto a columnas.
        // Se mide en 3 líneas paralelas (tolerancia a la leve inclinación de una foto).
        final c0 = horizontal ? c.minY : c.minX, c1 = horizontal ? c.maxY : c.maxX;
        final lines = {(c0 + c1) ~/ 2, c0 + (c1 - c0) ~/ 4, c1 - (c1 - c0) ~/ 4};
        int run(int line, int start, int step) {
          var n = 0;
          for (var k = start; k >= 0 && k < inner && n < 4 * t; k += step) {
            if (wall[idx(line, k)] == 0) break;
            n++;
          }
          return n;
        }
        final lo = horizontal ? c.minX : c.minY, hi = horizontal ? c.maxX : c.maxY;
        var before = 0, after = 0;
        for (final l in lines) {
          // Inicio/fin reales del hueco en esta línea (los bordes de una foto son irregulares).
          var s0 = -1, s1 = -1;
          for (var k = lo; k <= hi; k++) {
            if (gapMask[idx(l, k)] == 1) {
              if (s0 < 0) s0 = k;
              s1 = k;
            }
          }
          if (s0 < 0) continue;
          before = math.max(before, run(l, s0 - 1, -1));
          after = math.max(after, run(l, s1 + 1, 1));
        }
        if (before < 1.25 * t || after < 1.25 * t) continue;
        var inkIn = 0, area = 0;
        for (var y = c.minY; y <= c.maxY; y++) {
          for (var x = c.minX; x <= c.maxX; x++) {
            if (gapMask[y * w + x] == 0) continue;
            area++;
            if (ink[y * w + x] == 1) inkIn++;
          }
        }
        if (area == 0) continue;
        final cls = inkIn / area >= config.windowInkRatio ? ClassId.window : ClassId.door;
        for (var y = c.minY; y <= c.maxY; y++) {
          for (var x = c.minX; x <= c.maxX; x++) {
            if (gapMask[y * w + x] == 1 && labels[y * w + x] == 0) labels[y * w + x] = cls;
          }
        }
        if (cls == ClassId.window) {
          windows++;
        } else {
          doors++;
        }
      }
    }
    if (wallCount < 0.002 * w * h) warnings.add('Muy pocos píxeles de muro detectados; revisá la foto o el recorte.');
    return ClassicResult(
      SegmentationResult(width: w, height: h, labels: labels),
      ClassicDiagnostics(mode, thr, inkCount, wallCount, doors, windows, columns, warnings),
    );
  }
}
