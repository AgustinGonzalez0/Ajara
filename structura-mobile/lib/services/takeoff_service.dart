/// Cómputo métrico preliminar y exportación DXF del plano detectado (en el dispositivo).
library;

import 'dart:convert';

import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_model/structura_model.dart';
import 'package:structura_sim/structura_sim.dart' show SimulationException;

import '../data/project_models.dart';
import '../data/project_store.dart';

const mimeCsv = 'text/csv';
const mimeDxf = 'image/vnd.dxf';

/// Nombre de archivo seguro a partir del nombre del proyecto.
String safeFileStem(String name) {
  const map = {'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ñ': 'n', 'ü': 'u'};
  final lower = name.toLowerCase().split('').map((c) => map[c] ?? c).join();
  final s = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  return s.isEmpty ? 'plano' : (s.length > 40 ? s.substring(0, 40) : s);
}

class TakeoffService {
  final ProjectStore store;
  const TakeoffService(this.store);

  AnalysisRecord _active(ProjectManifest p) {
    final a = p.activeAnalysis;
    if (a == null) throw const SimulationException('Primero generá el modelo del plano.');
    return a;
  }

  Future<BuildingModel> _model(ProjectManifest p) async {
    final f = store.resolve(p.id, '${_active(p).dir}/building_model.json');
    return BuildingModel.fromJson(jsonDecode(await f.readAsString()) as Map<String, Object?>);
  }

  /// Alturas usadas la última vez en este proyecto (o las típicas).
  Future<TakeoffParams> lastParams(ProjectManifest p) async {
    final a = p.activeAnalysis;
    if (a == null) return const TakeoffParams();
    final f = store.resolve(p.id, '${a.dir}/takeoff.json');
    if (!await f.exists()) return const TakeoffParams();
    final j = ((jsonDecode(await f.readAsString()) as Map)['params'] as Map?)?.cast<String, Object?>() ?? const {};
    double d(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    return TakeoffParams(
        wallHeightM: d('wall_height_m', 2.60), doorHeightM: d('door_height_m', 2.05), windowHeightM: d('window_height_m', 1.10));
  }

  /// Calcula y guarda el cómputo (requiere escala verificada).
  Future<(QuantityTakeoff, BuildingModel)> compute(ProjectManifest p, {TakeoffParams? params}) async {
    final model = await _model(p);
    if (!model.hasVerifiedScale) throw const SimulationException('Falta la escala: marcá una medida conocida del plano.');
    final t = computeTakeoff(model, params: params ?? await lastParams(p));
    await store.writeBytes(
        p.id, '${_active(p).dir}/takeoff.json', utf8.encode(const JsonEncoder.withIndent('  ').convert(t.toJson())));
    return (t, model);
  }

  /// Planilla CSV del cómputo; devuelve la ruta absoluta.
  Future<String> exportCsv(ProjectManifest p, QuantityTakeoff t) async {
    final rel = '${_active(p).dir}/computo_${safeFileStem(p.name)}.csv';
    await store.writeBytes(p.id, rel, utf8.encode(t.toCsv(project: p.name)));
    await store.appendHistory(p.id, 'takeoff_exported', {'file': rel});
    return store.resolve(p.id, rel).path;
  }

  /// DXF del plano detectado (en metros si hay escala); devuelve (ruta, en metros).
  Future<(String, bool)> exportDxf(ProjectManifest p) async {
    final model = await _model(p);
    final d = buildDxf(model, title: 'STRUCTURA AI - ${p.name}');
    final rel = '${_active(p).dir}/${safeFileStem(p.name)}.dxf';
    await store.writeBytes(p.id, rel, ascii.encode(d.content));
    await store.appendHistory(p.id, 'dxf_exported', {'file': rel, 'meters': d.inMeters, 'entities': d.entities});
    return (store.resolve(p.id, rel).path, d.inMeters);
  }
}
