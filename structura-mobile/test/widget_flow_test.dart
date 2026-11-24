import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:structura_mobile/app/app.dart';
import 'package:structura_mobile/app/providers.dart';
import 'package:structura_mobile/data/project_models.dart';
import 'package:structura_mobile/data/project_store.dart';
import 'package:structura_mobile/features/import/import_screen.dart';
import 'package:structura_mobile/services/analysis_service.dart';
import 'package:structura_mobile/services/model_registry.dart';

import 'helpers.dart';

/// Avanza el reloj de la UI y deja correr E/S real (archivos, isolates).
/// Cada operación de archivo encadenada necesita un ciclo runAsync + pump.
Future<void> settle(WidgetTester t, {int rounds = 12}) async {
  for (var i = 0; i < rounds * 4; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// Avanza hasta que [finder] aparezca (E/S e isolates reales) o se agote el tiempo.
Future<void> settleUntil(WidgetTester t, Finder finder, {Duration timeout = const Duration(seconds: 60)}) async {
  final sw = Stopwatch()..start();
  while (finder.evaluate().isEmpty && sw.elapsed < timeout) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 50));
  }
}

class Harness {
  final Directory root;
  final ProjectStore store;
  Harness(this.root) : store = ProjectStore(Directory('${root.path}/projects'));

  Future<Widget> app({bool onboardingDone = false, File? pick}) async {
    SharedPreferences.setMockInitialValues({'onboarding_done': onboardingDone});
    final prefs = await SharedPreferences.getInstance();
    final model = InstalledModel(oracleDescriptor(), '${root.path}/oracle.onnx', 1234, true, 'bundled');
    return ProviderScope(
      overrides: [
        appDirsProvider.overrideWithValue(AppDirs(projects: store.root, models: Directory('${root.path}/models'))),
        prefsProvider.overrideWithValue(prefs),
        installedModelsProvider.overrideWith((ref) async => [model]),
        if (pick != null) filePickProvider.overrideWithValue(() async => PickedFile(pick, 'Planta baja.png')),
      ],
      child: const StructuraApp(),
    );
  }
}

void phone(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 2400);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
}

