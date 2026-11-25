import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_pipeline/structura_pipeline.dart';
import 'package:test/test.dart';

const step = 40; // clase codificada en el canal R (igual que structura-core/tests/test_tiling.py)

ModelDescriptor descriptor({String data = 'synthetic', int tile = 512, int overlap = 64}) => ModelDescriptor.fromJson({
      'format': 'structura-model/1',
      'id': 'oracle',
      'version': '0',
      'task': 'semantic_segmentation',
      'file': 'x.onnx',
      'input': {
        'shape': [1, 3, tile, tile]
      },
      'classes': ClassId.names,
      'tiling': {'tile': tile, 'overlap': overlap},
      'training': {'data': data, 'production_ready': true},
    });

/// "Modelo" perfecto: lee la clase del canal R y devuelve logits one-hot.
class OracleInferencer implements TileInferencer {
  @override
  final ModelDescriptor descriptor;
  int calls = 0;
  OracleInferencer(this.descriptor);
  @override
  Future<Float32List> infer(Float32List chw) async {
    calls++;
    final t = descriptor.tile, plane = t * t;
    final out = Float32List(6 * plane)..fillRange(0, 6 * plane, -10);
    for (var p = 0; p < plane; p++) {
      final c = (chw[p] * 255 / step).round().clamp(0, 5);
      out[c * plane + p] = 10;
    }
    return out;
  }

  @override
  Future<void> dispose() async {}
}

(PlanRaster, Uint8List) codedRaster(int w, int h, int seed) {
  final labels = Uint8List(w * h);
  var s = seed;
  int rnd() => s = (s * 1103515245 + 12345) & 0x7fffffff;
  final bw = w ~/ 8 + 1;
  final blocks = List.generate((h ~/ 8 + 1) * bw, (_) => rnd() % 6);
  final rgb = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = blocks[(y ~/ 8) * bw + x ~/ 8];
      labels[y * w + x] = c;
      rgb[(y * w + x) * 3] = c * step;
    }
  }
  return (PlanRaster(w, h, rgb), labels);
}

void main() {
  group('tiling', () {
    test('TTA (4 espejos): mismo resultado que sin TTA con un modelo equivariante, 4× inferencias', () async {
      for (final (w, h) in [(300, 200), (700, 513), (1100, 900)]) {
        final (raster, labels) = codedRaster(w, h, w * 3 + h);
        final plain = OracleInferencer(descriptor());
        final tta = OracleInferencer(descriptor());
        final a = await const TiledSegmenter().segment(raster, plain);
        final b = await const TiledSegmenter(tta: true).segment(raster, tta);
        expect(b.labels, labels, reason: '$w x $h');
        expect(b.labels, a.labels);
        expect(tta.calls, 4 * plain.calls);
      }
    });

    test('rejilla igual a Python', () {
      expect(tileStarts(300, 512, 448), [0]);
      expect(tileStarts(512, 512, 448), [0]);
      expect(tileStarts(513, 512, 448), [0, 1]);
      expect(tileStarts(3100, 512, 448), [0, 448, 896, 1344, 1792, 2240, 2588]);
    });

    test('recomposición exacta por bandas para cualquier tamaño', () async {
      for (final (w, h) in [(200, 300), (512, 512), (513, 700), (1500, 1100), (700, 2100)]) {
        final (raster, labels) = codedRaster(w, h, w + h);
        final inf = OracleInferencer(descriptor());
        final seg = await const TiledSegmenter().segment(raster, inf);
        expect(seg.labels, labels, reason: '$w x $h');
        expect(seg.confidence!.every((v) => v > 0.99), isTrue);
        expect(inf.calls, tileStarts(w, 512, 448).length * tileStarts(h, 512, 448).length);
      }
    });

    test('tiles pequeños con overlap (bandas múltiples)', () async {
      final (raster, labels) = codedRaster(301, 257, 3);
      final seg = await const TiledSegmenter().segment(raster, OracleInferencer(descriptor(tile: 64, overlap: 16)));
      expect(seg.labels, labels);
    });

    test('cancelación', () async {
      final (raster, _) = codedRaster(1500, 1500, 1);
      final token = CancellationToken();
      final future = const TiledSegmenter().segment(raster, OracleInferencer(descriptor()), token: token,
          onTile: (done, _) {
        if (done == 2) token.cancel();
      });
      expect(future, throwsA(isA<CancelledException>()));
    });
  });

  group('ModelDescriptor', () {
    test('modelo sintético nunca es apto aunque diga production_ready', () {
      final d = descriptor(data: 'synthetic');
      expect(d.productionReady, isFalse);
      expect(d.isTestModel, isTrue);
      expect(d.trustLabel, contains('prueba'));
    });

    test('lee el descriptor real exportado por structura-core', () {
      final f = File('../../data/runs/synthetic_test_model/vision_ai_synthetic_test.model.json');
      if (!f.existsSync()) {
        markTestSkipped('modelo de prueba no generado');
        return;
      }
      final d = ModelDescriptor.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, Object?>);
      expect(d.trainingData, 'synthetic');
      expect(d.isTestModel, isTrue);
      expect(d.inputShape, [1, 3, 512, 512]);
      expect(d.classes.length, 6);
    });

    test('formato desconocido', () {
      expect(() => ModelDescriptor.fromJson({'format': 'otro'}), throwsFormatException);
    });
  });

  group('AnalysisPipeline', () {
    test('etapas, progreso, Building Model y malla', () async {
      // Planta codificada: caja de muros (clase 1) y una puerta (clase 2).
      const w = 600, h = 400;
      final rgb = Uint8List(w * h * 3);
      void fill(int x0, int y0, int x1, int y1, int c) {
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            rgb[(y * w + x) * 3] = c * step;
          }
        }
      }

      fill(20, 20, 580, 32, 1);
      fill(20, 368, 580, 380, 1);
      fill(20, 32, 32, 368, 1);
      fill(568, 32, 580, 368, 1);
      fill(200, 20, 260, 32, 2);
      final events = <ProgressEvent>[];
      final r = await const AnalysisPipeline().run(
          raster: PlanRaster(w, h, rgb),
          inferencer: OracleInferencer(descriptor()),
          buildingModelId: 'bm',
          onProgress: events.add);
      expect(r.elementCounts['wall'], 5);
      expect(r.elementCounts['door'], 1);
      expect(r.mesh.triangleCount, greaterThan(0));
      expect(r.timings.map((t) => t.stageId), ['segment', 'vectorize', 'mesh']);
      expect(events.map((e) => e.stageId).toSet(), {'segment', 'vectorize', 'mesh'});
      expect(events.last.overall, 1.0);
      expect(r.warnings.first, contains('prueba')); // el pipeline avisa que es un modelo de prueba
      final door = r.build.model.allElements.firstWhere((e) => e.kind.name == 'door');
      expect(door.source.modelTrainingData, 'synthetic');
    });

    test('error del runtime se reporta como StageFailure', () async {
      final bad = _FailingInferencer(descriptor());
      expect(
          const AnalysisPipeline().run(raster: PlanRaster(10, 10, Uint8List(300)), inferencer: bad, buildingModelId: 'x'),
          throwsA(isA<StageFailure>().having((e) => e.stageId, 'stage', 'segment')));
    });
  });
}

class _FailingInferencer extends OracleInferencer {
  _FailingInferencer(super.descriptor);
  @override
  Future<Float32List> infer(Float32List chw) async => throw StateError('runtime caído');
}
