import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:structura_mobile/data/project_models.dart';
import 'package:structura_mobile/data/project_store.dart';

import 'helpers.dart';

void main() {
  test('crear, listar, cargar, guardar y borrar', () async {
    final store = ProjectStore(tempDir());
    final a = await store.create(name: '  Casa Núñez ', description: 'PB', type: BuildingType.residential);
    expect(a.name, 'Casa Núñez');
    final b = await store.create(name: 'Local');
    final list = await store.list();
    expect(list.map((p) => p.id), containsAll([a.id, b.id]));
    final loaded = await store.load(a.id);
    expect(loaded.buildingType, BuildingType.residential);
    final saved = await store.save(loaded.copyWith(name: 'Casa Núñez 2'));
    expect(saved.updatedAt.isBefore(loaded.updatedAt), isFalse);
    expect((await store.load(a.id)).name, 'Casa Núñez 2');
    await store.delete(b.id);
    expect((await store.list()).length, 1);
    expect(() => store.create(name: '   '), throwsArgumentError);
  });

  test('si project.json está corrupto se recupera desde .bak', () async {
    final store = ProjectStore(tempDir());
    final m = await store.create(name: 'Original');
    await store.save(m.copyWith(name: 'Segunda versión'));
    final main = File('${store.projectDir(m.id).path}/project.json');
    main.writeAsStringSync('{"format": "structura-project", "format_ver'); // escritura cortada
    final recovered = await store.load(m.id);
    expect(recovered.name, 'Original'); // la versión anterior completa
  });

  test('proyectos ilegibles o de formato futuro se reportan sin romper la lista', () async {
    final root = tempDir();
    final store = ProjectStore(root);
    await store.create(name: 'Bueno');
    final future = Directory('${root.path}/futuro')..createSync();
    File('${future.path}/project.json').writeAsStringSync(jsonEncode({'format': 'structura-project', 'format_version': 99}));
    Directory('${root.path}/basura').createSync();
    final list = await store.list();
    expect(list.length, 1);
    expect(store.lastIssues.length, 2);
    expect(store.lastIssues.map((i) => i.message).join(), contains('más nuevo'));
  });

  test('historial append-only y tamaño', () async {
    final store = ProjectStore(tempDir());
    final m = await store.create(name: 'H');
    await store.appendHistory(m.id, 'plan_imported', {'plan_id': 'x'});
    final h = await store.history(m.id);
    expect(h.map((e) => e['action']), ['project_created', 'plan_imported']);
    expect(await store.sizeOf(m.id), greaterThan(0));
  });

  test('roundtrip de manifiesto con planos y análisis', () {
    final now = DateTime.utc(2026, 11, 24);
    final m = ProjectManifest(
      id: 'p',
      name: 'n',
      createdAt: now,
      updatedAt: now,
      status: ProjectStatus.analyzed,
      plans: [
        PlanSource(
            id: 'a',
            originalName: 'plano.pdf',
            originalFile: 'sources/a/original.pdf',
            originalSha256: 'x',
            sourceType: 'pdf',
            page: 2,
            rasterFile: 'sources/a/raster.png',
            rasterSha256: 'y',
            width: 10,
            height: 20,
            dpi: 200,
            dpiSource: 'pdf_render',
            importedAt: now)
      ],
      activePlanId: 'a',
      analyses: [
        AnalysisRecord(
            id: 'r', planId: 'a', createdAt: now, status: AnalysisStatus.completed, dir: 'analysis/r', model: const {'id': 'm'}, counts: const {'wall': 3})
      ],
      activeAnalysisId: 'r',
    );
    final back = ProjectManifest.fromJson(jsonDecode(jsonEncode(m.toJson())) as Map<String, Object?>);
    expect(jsonEncode(back.toJson()), jsonEncode(m.toJson()));
    expect(back.activePlan!.page, 2);
    expect(back.activeAnalysis!.isTestModel, isTrue);
  });
}
