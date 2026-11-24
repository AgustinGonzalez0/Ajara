/// Ensambla un BuildingModel a partir de una segmentación.
library;

import 'package:structura_model/structura_model.dart';

import 'segmentation.dart';
import 'vectorizer.dart';

class ModelBuildResult {
  final BuildingModel model;
  final VectorizationResult vectorization;
  final List<ModelIssue> issues;
  const ModelBuildResult(this.model, this.vectorization, this.issues);
}

class BuildingModelBuilder {
  final Vectorizer vectorizer;
  const BuildingModelBuilder([this.vectorizer = const Vectorizer()]);

  ModelBuildResult build(
    SegmentationResult seg, {
    required String modelId,
    required Source detectorSource,
    String? imageSha256,
    double? dpi,
    PlanScale? scale,
  }) {
    final v = vectorizer.run(seg, source: detectorSource);
    final model = BuildingModel(
      id: modelId,
      plan: PlanReference(widthPx: seg.width, heightPx: seg.height, imageSha256: imageSha256, dpi: dpi),
      scale: scale,
      levels: [Level(id: 'L0', name: null, elements: v.elements)],
      relations: v.relations,
      source: Source(Provenance.derived, timestamp: DateTime.now().toUtc(), note: 'Geometry Engine 0.1'),
    );
    return ModelBuildResult(model, v, model.validate());
  }
}
