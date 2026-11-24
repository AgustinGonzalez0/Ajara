/// Calibración de escala y evaluación preliminar (screening) de un proyecto.
library;

import 'dart:convert';

import 'package:structura_model/structura_model.dart';
import 'package:structura_sim/structura_sim.dart';

import '../data/project_models.dart';
import '../data/project_store.dart';

class ScreeningService {
  final ProjectStore store;
  const ScreeningService(this.store);

  String _modelRel(AnalysisRecord a) => '${a.dir}/building_model.json';
  String _reportRel(AnalysisRecord a) => '${a.dir}/screening.json';

  AnalysisRecord _active(ProjectManifest p) {
    final a = p.activeAnalysis;
    if (a == null) throw const SimulationException('Primero ejecutá el análisis del plano.');
    return a;
  }

  Future<BuildingModel> loadModel(ProjectManifest p) async {
    final f = store.resolve(p.id, _modelRel(_active(p)));
    return BuildingModel.fromJson(jsonDecode(await f.readAsString()) as Map<String, Object?>);
  }

  /// Fija la escala a partir de una medida real conocida: el largo total (exterior)
  /// del muro [wallId]. Queda registrada como dato verificado por el usuario.
  Future<BuildingModel> calibrate(ProjectManifest p, String wallId, double meters) async {
    if (!(meters > 0 && meters < 1000)) throw const SimulationException('Ingresá un largo válido en metros.');
    final model = await loadModel(p);
    final wall = model.elementById(wallId);
    if (wall is! Wall) throw SimulationException('El elemento $wallId no es un muro.');
    final b = wall.bounds;
    final px = b.width > b.height ? b.width : b.height;
    final scale = PlanScale(
      pxPerUnit: px / meters,
      unit: LengthUnit.m,
      verified: true,
      source: Source(Provenance.userCreated,
          timestamp: DateTime.now().toUtc(), note: 'Calibrado con el muro $wallId = ${meters.toStringAsFixed(3)} m'),
    );
    final updated = model.copyWith(scale: scale);
    await store.writeBytes(p.id, _modelRel(_active(p)),
        utf8.encode(const JsonEncoder.withIndent('  ').convert(updated.toJson())));
    await store.appendHistory(p.id, 'scale_calibrated', {'wall_id': wallId, 'meters': meters, 'px_per_m': scale.pxPerUnit});
    return updated;
  }

  Future<ScreeningReport> evaluate(ProjectManifest p, BuildingInput building,
      {required SeismicInput seismic, TsunamiInput? tsunami, WindInput? wind}) async {
    final model = await loadModel(p);
    final report = runScreening(model, building, seismic: seismic, tsunami: tsunami, wind: wind);
    await store.writeBytes(
        p.id, _reportRel(_active(p)), utf8.encode(const JsonEncoder.withIndent('  ').convert(report.toJson())));
    await store.appendHistory(p.id, 'screening_run', {
      'results': {for (final r in report.results) r.hazard.name: r.overall.name},
      'floors': building.floors,
      'material': building.material.name,
    });
    return report;
  }

  /// Último informe guardado (JSON) o null.
  Future<Map<String, Object?>?> lastReport(ProjectManifest p) async {
    final a = p.activeAnalysis;
    if (a == null) return null;
    final f = store.resolve(p.id, _reportRel(a));
    if (!await f.exists()) return null;
    return (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
  }
}
