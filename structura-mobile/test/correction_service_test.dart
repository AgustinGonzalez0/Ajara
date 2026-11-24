import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:structura_mobile/data/project_models.dart';
import 'package:structura_mobile/data/project_store.dart';
import 'package:structura_mobile/services/analysis_service.dart';
import 'package:structura_mobile/services/correction_service.dart';
import 'package:structura_model/structura_model.dart';

import 'helpers.dart';

/// Proyecto con un análisis real del motor clásico sobre el plano de prueba.
Future<(ProjectStore, ProjectManifest)> analyzedProject() async {
  final store = ProjectStore(Directory('${tempDir().path}/projects'));
  var p = await store.create(name: 'Corrección');
  final raster = store.resolve(p.id, 'sources/a/raster.png');
  await raster.parent.create(recursive: true);
  await raster.writeAsBytes(realisticPlanPng());
  p = p.copyWith(plans: [
    PlanSource(
        id: 'a',
        originalName: 'plano.png',
        originalFile: 'sources/a/raster.png',
        originalSha256: 'x',
        sourceType: 'png',
        rasterFile: 'sources/a/raster.png',
        rasterSha256: 'x',
        width: 640,
        height: 480,
        dpiSource: 'unknown',
        importedAt: DateTime.now().toUtc())
  ], activePlanId: 'a');
  final rec = await executeClassicAnalysis(AnalysisJob(
      projectDir: store.projectDir(p.id).path,
      rasterPath: raster.path,
      rasterSha256: 'x',
      dpi: null,
      planId: 'a',
      modelJson: const {},
      modelPath: '',
      runId: 'r1'));
  p = await store.save(p.copyWith(analyses: [rec], activeAnalysisId: rec.id, status: ProjectStatus.analyzed));
  return (store, p);
}

void main() {
  test('cambiar puerta ↔ ventana: procedencia, conteos, GLB y evaluación invalidada', () async {
    final (store, p) = await analyzedProject();
    final svc = CorrectionService(store);
    final dir = p.activeAnalysis!.dir;
    final screening = store.resolve(p.id, '$dir/screening.json');
    await screening.writeAsString('{}'); // evaluación vieja
    final glbBefore = await store.resolve(p.id, '$dir/model.glb').readAsBytes();

    final model = await svc.load(p);
    final door = model.allElements.whereType<Opening>().firstWhere((o) => o.type == OpeningType.door);
    final updated = await svc.apply(p, ChangeOpeningType(door.id, OpeningType.window));

    final changed = updated.elementById(door.id) as Opening;
    expect(changed.type, OpeningType.window);
    expect(changed.source.provenance, Provenance.userCorrected);
    expect(changed.source.note, contains('puerta a ventana'));
    expect(await screening.exists(), isFalse);
    final after = await store.load(p.id);
    expect(after.activeAnalysis!.counts['door'] ?? 0, 0);
    expect(after.activeAnalysis!.counts['window'], 2);
    final glbAfter = await store.resolve(p.id, '$dir/model.glb').readAsBytes();
    expect(glbAfter, isNot(equals(glbBefore)));
    final history = await store.history(p.id);
    expect(history.last['action'], 'element_corrected');
    expect((history.last['detail'] as Map)['screening_invalidated'], isTrue);
  });

  test('eliminar un muro suelta sus aberturas y se puede deshacer', () async {
    final (store, p) = await analyzedProject();
    final svc = CorrectionService(store);
    final before = await svc.load(p);
    final host = before.allElements.whereType<Opening>().firstWhere((o) => o.hostWallId != null).hostWallId!;
    final updated = await svc.apply(p, DeleteElement(host));
    expect(updated.elementById(host), isNull);
    expect(updated.allElements.whereType<Opening>().any((o) => o.hostWallId == host), isFalse);
    expect(updated.allElements.length, before.allElements.length - 1);
    expect(updated.validate().where((i) => i.message.contains(host)), isEmpty);

    await svc.save(await store.load(p.id), before); // deshacer
    final restored = await svc.load(await store.load(p.id));
    expect(restored.allElements.length, before.allElements.length);
    expect(restored.elementById(host), isNotNull);
  });
}
