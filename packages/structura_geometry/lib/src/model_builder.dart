/// Ensambla un BuildingModel a partir de una segmentación.
library;

import 'package:structura_model/structura_model.dart';

import 'evidence.dart';
import 'refine.dart';
import 'segmentation.dart';
import 'vectorizer.dart';

class ModelBuildResult {
  final BuildingModel model;
  final VectorizationResult vectorization;
  final List<ModelIssue> issues;

  /// Qué corrigió el afinado geométrico (null si se generó en modo rápido).
  final RefineReport? refinement;
  const ModelBuildResult(this.model, this.vectorization, this.issues, [this.refinement]);
}

class BuildingModelBuilder {
  final Vectorizer vectorizer;

  /// Afinado geométrico (esquinas, alineación, aberturas). Activado por defecto.
  final bool refine;
  final GeometryRefiner refiner;
  const BuildingModelBuilder([this.vectorizer = const Vectorizer(), this.refine = true, this.refiner = const GeometryRefiner()]);

  ModelBuildResult build(
    SegmentationResult seg, {
    required String modelId,
    required Source detectorSource,
    String? imageSha256,
    double? dpi,
    PlanScale? scale,
  }) {
    final v = vectorizer.run(seg, source: detectorSource);
    RefineResult? refined;
    if (refine) {
      refined = refiner.refine(v.elements);
      // Si la imagen muestra que un muro sigue, se prolonga y se afina de nuevo para que
      // las esquinas y los tramos colineales se cierren (ambientes cerrados en planta).
      final ext = extendWallsAlongEvidence(refined.elements, seg);
      if (ext.extended > 0) {
        final second = refiner.refine(ext.elements);
        refined.report
          ..add(second.report)
          ..wallsExtended += ext.extended;
        refined = RefineResult(second.elements, second.relations, refined.report);
      }
    }
    final model = BuildingModel(
      id: modelId,
      plan: PlanReference(widthPx: seg.width, heightPx: seg.height, imageSha256: imageSha256, dpi: dpi),
      scale: scale,
      levels: [Level(id: 'L0', name: null, elements: refined?.elements ?? v.elements)],
      relations: refined?.relations ?? v.relations,
      source: Source(Provenance.derived,
          timestamp: DateTime.now().toUtc(), note: refine ? 'Geometry Engine 0.2 (afinado)' : 'Geometry Engine 0.2 (rápido)'),
    );
    return ModelBuildResult(model, v, model.validate(), refined?.report);
  }
}
