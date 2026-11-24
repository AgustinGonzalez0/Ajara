// Sonda de diagnóstico (no forma parte del paquete): genera la foto sintética de los
// tests, la rectifica, detecta y guarda imágenes PGM para inspección visual.
import 'dart:io';

import 'package:structura_vision/structura_vision.dart';

import '../test/vision_test.dart' as t;

void main() {
  final plan = t.planImage();
  final (w, h, rgb, truth) = t.photoOf(plan);
  final gray = GrayImage.fromRgb(w, h, rgb);
  final paper = detectPaperQuad(gray);
  print('quad ${paper.quad.points} truth ${truth.points}');
  final (rw, rh, rect) = warpPerspective(w, h, rgb, paper.quad);
  final r = const ClassicDetector().detect(GrayImage.fromRgb(rw, rh, rect));
  print('out $rw x $rh ${r.diagnostics.toJson()}');
  final g = GrayImage.fromRgb(rw, rh, rect);
  File('tool/rect.pgm').writeAsBytesSync([...'P5 $rw $rh 255\n'.codeUnits, ...g.data]);
  File('tool/lab.pgm')
      .writeAsBytesSync([...'P5 $rw $rh 255\n'.codeUnits, ...r.segmentation.labels.map((v) => v * 50)]);
}
