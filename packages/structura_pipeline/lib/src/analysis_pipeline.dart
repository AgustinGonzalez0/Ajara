/// Pipeline de análisis por etapas: segmentación → Building Model → malla 3D.
///
/// Cada etapa informa progreso, respeta la cancelación y, si falla, lanza
/// [StageFailure] con el id de la etapa. No hay resultados simulados: si no hay
/// modelo cargado, la etapa de segmentación no puede ejecutarse.
library;

import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_model/structura_model.dart';

import 'contracts.dart';
import 'tiled_segmenter.dart';

class StageTiming {
  final String stageId;
  final Duration duration;
  const StageTiming(this.stageId, this.duration);
  Map<String, Object?> toJson() => {'stage': stageId, 'ms': duration.inMilliseconds};
}

class AnalysisResult {
  final ModelDescriptor model;
  final SegmentationResult segmentation;
  final ModelBuildResult build;
  final BuildingMesh mesh;
  final List<StageTiming> timings;
  final List<String> warnings;
  const AnalysisResult(this.model, this.segmentation, this.build, this.mesh, this.timings, this.warnings);

  Map<String, int> get elementCounts {
    final counts = <String, int>{};
    for (final e in build.model.allElements) {
      counts[e.kind.name] = (counts[e.kind.name] ?? 0) + 1;
    }
    return counts;
  }
}

class AnalysisPipeline {
  static const stages = [
    ('segment', 'Segmentación (Vision AI)'),
    ('vectorize', 'Vectorización y Building Model'),
    ('mesh', 'Geometría 3D'),
  ];

  final TiledSegmenter segmenter;
  final BuildingModelBuilder modelBuilder;
  final MeshBuilder meshBuilder;
  const AnalysisPipeline({
    this.segmenter = const TiledSegmenter(),
    this.modelBuilder = const BuildingModelBuilder(),
    this.meshBuilder = const MeshBuilder(),
  });

  Future<AnalysisResult> run({
    required PlanRaster raster,
    required TileInferencer inferencer,
    required String buildingModelId,
    String? imageSha256,
    double? dpi,
    PlanScale? scale,
    CancellationToken? token,
    ProgressSink? onProgress,
  }) async {
    final t = token ?? CancellationToken();
    final timings = <StageTiming>[];
    final warnings = <String>[];
    final d = inferencer.descriptor;
    if (d.isTestModel) warnings.add(d.trustLabel);
    void report(int i, double? f, [String? msg]) =>
        onProgress?.call(ProgressEvent(stages[i].$1, stages[i].$2, i, stages.length, f, msg));

    Future<T> stage<T>(int i, Future<T> Function() body) async {
      t.throwIfCancelled();
      report(i, 0);
      final sw = Stopwatch()..start();
      try {
        final r = await body();
        timings.add(StageTiming(stages[i].$1, sw.elapsed));
        report(i, 1);
        return r;
      } on CancelledException {
        rethrow;
      } on StageFailure {
        rethrow;
      } catch (e) {
        throw StageFailure(stages[i].$1, 'falló', e);
      }
    }

    final seg = await stage(0, () => segmenter.segment(raster, inferencer, token: t,
        onTile: (done, total) => report(0, done / total, 'Tile $done de $total')));
    final build = await stage(1, () async {
      final source = Source(Provenance.aiDetected,
          modelId: d.id, modelVersion: d.version, modelTrainingData: d.trainingData, timestamp: DateTime.now().toUtc());
      return modelBuilder.build(seg,
          modelId: buildingModelId, detectorSource: source, imageSha256: imageSha256, dpi: dpi, scale: scale);
    });
    warnings.addAll(build.vectorization.warnings);
    warnings.addAll(build.issues.map((i) => i.toString()));
    if (build.model.allElements.isEmpty) warnings.add('No se detectaron elementos en el plano.');
    final mesh = await stage(2, () async => meshBuilder.build(build.model));
    return AnalysisResult(d, seg, build, mesh, timings, warnings);
  }
}
