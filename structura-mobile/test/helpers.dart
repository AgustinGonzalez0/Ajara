import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_pipeline/structura_pipeline.dart';

/// Carpeta temporal con caracteres no ASCII (rutas Unicode en Windows/Android).
Directory tempDir() {
  final d = Directory.systemTemp.createTempSync('structura_mobile_');
  final sub = Directory('${d.path}${Platform.pathSeparator}datos año ñ')..createSync();
  addTearDown(() {
    try {
      d.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows puede retener archivos abiertos por un instante.
    }
  });
  return sub;
}

const step = 40;

ModelDescriptor oracleDescriptor({String data = 'synthetic', int tile = 512, int overlap = 64}) =>
    ModelDescriptor.fromJson(oracleDescriptorJson(data: data, tile: tile, overlap: overlap));

Map<String, Object?> oracleDescriptorJson({String data = 'synthetic', int tile = 512, int overlap = 64}) => {
      'format': 'structura-model/1',
      'id': 'oracle_test',
      'version': '0',
      'task': 'semantic_segmentation',
      'file': 'oracle.onnx',
      'input': {
        'shape': [1, 3, tile, tile]
      },
      'classes': ClassId.names,
      'tiling': {'tile': tile, 'overlap': overlap},
      'training': {'data': data, 'production_ready': false},
    };

/// Inferenciador perfecto: lee la clase codificada en el canal R (valor = clase × 40).
class OracleInferencer implements TileInferencer {
  @override
  final ModelDescriptor descriptor;
  final Duration delay;
  OracleInferencer(this.descriptor, {this.delay = Duration.zero});
  @override
  Future<Float32List> infer(Float32List chw) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final t = descriptor.tile, plane = t * t;
    final out = Float32List(6 * plane)..fillRange(0, 6 * plane, -10);
    for (var p = 0; p < plane; p++) {
      out[(chw[p] * 255 / step).round().clamp(0, 5) * plane + p] = 10;
    }
    return out;
  }

  @override
  Future<void> dispose() async {}
}

class OracleRuntime implements InferenceRuntime {
  @override
  String get name => 'oracle';
  @override
  Future<TileInferencer> load(ModelDescriptor d, String path) async => OracleInferencer(d);
}

/// Plano codificado: caja de muros, puerta, ventana, columna y escalera (en px del plano).
Uint8List codedPlanPng({int w = 640, int h = 480}) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  void fill(int x0, int y0, int x1, int y1, int c) {
    for (var y = y0.clamp(0, h); y < y1.clamp(0, h); y++) {
      for (var x = x0.clamp(0, w); x < x1.clamp(0, w); x++) {
        image.setPixelRgb(x, y, c * step, 0, 0);
      }
    }
  }

  fill(20, 20, w - 20, 32, 1);
  fill(20, h - 32, w - 20, h - 20, 1);
  fill(20, 32, 32, h - 32, 1);
  fill(w - 32, 32, w - 20, h - 32, 1);
  fill(200, 20, 260, 32, 2);
  fill(300, h - 32, 380, h - 20, 3);
  fill(80, 80, 96, 96, 4);
  fill(450, 200, 520, 380, 5);
  return img.encodePng(image);
}

/// Plano realista (muros negros de 12 px sobre blanco, vano, ventana y columna) para el motor clásico.
Uint8List realisticPlanPng({int w = 640, int h = 480}) {
  final image = img.Image(width: w, height: h, numChannels: 3)..clear(img.ColorRgb8(255, 255, 255));
  void fill(int x0, int y0, int x1, int y1, [int v = 0]) =>
      img.fillRect(image, x1: x0, y1: y0, x2: x1 - 1, y2: y1 - 1, color: img.ColorRgb8(v, v, v));
  fill(40, 40, w - 40, 52);
  fill(40, h - 52, w - 40, h - 40);
  fill(40, 40, 52, h - 40);
  fill(w - 52, 40, w - 40, h - 40);
  fill(330, 52, 342, h - 52);
  fill(330, 120, 342, 190, 255); // vano de puerta
  fill(120, 40, 220, 52, 255); // ventana
  fill(120, 42, 220, 43);
  fill(120, 49, 220, 50);
  fill(480, 300, 504, 324); // columna aislada
  return img.encodePng(image);
}
