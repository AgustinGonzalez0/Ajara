import 'dart:typed_data';

import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_model/structura_model.dart';
import 'package:test/test.dart';

const det = Source(Provenance.aiDetected, modelId: 'test', modelTrainingData: 'synthetic');

/// Planta sintética: caja de muros de 10 px, puerta en el muro superior,
/// ventana en el inferior, columna y escalera.
SegmentationResult plan({bool withConfidence = true}) {
  const w = 200, h = 150;
  final labels = Uint8List(w * h);
  void fill(int x0, int y0, int x1, int y1, int c) {
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        labels[y * w + x] = c;
      }
    }
  }

  fill(10, 10, 190, 20, ClassId.wall); // superior
  fill(10, 130, 190, 140, ClassId.wall); // inferior
  fill(10, 20, 20, 130, ClassId.wall); // izquierdo
  fill(180, 20, 190, 130, ClassId.wall); // derecho
  fill(60, 10, 90, 20, ClassId.door); // vano en el muro superior
  fill(100, 130, 140, 140, ClassId.window);
  fill(40, 40, 52, 52, ClassId.column);
  fill(120, 50, 160, 110, ClassId.stairs);
  Float32List? conf;
  if (withConfidence) {
    conf = Float32List(w * h)..fillRange(0, w * h, 0.8);
  }
  return SegmentationResult(width: w, height: h, labels: labels, confidence: conf);
}

