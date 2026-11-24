import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_mobile/data/project_models.dart';
import 'package:structura_mobile/features/model3d/software_renderer.dart';
import 'package:structura_mobile/services/analysis_service.dart';
import 'package:structura_model/structura_model.dart';
import 'package:structura_pipeline/structura_pipeline.dart';

import 'helpers.dart';

AnalysisJob makeJob(Directory dir) {
  final raster = File('${dir.path}/raster.png')..writeAsBytesSync(codedPlanPng());
  return AnalysisJob(
    projectDir: dir.path,
    rasterPath: raster.path,
    rasterSha256: 'sha',
    dpi: 200,
    planId: 'plan1',
    modelJson: oracleDescriptorJson(),
    modelPath: 'oracle.onnx',
    runId: 'run1',
  );
}

void main() {
  test('executeAnalysis guarda labels, confianza, Building Model, GLB y run.json', () async {
    final dir = tempDir();
    final job = makeJob(dir);
    final events = <ProgressEvent>[];
    final rec = await executeAnalysis(job, OracleInferencer(oracleDescriptor()), onProgress: events.add);
    expect(rec.status, AnalysisStatus.completed, reason: rec.error);
    expect(rec.counts['wall'], greaterThanOrEqualTo(4));
    expect(rec.counts['door'], 1);
    expect(rec.counts['window'], 1);
    expect(rec.counts['column'], 1);
    expect(rec.counts['stairs'], 1);
    expect(rec.isTestModel, isTrue);
    expect(rec.warnings.first, contains('prueba'));
    final out = job.outDir;
    final labels = img.decodePng(File('${out.path}/labels.png').readAsBytesSync())!;
    expect((labels.width, labels.height, labels.numChannels), (640, 480, 1));
    expect(labels.getPixel(25, 25).r, 1); // muro
    expect(labels.getPixel(210, 25).r, 2); // puerta
    final model = BuildingModel.fromJson(
        jsonDecode(File('${out.path}/building_model.json').readAsStringSync()) as Map<String, Object?>);
    expect(model.validate().where((i) => i.severity == IssueSeverity.error), isEmpty);
    expect(model.plan.dpi, 200);
    expect(model.allElements.first.source.modelTrainingData, 'synthetic');
    final glb = GlbInfo.parse(File('${out.path}/model.glb').readAsBytesSync());
    expect(((glb.json['asset'] as Map)['extras'] as Map)['structura_model'], isNotNull);
    final run = jsonDecode(File('${out.path}/run.json').readAsStringSync()) as Map;
    expect((run['display_assumptions'] as Map)['is_measurement'], false);
    expect(events.map((e) => e.stageId).toSet(), {'segment', 'vectorize', 'mesh'});
  });

  test('cancelación y error quedan registrados, sin resultados falsos', () async {
    final dir = tempDir();
    final token = CancellationToken()..cancel();
    final cancelled = await executeAnalysis(makeJob(dir), OracleInferencer(oracleDescriptor()), token: token);
    expect(cancelled.status, AnalysisStatus.cancelled);
    expect(Directory('${dir.path}/analysis/run1').existsSync(), isFalse);

    final bad = makeJob(dir);
    File(bad.rasterPath).writeAsBytesSync([1, 2, 3]);
    final failed = await executeAnalysis(bad, OracleInferencer(oracleDescriptor()));
    expect(failed.status, AnalysisStatus.failed);
    expect(failed.error, isNotNull);
  });

  test('InProcessAnalysisRunner con runtime inyectado', () async {
    final dir = tempDir();
    final handle = const InProcessAnalysisRunner(_Rt()).start(makeJob(dir), (_) {});
    final rec = await handle.result;
    expect(rec.status, AnalysisStatus.completed);
  });

  test('renderizador: encuadre, descarte de caras traseras y capas ocultas', () {
    final model = BuildingModel(
      id: 'b',
      plan: const PlanReference(widthPx: 100, heightPx: 100),
      levels: const [
        Level(id: 'L0', elements: [
          Wall(id: 'w', source: Source(Provenance.userCreated), start: Point2(10, 50), end: Point2(90, 50), thicknessPx: 10),
        ])
      ],
      source: const Source(Provenance.derived),
    );
    final mesh = RenderMesh.fromBuildingMesh(const MeshBuilder().build(model, includeFloor: false));
    expect(mesh.triangleCount, 12);
    final cam = mesh.frame();
    final (v, stats) = buildFrame(mesh, cam, const Size(400, 300), {});
    expect(v, isNotNull);
    expect(stats.drawn + stats.culled, 12);
    expect(stats.culled, greaterThanOrEqualTo(4)); // una caja vista desde afuera oculta ~la mitad
    final (_, hidden) = buildFrame(mesh, cam, const Size(400, 300), {'wall'});
    expect(hidden.drawn, 0);
    final (empty, _) = buildFrame(mesh, cam, Size.zero, {});
    expect(empty, isNull);
  });

  test('decodeRaster devuelve RGB intercalado', () {
    final r = decodeRaster(Uint8List.fromList(codedPlanPng(w: 50, h: 40)));
    expect((r.width, r.height, r.rgb.length), (50, 40, 50 * 40 * 3));
  });
}

class _Rt implements InferenceRuntime {
  const _Rt();
  @override
  String get name => 'oracle';
  @override
  Future<TileInferencer> load(ModelDescriptor d, String path) async => OracleInferencer(d);
}
