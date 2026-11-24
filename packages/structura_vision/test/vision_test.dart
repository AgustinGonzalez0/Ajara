import 'dart:math' as math;
import 'dart:typed_data';

import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_model/structura_model.dart';
import 'package:structura_vision/structura_vision.dart';
import 'package:test/test.dart';

/// Plano digital: muros de 12 px, vano de puerta con arco fino, ventana (dos líneas
/// finas dentro del espesor), columna aislada, cota y "texto" finos.
GrayImage planImage({int w = 900, int h = 640}) {
  final d = Uint8List(w * h)..fillRange(0, w * h, 255);
  void rect(int x0, int y0, int x1, int y1, [int v = 0]) {
    for (var y = math.max(0, y0); y < math.min(h, y1); y++) {
      for (var x = math.max(0, x0); x < math.min(w, x1); x++) {
        d[y * w + x] = v;
      }
    }
  }

  rect(60, 60, 840, 72); // superior
  rect(60, 568, 840, 580); // inferior
  rect(60, 60, 72, 580); // izquierdo
  rect(828, 60, 840, 580); // derecho
  rect(450, 72, 462, 568); // tabique
  rect(450, 200, 462, 270, 255); // vano de puerta (70 px ≈ 5,8 espesores)
  for (var a = 0; a <= 90; a++) {
    final r = a * math.pi / 180;
    rect(462 + (70 * math.cos(r)).round(), 200 + (70 * math.sin(r)).round(), 463 + (70 * math.cos(r)).round(),
        201 + (70 * math.sin(r)).round());
  }
  rect(200, 60, 320, 72, 255); // hueco de ventana en el muro superior
  rect(200, 62, 320, 63); // líneas finas de carpintería
  rect(200, 69, 320, 70);
  rect(650, 400, 676, 426); // columna aislada
  rect(60, 30, 840, 31); // línea de cota
  for (var i = 0; i < 6; i++) {
    rect(400 + i * 8, 18, 402 + i * 8, 26); // "texto" de cota
  }
  return GrayImage(w, h, d);
}

/// Simula una foto: el plano en perspectiva sobre una mesa, con gradiente de luz y ruido.
(int, int, Uint8List, Quad) photoOf(GrayImage plan) {
  const w = 1200, h = 1000;
  final truth = Quad(const Pt(140, 110), const Pt(1080, 160), const Pt(1030, 860), const Pt(170, 900));
  final hm = homography(truth.points, [const Pt(0, 0), Pt(plan.width - 1.0, 0), Pt(plan.width - 1.0, plan.height - 1.0), Pt(0, plan.height - 1.0)]);
  final rgb = Uint8List(w * h * 3);
  final rnd = math.Random(3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final light = 0.75 + 0.25 * (x / w); // sombra a la izquierda
      final p = applyH(hm, x.toDouble(), y.toDouble());
      double v;
      if (p.x >= 0 && p.y >= 0 && p.x < plan.width - 1 && p.y < plan.height - 1) {
        v = plan.at(p.x.round(), p.y.round()).toDouble();
      } else {
        v = 70; // mesa oscura
      }
      v = (v * light + rnd.nextInt(17) - 8).clamp(0, 255);
      final o = (y * w + x) * 3;
      rgb[o] = rgb[o + 1] = rgb[o + 2] = v.round();
    }
  }
  return (w, h, rgb, truth);
}

void main() {
  test('plano digital: muros, puerta, ventana y columna sin IA', () {
    final r = const ClassicDetector().detect(planImage());
    final d = r.diagnostics;
    expect(d.wallThicknessPx, inInclusiveRange(11, 13));
    expect(d.doors, 1);
    expect(d.windows, 1);
    expect(d.columns, 1);
    final hist = r.segmentation.classHistogram();
    expect(hist[ClassId.wall], greaterThan(15000));
    // La cota y el texto (trazo fino) no son muros.
    expect(r.segmentation.labelAt(500, 30), 0);
    expect(r.segmentation.labelAt(401, 20), 0);
    // Vectorización hasta Building Model con procedencia clásica y sin confianza inventada.
    final b = const BuildingModelBuilder().build(r.segmentation,
        modelId: 'x', detectorSource: const Source(Provenance.classicDetected));
    expect(b.model.allElements.whereType<Opening>().length, 2);
    expect(b.model.allElements.every((e) => e.confidence == null), isTrue);
    expect(b.issues.where((i) => i.severity == IssueSeverity.error), isEmpty);
    final door = b.model.allElements.whereType<Opening>().firstWhere((o) => o.type == OpeningType.door);
    expect(door.hostWallId, isNotNull);
  });

  test('foto en perspectiva: detecta la hoja, rectifica y detecta igual', () {
    final plan = planImage();
    final (w, h, rgb, truth) = photoOf(plan);
    final gray = GrayImage.fromRgb(w, h, rgb);
    final paper = detectPaperQuad(gray);
    expect(paper.detected, isTrue);
    for (var i = 0; i < 4; i++) {
      expect(paper.quad.points[i].dist(truth.points[i]), lessThan(20), reason: 'esquina $i');
    }
    final (rw, rh, rect) = warpPerspective(w, h, rgb, paper.quad);
    // Sin calibración de cámara la proporción real no es recuperable de una foto: se usa
    // la de los lados del cuadrilátero (criterio de los escáneres de documentos).
    final (tw, th) = truth.outputSize();
    expect((rw / rh - tw / th).abs(), lessThan(0.05));
    final r = const ClassicDetector().detect(GrayImage.fromRgb(rw, rh, rect));
    expect(r.diagnostics.doors, 1, reason: '${r.diagnostics.toJson()}');
    expect(r.diagnostics.windows, 1, reason: '${r.diagnostics.toJson()}');
    expect(r.segmentation.classHistogram()[ClassId.wall], greaterThan(10000));
  });

  test('sin hoja visible devuelve el marco completo para ajuste manual', () {
    final g = GrayImage.filled(200, 150, 128);
    final p = detectPaperQuad(g);
    expect(p.detected, isFalse);
    expect(p.quad.points.last.y, 149);
  });

  test('homografía exacta en los 4 puntos', () {
    final src = [const Pt(10, 20), const Pt(300, 15), const Pt(310, 240), const Pt(5, 250)];
    final dst = [const Pt(0, 0), const Pt(100, 0), const Pt(100, 80), const Pt(0, 80)];
    final hm = homography(src, dst);
    for (var i = 0; i < 4; i++) {
      final p = applyH(hm, src[i].x, src[i].y);
      expect(p.dist(dst[i]), lessThan(1e-6));
    }
    expect(() => homography(List.filled(4, const Pt(1, 1)), dst), throwsStateError);
  });

  test('plano sin muros gruesos: aviso explícito, sin inventar', () {
    final g = GrayImage.filled(300, 200, 255);
    for (var x = 20; x < 280; x++) {
      g.data[100 * 300 + x] = 0; // una línea fina
    }
    final r = const ClassicDetector().detect(g);
    expect(r.diagnostics.warnings.first, contains('trazos gruesos'));
    expect(r.segmentation.classHistogram()[ClassId.wall], 0);
  });
}