void main() {
  group('Vectorizer', () {
    test('muros, aberturas con anfitrión, columna y escalera', () {
      final r = const Vectorizer().run(plan(), source: det);
      final walls = r.elements.whereType<Wall>().toList();
      // Superior partido por la puerta (2) + inferior partido por la ventana (2) + laterales (2).
      expect(walls.length, 6);
      expect(walls.every((w) => w.thicknessPx == 10), isTrue);
      final totalWallPx = walls.fold<double>(0, (a, w) => a + w.lengthPx * w.thicknessPx);
      expect(totalWallPx, plan().classHistogram()[ClassId.wall].toDouble()); // cobertura exacta
      final door = r.elements.whereType<Opening>().firstWhere((o) => o.type == OpeningType.door);
      expect(door.footprint.toJson(), [60.0, 10.0, 90.0, 20.0]);
      final host = walls.firstWhere((w) => w.id == door.hostWallId);
      expect(host.start.y, 15.0); // muro superior
      final window = r.elements.whereType<Opening>().firstWhere((o) => o.type == OpeningType.window);
      expect(walls.firstWhere((w) => w.id == window.hostWallId).start.y, 135.0);
      expect(r.elements.whereType<ColumnElement>().single.footprint.toJson(), [40.0, 40.0, 52.0, 52.0]);
      expect(r.elements.whereType<Stairs>().single.footprint.width, 40);
      expect(r.relations.length, 2);
      expect(r.warnings, isEmpty);
      expect(door.confidence, closeTo(0.8, 1e-6));
    });

    test('determinista y sin confianza inventada', () {
      final a = const Vectorizer().run(plan(withConfidence: false), source: det);
      final b = const Vectorizer().run(plan(withConfidence: false), source: det);
      expect(a.elements.map((e) => e.toJson().toString()).toList(), b.elements.map((e) => e.toJson().toString()).toList());
      expect(a.elements.every((e) => e.confidence == null), isTrue);
    });

    test('ruido pequeño se descarta', () {
      final seg = plan();
      seg.labels[75 * 200 + 100] = ClassId.door; // 1 px
      final r = const Vectorizer().run(seg, source: det);
      expect(r.elements.whereType<Opening>().where((o) => o.type == OpeningType.door).length, 1);
    });

    test('dimensiones inválidas', () {
      expect(() => SegmentationResult(width: 2, height: 2, labels: Uint8List(3)), throwsArgumentError);
    });
  });

  group('BuildingModelBuilder + Mesh + GLB', () {
    late BuildingModel model;
    setUp(() {
      final res = const BuildingModelBuilder().build(plan(), modelId: 'bm', detectorSource: det);
      expect(res.issues.where((i) => i.severity == IssueSeverity.error), isEmpty);
      model = res.model;
    });

    test('supuestos de visualización explícitos sin escala', () {
      final a = DisplayAssumptions.forModel(model);
      expect(a.units, 'plan_px');
      expect(a.wallHeight, 180); // 18 × 10 px
      expect(a.toJson()['is_measurement'], false);
      // El Building Model no gana alturas: siguen desconocidas.
      expect(model.allElements.whereType<Wall>().every((w) => w.heightM == null), isTrue);
    });

    test('con escala verificada la malla está en metros', () {
      final m = model.copyWith(
          scale: const PlanScale(pxPerUnit: 50, unit: LengthUnit.m, verified: true, source: Source(Provenance.userCreated)));
      final a = DisplayAssumptions.forModel(m);
      expect(a.units, 'm');
      expect(a.pxToUnits, closeTo(0.02, 1e-12));
    });

    test('normales hacia afuera y triángulos CCW', () {
      final mesh = const MeshBuilder().build(model);
      expect(mesh.parts.keys, unorderedEquals(['wall', 'door', 'window', 'column', 'stairs', 'floor']));
      for (final part in mesh.parts.values) {
        final p = part.positions, n = part.normals;
        for (var t = 0; t < part.indices.length; t += 3) {
          final i0 = part.indices[t] * 3, i1 = part.indices[t + 1] * 3, i2 = part.indices[t + 2] * 3;
          final e1 = [p[i1] - p[i0], p[i1 + 1] - p[i0 + 1], p[i1 + 2] - p[i0 + 2]];
          final e2 = [p[i2] - p[i0], p[i2 + 1] - p[i0 + 1], p[i2 + 2] - p[i0 + 2]];
          final c = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]];
          final dot = c[0] * n[i0] + c[1] * n[i0 + 1] + c[2] * n[i0 + 2];
          expect(dot, greaterThanOrEqualTo(0), reason: '${part.category} triángulo ${t ~/ 3}');
        }
        expect(part.triangleElementIds.length, part.triangleCount);
      }
    });

    test('GLB válido y con supuestos declarados', () {
      final mesh = const MeshBuilder().build(model);
      final bytes = const GlbWriter().write(mesh, extras: {'source_model': 'test'});
      expect(bytes.length % 4, 0);
      final info = GlbInfo.parse(bytes);
      final j = info.json;
      expect((j['asset'] as Map)['version'], '2.0');
      final extras = (j['asset'] as Map)['extras'] as Map;
      expect((extras['display_assumptions'] as Map)['is_measurement'], false);
      final accessors = (j['accessors'] as List).cast<Map>();
      final views = (j['bufferViews'] as List).cast<Map>();
      expect((j['buffers'] as List).first['byteLength'], info.bin.length);
      for (final a in accessors) {
        final v = views[a['bufferView'] as int];
        final size = a['type'] == 'VEC3' ? 12 : 4;
        expect(v['byteLength'], (a['count'] as int) * size);
        expect((v['byteOffset'] as int) % 4, 0);
        expect((v['byteOffset'] as int) + (v['byteLength'] as int), lessThanOrEqualTo(info.bin.length));
      }
      final pos = accessors.where((a) => a.containsKey('min')).toList();
      expect(pos.length, mesh.parts.length);
      // Índices dentro de rango
      final meshes = (j['meshes'] as List).cast<Map>();
      for (final m in meshes) {
        final prim = (m['primitives'] as List).first as Map;
        final count = accessors[(prim['attributes'] as Map)['POSITION'] as int]['count'] as int;
        final idxAcc = accessors[prim['indices'] as int];
        final v = views[idxAcc['bufferView'] as int];
        final idx = Uint32List.sublistView(info.bin, v['byteOffset'] as int, (v['byteOffset'] as int) + (v['byteLength'] as int));
        expect(idx.every((i) => i < count), isTrue);
      }
      expect(() => GlbInfo.parse(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    });
  });
}
