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
import 'package:structura_mobile/features/photo/photo_screen.dart';
import 'package:structura_mobile/services/analysis_service.dart';
import 'package:structura_mobile/services/model_registry.dart';
import 'package:structura_mobile/services/share_service.dart';

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

/// Registra lo que se compartiría (la hoja de compartir del sistema no existe en tests).
class FakeSharer implements FileSharer {
  final shared = <(String path, String mime)>[];
  @override
  Future<void> shareFile(String path, {required String mimeType, String? subject, String? text}) async =>
      shared.add((path, mimeType));
}

class Harness {
  final Directory root;
  final ProjectStore store;
  final sharer = FakeSharer();
  Harness(this.root) : store = ProjectStore(Directory('${root.path}/projects'));

  Future<Widget> app({bool onboardingDone = false, File? pick, bool photoCancel = false}) async {
    SharedPreferences.setMockInitialValues({'onboarding_done': onboardingDone});
    final prefs = await SharedPreferences.getInstance();
    final model = InstalledModel(oracleDescriptor(), '${root.path}/oracle.onnx', 1234, true, 'bundled');
    return ProviderScope(
      overrides: [
        appDirsProvider.overrideWithValue(AppDirs(projects: store.root, models: Directory('${root.path}/models'))),
        prefsProvider.overrideWithValue(prefs),
        installedModelsProvider.overrideWith((ref) async => [model]),
        fileSharerProvider.overrideWithValue(sharer),
        if (pick != null) filePickProvider.overrideWithValue(() async => PickedFile(pick, 'Planta baja.png')),
        if (photoCancel) photoPickProvider.overrideWithValue((camera) async => null),
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
    expect(find.text('Una foto del plano'), findsOneWidget);
    await t.tap(find.text('Omitir'));
    await settle(t);
    expect(find.text('Fotografiar plano'), findsOneWidget);
    expect(find.text('Todavía no hay proyectos'), findsOneWidget);

    await t.tap(find.byKey(const Key('new_project')));
    await settle(t);
    await t.enterText(find.byKey(const Key('project_name')), 'Casa Núñez');
    await t.tap(find.text('Residencial'));
    await t.tap(find.byKey(const Key('create_only')));
    await settle(t);
    expect(find.text('Casa Núñez'), findsOneWidget);
    expect(find.text('Sumá el plano'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Fotografiar plano'), findsOneWidget); // acción siguiente, fija abajo

    // Renombrar desde el título, sin ir a otra pantalla.
    await t.tap(find.byKey(const Key('project_title')));
    await settle(t, rounds: 4);
    await t.enterText(find.byKey(const Key('rename_field')), 'Casa Núñez PB');
    await t.tap(find.byKey(const Key('rename_save')));
    await settle(t);
    expect(find.text('Casa Núñez PB'), findsOneWidget);

    final saved = await t.runAsync(() => h.store.list());
    expect(saved!.single.buildingType, BuildingType.residential);
    expect(saved.single.name, 'Casa Núñez PB');

    await t.pageBack();
    await settle(t);
    expect(find.text('Casa Núñez PB'), findsOneWidget); // aparece en el dashboard
  });

  testWidgets('flujo rápido cancelado: el proyecto vacío se descarta', (t) async {
    phone(t);
    final h = Harness(tempDir());
    await t.pumpWidget(await h.app(onboardingDone: true, photoCancel: true));
    await settle(t, rounds: 20);
    await t.tap(find.byKey(const Key('quick_gallery')));
    await settle(t);
    expect(find.text('Fotografiá el plano'), findsOneWidget); // se canceló la galería
    await t.pageBack();
    await settle(t);
    expect(await t.runAsync(() => h.store.list()), isEmpty);
    expect(find.text('Todavía no hay proyectos'), findsOneWidget);
  });

  testWidgets('flujo completo con pocos toques: archivo → 3D → escala → evaluación → PDF → simulación 3D', (t) async {
    phone(t);
    final root = tempDir();
    final png = File('${root.path}/plano.png')..writeAsBytesSync(realisticPlanPng());
    final h = Harness(root);
    await t.pumpWidget(await h.app(onboardingDone: true, pick: png));
    await settle(t, rounds: 20);

    // 1 toque: el proyecto se crea solo, el archivo se importa y el análisis arranca.
    await t.tap(find.byKey(const Key('quick_file')));
    await settleUntil(t, find.byKey(const Key('mini_3d')));
    expect(find.byKey(const Key('mini_3d')), findsOneWidget);
    expect(find.text('MOTOR CLÁSICO · SIN IA  ›'), findsOneWidget);
    expect(find.text('1 puerta'), findsOneWidget);
    expect(find.text('1 ventana'), findsOneWidget);
    final rec = (await t.runAsync(() => h.store.list()))!.single.activeAnalysis!;
    expect(rec.model['engine'], 'classic');
    expect(rec.counts['wall'], greaterThanOrEqualTo(5));
    expect(rec.counts['column'], 1);

    // Acción siguiente: evaluar. Sin escala, va directo a calibrar y de ahí sigue sola.
    expect(find.text('Evaluar sismo, tsunami y viento'), findsOneWidget);
    await t.tap(find.byKey(const Key('primary_action')));
    await settle(t, rounds: 20);
    final r = t.getRect(find.byKey(const Key('calibrate_viewer')));
    await t.tapAt(Offset(r.left + r.width * 0.2, r.center.dy));
    await t.pump(const Duration(milliseconds: 400));
    await t.tapAt(Offset(r.left + r.width * 0.8, r.center.dy));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Distancia marcada'), findsOneWidget);
    await t.enterText(find.byKey(const Key('calibrate_meters')), '9,5');
    await t.pump();
    expect(find.byKey(const Key('calibrate_sanity')), findsOneWidget);
    await t.tap(find.byKey(const Key('calibrate_save')));
    await settle(t, rounds: 30);
    expect(find.text('Evaluación preliminar'), findsOneWidget);
    expect(find.textContaining('Escala verificada'), findsOneWidget);

    // Preset en un toque; "Evaluar" siempre visible abajo.
    await t.ensureVisible(find.byKey(const Key('preset_1')));
    await t.pump();
    await t.tap(find.byKey(const Key('preset_1')));
    await t.pump();
    expect(find.descendant(of: find.byKey(const Key('floors')), matching: find.text('2')), findsOneWidget);
    await t.tap(find.byKey(const Key('run_screening')));
    await settle(t, rounds: 20);
    expect(find.byKey(const Key('results_panel')), findsOneWidget);
    expect(find.text('Sismo'), findsOneWidget);
    await t.tap(find.byKey(const Key('hazard_seismic')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Corte basal dirección X (demanda/capacidad)'), findsOneWidget);
    final project = (await t.runAsync(() => h.store.list()))!.single;
    final report = File('${h.store.projectDir(project.id).path}/${project.activeAnalysis!.dir}/screening.json');
    expect(await t.runAsync(() => report.exists()), isTrue);

    // Informe PDF generado en el dispositivo y entregado a la hoja de compartir.
    await t.tap(find.byKey(const Key('export_pdf')));
    await settleUntil(t, find.byKey(const Key('pdf_saved')));
    expect(h.sharer.shared.single.$2, mimePdf);
    final pdf = File(h.sharer.shared.single.$1);
    final head = await t.runAsync(() => pdf.openRead(0, 5).first);
    expect(String.fromCharCodes(head!), '%PDF-');
    expect(pdf.path, endsWith('informe_evaluacion.pdf'));

    // Simulación 3D y cambio de peligro sin volver atrás.
    await t.tap(find.byKey(const Key('view3d_seismic')));
    await settle(t, rounds: 20);
    expect(find.text('Simulación 3D'), findsOneWidget);
    expect(find.text('SIMULACIÓN PRELIMINAR'), findsOneWidget);
    expect(find.textContaining('Altura total declarada para la evaluación: 2 piso(s)'), findsOneWidget);
    await t.tap(find.byKey(const Key('mode_tsunami')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Agua hasta'), findsOneWidget);
    await t.tap(find.byKey(const Key('share_glb')));
    await settle(t, rounds: 4);
    expect(h.sharer.shared.last.$2, mimeGlb);
    expect(h.sharer.shared.last.$1, endsWith('model.glb'));

    // De vuelta al panel: la acción siguiente ahora es compartir el informe.
    await t.pageBack();
    await settle(t);
    await t.pageBack();
    await settle(t, rounds: 20);
    expect(find.text('Compartir informe PDF'), findsOneWidget);
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
    expect(find.text('RESULTADO NO VALIDADO CON PLANOS REALES'), findsOneWidget);
    expect(find.byKey(const Key('mini_3d')), findsOneWidget);

    await t.tap(find.byKey(const Key('tile_plan')));
    await settle(t, rounds: 20);
    expect(find.text('Segmentación'), findsOneWidget);
    expect(find.textContaining('Muros · w0001'), findsOneWidget);
    await t.scrollUntilVisible(find.textContaining('Tocá un elemento en el plano'), 300, scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('Tocá un elemento en el plano'), findsOneWidget);
    await t.pageBack();
    await settle(t);

    await t.tap(find.byKey(const Key('tile_3d')));
    await settle(t, rounds: 20);
    expect(find.textContaining('Sin escala verificada'), findsOneWidget);
    expect(find.text('UNIDADES: PX · ALTURA SUPUESTA'), findsOneWidget);
    await t.tap(find.byKey(const Key('view_top')));
    await t.pump();
    await t.scrollUntilVisible(find.text('Triángulos'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('Triángulos'), findsOneWidget);
    expect(id, isNotNull);
  });

  testWidgets('configuración muestra capacidades reales y procedencia del modelo', (t) async {
    phone(t);
    final h = Harness(tempDir());
    await t.pumpWidget(await h.app(onboardingDone: true));
    await settle(t, rounds: 20);
    await t.tap(find.text('Configuración').last);
    await settle(t);
    expect(find.byKey(const Key('engine_setting')), findsOneWidget);
    await t.scrollUntilVisible(find.text('PRUEBA'), 200);
    expect(find.text('DATOS: SYNTHETIC'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Runtime de IA (ONNX Runtime)'), 200);
    expect(find.text('NO DISPONIBLE'), findsNWidgets(2)); // en el host de tests no hay Android
  });
}
