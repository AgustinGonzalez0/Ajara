/// Corre el motor clásico sobre imágenes PGM (P5, 8 bits) y escribe las etiquetas como PGM.
/// Uso: `dart run tool/classic_cli.dart lista.txt` (cada línea: `entrada.pgm` TAB `salida.pgm`).
/// Sirve para comparar el motor clásico con Vision AI sobre el mismo set de test.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:structura_vision/structura_vision.dart';

GrayImage readPgm(String path) {
  final b = File(path).readAsBytesSync();
  var i = 0;
  String token() {
    while (b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09) {
      i++;
    }
    final s = i;
    while (!(b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09)) {
      i++;
    }
    return String.fromCharCodes(b.sublist(s, i));
  }

  if (token() != 'P5') throw FormatException('$path no es PGM P5');
  final w = int.parse(token()), h = int.parse(token());
  token(); // maxval
  i++;
  return GrayImage(w, h, Uint8List.fromList(b.sublist(i, i + w * h)));
}

void writePgm(String path, int w, int h, Uint8List data) {
  final header = 'P5\n$w $h\n255\n'.codeUnits;
  File(path).writeAsBytesSync([...header, ...data]);
}

void main(List<String> args) {
  final lines = File(args.single).readAsLinesSync().where((l) => l.trim().isNotEmpty);
  final sw = Stopwatch();
  var n = 0;
  for (final l in lines) {
    final parts = l.split('\t');
    final img = readPgm(parts[0]);
    sw.start();
    final r = const ClassicDetector().detectScaled(img);
    sw.stop();
    writePgm(parts[1], r.segmentation.width, r.segmentation.height, r.segmentation.labels);
    n++;
  }
  stdout.writeln('ok $n imágenes, ${(sw.elapsedMilliseconds / (n == 0 ? 1 : n)).toStringAsFixed(0)} ms promedio');
}