void main() {
  testWidgets('primer inicio: splash → onboarding → dashboard vacío → crear proyecto', (t) async {
    phone(t);
    final h = Harness(tempDir());
    await t.pumpWidget(await h.app());
    expect(find.text('STRUCTURA'), findsOneWidget);
    await settle(t, rounds: 20);
    expect(find.text('Importá tus planos'), findsOneWidget);
    await t.tap(find.text('Omitir'));
    await settle(t);
    expect(find.text('Proyectos'), findsWidgets);
    expect(find.text('Todavía no hay proyectos'), findsOneWidget);

    await t.tap(find.text('Nuevo proyecto'));
    await settle(t);
    await t.enterText(find.byKey(const Key('project_name')), 'Casa Núñez');
    await t.tap(find.text('Residencial'));
    await t.tap(find.byKey(const Key('create_only')));
    await settle(t);
    expect(find.text('Casa Núñez'), findsOneWidget);
    expect(find.text('Importar plano'), findsOneWidget);
    expect(find.text('BORRADOR'), findsOneWidget);

    // Persistencia real en disco
    final saved = await t.runAsync(() => h.store.list());
    expect(saved!.single.buildingType, BuildingType.residential);

    await t.pageBack();
    await settle(t);
    expect(find.text('Casa Núñez'), findsOneWidget); // aparece en recientes
  });

  testWidgets('flujo completo: importar → análisis clásico sin IA → escala → evaluación → simulación 3D', (t) async {
    phone(t);
    final root = tempDir();
    final png = File('${root.path}/plano.png')..writeAsBytesSync(realisticPlanPng());
    final h = Harness(root);
    await t.pumpWidget(await h.app(onboardingDone: true, pick: png));
    await settle(t, rounds: 20);
    await t.tap(find.text('Importar plano'));
    await settle(t);
    await t.enterText(find.byKey(const Key('project_name')), 'Depto 3B');
    await t.tap(find.byKey(const Key('create_and_import')));
    await settle(t);
    await t.tap(find.byKey(const Key('pick_file')));
    await settle(t);
    expect(find.textContaining('Tipo detectado: PNG'), findsOneWidget);
    await t.tap(find.byKey(const Key('do_import')));
    await settle(t, rounds: 20);
    expect(find.text('Depto 3B'), findsOneWidget);
    expect(find.textContaining('640×480 px'), findsOneWidget);

    // Análisis con el motor clásico (sin IA): funciona en cualquier plataforma.
    await t.tap(find.text('Analizar'));
    await settle(t);
    expect(find.text('Clásico — sin IA'), findsOneWidget);
    expect(find.text('RECOMENDADO'), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('run_analysis')));
    await t.tap(find.byKey(const Key('run_analysis')));
    await settleUntil(t, find.text('Análisis completado y guardado en el proyecto.'));
    expect(find.text('Análisis completado y guardado en el proyecto.'), findsOneWidget);
    final saved = await t.runAsync(() => h.store.list());
    final rec = saved!.single.activeAnalysis!;
    expect(rec.model['engine'], 'classic');
    expect(rec.counts['wall'], greaterThanOrEqualTo(5));
    expect(rec.counts['door'], 1);
    expect(rec.counts['window'], 1);
    expect(rec.counts['column'], 1);

    // Evaluación preliminar: primero la escala verificada.
    await t.pageBack();
    await settle(t);
    await t.scrollUntilVisible(find.text('Evaluar'), 300, scrollable: find.byType(Scrollable).last);
    await t.pump();
    await t.tap(find.text('Evaluar'));
    await settle(t, rounds: 20);
    expect(find.textContaining('No determina que la estructura sea segura'), findsOneWidget);
    expect(find.byKey(const Key('run_screening')), findsNothing); // sin escala no se evalúa
    await t.tap(find.byKey(const Key('scale_wall')));
    await settle(t, rounds: 3);
    await t.tap(find.textContaining('w0001').last);
    await settle(t, rounds: 3);
    await t.enterText(find.byKey(const Key('scale_meters')), '11,2');
    await t.tap(find.byKey(const Key('save_scale')));
    await settle(t, rounds: 20);
    expect(find.textContaining('Escala verificada'), findsOneWidget);
    await t.scrollUntilVisible(find.byKey(const Key('run_screening')), 300, scrollable: find.byType(Scrollable).last);
    await t.pump();
    await t.tap(find.byKey(const Key('run_screening')));
    await settle(t, rounds: 20);
    await t.scrollUntilVisible(find.text('Sismo / terremoto'), 300, scrollable: find.byType(Scrollable).last);
    expect(find.text('Sismo / terremoto'), findsOneWidget);
    expect(find.text('Corte basal dirección X (demanda/capacidad)'), findsOneWidget);
    final project = (await t.runAsync(() => h.store.list()))!.single;
    final report = File('${h.store.projectDir(project.id).path}/${project.activeAnalysis!.dir}/screening.json');
    expect(await t.runAsync(() => report.exists()), isTrue);

    await t.scrollUntilVisible(find.byKey(const Key('view3d_seismic')), 200, scrollable: find.byType(Scrollable).last);
    await t.pump();
    await t.tap(find.byKey(const Key('view3d_seismic')));
    await settle(t, rounds: 20);
    expect(find.text('Simulación 3D'), findsOneWidget);
    expect(find.text('SIMULACIÓN PRELIMINAR'), findsOneWidget);
    expect(find.textContaining('Altura total declarada'), findsOneWidget);
  });

  testWidgets('proyecto analizado: editor 2D y modelo 3D desde disco (sin re-procesar)', (t) async {
    final root = tempDir();
    final h = Harness(root);
    // Prepara un proyecto con un análisis real ejecutado por el pipeline (inferenciador oráculo).
    final id = await t.runAsync(() async {
      var p = await h.store.create(name: 'Analizado');
      final raster = h.store.resolve(p.id, 'sources/a/raster.png');
      await raster.parent.create(recursive: true);
      await raster.writeAsBytes(codedPlanPng());
      final now = DateTime.now().toUtc();
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
            importedAt: now)
      ], activePlanId: 'a');
      final job = AnalysisJob(
          projectDir: h.store.projectDir(p.id).path,
          rasterPath: raster.path,
          rasterSha256: 'x',
          dpi: null,
          planId: 'a',
          modelJson: oracleDescriptorJson(),
          modelPath: '',
          runId: 'r1');
      final rec = await executeAnalysis(job, OracleInferencer(oracleDescriptor()));
      await h.store.save(p.copyWith(analyses: [rec], activeAnalysisId: rec.id, status: ProjectStatus.analyzed));
      return p.id;
    });
    // Tablet: rail lateral y paneles laterales.
    t.view.physicalSize = const Size(2560, 1600);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(await h.app(onboardingDone: true));
    await settle(t, rounds: 20);
    expect(find.byType(NavigationRail), findsOneWidget);
    await t.tap(find.text('Analizado'));
    await settle(t);
    expect(find.text('ANALIZADO'), findsOneWidget);
    expect(find.text('RESULTADO NO VALIDADO CON PLANOS REALES'), findsOneWidget);

    await t.ensureVisible(find.text('Abrir editor 2D'));
    await t.pump();
    await t.tap(find.text('Abrir editor 2D'));
    await settle(t, rounds: 20);
    expect(find.text('Segmentación (IA)'), findsOneWidget);
    expect(find.textContaining('Muros · w0001'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Corrección manual'), 300, scrollable: find.byType(Scrollable).last);
    expect(find.text('Corrección manual'), findsOneWidget);
    await t.pageBack();
    await settle(t);

    await t.ensureVisible(find.text('Ver modelo 3D'));
    await t.pump();
    await t.tap(find.text('Ver modelo 3D'));
    await settle(t, rounds: 20);
    expect(find.textContaining('Sin escala verificada'), findsOneWidget);
    expect(find.text('UNIDADES: PX · ALTURA SUPUESTA'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Triángulos'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('Triángulos'), findsOneWidget);
    await t.tap(find.text('Planta'));
    await t.pump();
    expect(id, isNotNull);
  });

  testWidgets('configuración muestra capacidades reales y procedencia del modelo', (t) async {
    phone(t);
    final h = Harness(tempDir());
    await t.pumpWidget(await h.app(onboardingDone: true));
    await settle(t, rounds: 20);
    await t.tap(find.text('Configuración').last);
    await settle(t);
    expect(find.text('Runtime de IA (ONNX Runtime)'), findsOneWidget);
    expect(find.text('NO DISPONIBLE'), findsNWidgets(2)); // en el host de tests no hay Android
    await t.scrollUntilVisible(find.text('PRUEBA'), 200);
    expect(find.text('DATOS: SYNTHETIC'), findsOneWidget);
  });
}
