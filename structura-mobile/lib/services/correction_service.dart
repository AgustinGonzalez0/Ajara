/// Corrección manual de detecciones por el profesional.
///
/// Cada cambio queda en el Building Model con procedencia `userCorrected` (o se
/// elimina el elemento), se registra en el historial, se regenera el GLB para que lo
/// que se comparte coincida con lo que se ve, y se invalida la evaluación anterior:
/// fue calculada con otra geometría y mostrarla sería engañoso.
library;

import 'dart:convert';

import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_model/structura_model.dart';

import '../data/project_models.dart';
import '../data/project_store.dart';

sealed class Correction {
  final String elementId;
  const Correction(this.elementId);
}

class DeleteElement extends Correction {
  const DeleteElement(super.elementId);
}

class ChangeOpeningType extends Correction {
  final OpeningType to;
  const ChangeOpeningType(super.elementId, this.to);
}

class CorrectionService {
  final ProjectStore store;
  const CorrectionService(this.store);

  AnalysisRecord _active(ProjectManifest p) {
    final a = p.activeAnalysis;
    if (a == null) throw StateError('No hay análisis para corregir.');
    return a;
  }

  Future<BuildingModel> load(ProjectManifest p) async {
    final f = store.resolve(p.id, '${_active(p).dir}/building_model.json');
    return BuildingModel.fromJson(jsonDecode(await f.readAsString()) as Map<String, Object?>);
  }

  /// Aplica la corrección y devuelve el modelo nuevo (ya guardado).
  Future<BuildingModel> apply(ProjectManifest p, Correction c, {DateTime? now}) async {
    final model = await load(p);
    final target = model.elementById(c.elementId);
    if (target == null) throw StateError('No existe el elemento ${c.elementId}.');
    final ts = (now ?? DateTime.now()).toUtc();
    final levels = <Level>[];
    for (final l in model.levels) {
      final out = <BuildingElement>[];
      for (final e in l.elements) {
        if (e.id == c.elementId) {
          switch (c) {
            case DeleteElement():
              continue; // eliminado
            case ChangeOpeningType(:final to):
              if (e is! Opening) throw StateError('${e.id} no es una abertura.');
              out.add(Opening(
                id: e.id,
                source: Source(Provenance.userCorrected,
                    timestamp: ts, note: 'Cambiado de ${_name(e.type)} a ${_name(to)} por el usuario'),
                confidence: null,
                type: to,
                footprint: e.footprint,
                hostWallId: e.hostWallId,
                heightM: e.heightM,
                sillHeightM: e.sillHeightM,
              ));
          }
        } else if (c is DeleteElement && e is Opening && e.hostWallId == c.elementId) {
          // La abertura queda sin muro anfitrión: se conserva, sin referencia colgante.
          out.add(Opening(
              id: e.id,
              source: e.source,
              confidence: e.confidence,
              type: e.type,
              footprint: e.footprint,
              hostWallId: null,
              heightM: e.heightM,
              sillHeightM: e.sillHeightM));
        } else {
          out.add(e);
        }
      }
      levels.add(l.copyWith(elements: out));
    }
    final updated = model.copyWith(levels: levels);
    await save(p, updated, history: {
      'action': c is DeleteElement ? 'delete' : 'change_opening_type',
      'element_id': c.elementId,
      'kind': target.kind.name,
      if (c is ChangeOpeningType) 'to': c.to.name,
    });
    return updated;
  }

  /// Guarda un modelo (también para deshacer): JSON, GLB, conteos y evaluación invalidada.
  Future<void> save(ProjectManifest p, BuildingModel model, {Map<String, Object?> history = const {'action': 'restore'}}) async {
    final a = _active(p);
    await store.writeBytes(p.id, '${a.dir}/building_model.json',
        utf8.encode(const JsonEncoder.withIndent('  ').convert(model.toJson())));
    final mesh = const MeshBuilder().build(model);
    await store.writeBytes(p.id, '${a.dir}/model.glb',
        const GlbWriter().write(mesh, extras: {'structura_model': a.model, 'building_model_id': model.id, 'user_corrected': true}));
    final screening = store.resolve(p.id, '${a.dir}/screening.json');
    final hadScreening = await screening.exists();
    if (hadScreening) await screening.delete();

    final counts = <String, int>{};
    for (final e in model.allElements) {
      counts[e.kind.name] = (counts[e.kind.name] ?? 0) + 1;
    }
    final fresh = await store.load(p.id);
    await store.save(fresh.copyWith(analyses: [
      for (final r in fresh.analyses)
        if (r.id == a.id)
          AnalysisRecord(
              id: r.id,
              planId: r.planId,
              createdAt: r.createdAt,
              status: r.status,
              dir: r.dir,
              model: r.model,
              counts: counts,
              warnings: r.warnings,
              timings: r.timings,
              error: r.error)
        else
          r,
    ]));
    await store.appendHistory(p.id, 'element_corrected', {...history, 'screening_invalidated': hadScreening});
  }

  static String _name(OpeningType t) => t == OpeningType.door ? 'puerta' : 'ventana';
}
