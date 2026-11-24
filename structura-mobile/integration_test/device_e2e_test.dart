// Prueba integral en dispositivo/emulador Android (no simula IA ni PDF):
//   flutter test integration_test/device_e2e_test.dart -d <dispositivo>
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_mobile/app/app.dart';
import 'package:structura_mobile/app/providers.dart';
import 'package:structura_mobile/app/router.dart';
import 'package:structura_mobile/data/project_models.dart';
import 'package:structura_mobile/platform/native_channels.dart';

/// PDF mínimo válido: página carta (612x792 pt) con un rectángulo negro.
List<int> minimalPdf() {
  const content = '0 0 0 rg 100 600 200 20 re f';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
  ];
  final b = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(b.length);
    b.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = b.length;
  b.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    b.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  b.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return ascii.encode(b.toString());
}

/// Planta sintética (muros negros de 12 px, tabique con vano, escalera) como las del dataset sintético.
List<int> syntheticPlanPng() {
  const w = 1100, h = 800;
  final im = img.Image(width: w, height: h, numChannels: 3)..clear(img.ColorRgb8(255, 255, 255));
  void rect(int x0, int y0, int x1, int y1, int v) => img.fillRect(im, x1: x0, y1: y0, x2: x1, y2: y1, color: img.ColorRgb8(v, v, v));
  rect(40, 40, 1060, 51, 0);
  rect(40, 749, 1060, 760, 0);
  rect(40, 40, 51, 760, 0);
  rect(1049, 40, 1060, 760, 0);
  rect(560, 40, 571, 760, 0);
  rect(560, 120, 571, 170, 255); // vano de puerta
  for (var y = 520; y < 700; y += 10) {
    img.drawLine(im, x1: 860, y1: y, x2: 960, y2: y, color: img.ColorRgb8(0, 0, 0));
  }
  img.drawRect(im, x1: 860, y1: 520, x2: 960, y2: 700, color: img.ColorRgb8(0, 0, 0));
  return img.encodePng(im);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android E2E: PDF nativo, ONNX Runtime real, análisis, persistencia y visor 3D', (t) async {
    expect(NativeCapabilities.onnx && NativeCapabilities.pdf, isTrue, reason: 'requiere Android');
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final root = Directory('${docs.path}/structura_e2e_${DateTime.now().millisecondsSinceEpoch}')..createSync(recursive: true);
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      appDirsProvider.overrideWithValue(AppDirs(projects: Directory('${root.path}/projects'), models: Directory('${support.path}/models'))),
      prefsProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(container: container, child: const StructuraApp()));
    await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));

    // 1. Modelo empaquetado instalado y verificado
    final models = await container.read(installedModelsProvider.future);
    expect(models, isNotEmpty);
    final model = models.first;
    expect(model.hashVerified, isTrue);
    expect(model.descriptor.trainingData, 'synthetic');
    expect(model.descriptor.isTestModel, isTrue);

    // 2. PDF real con PdfRenderer
    final pdfFile = File('${root.path}/plano_prueba.pdf')..writeAsBytesSync(minimalPdf());
    const pdf = AndroidPdfRasterizer();
    expect(await pdf.pageCount(pdfFile.path), 1);
    final out = '${root.path}/pdf_render.png';
    final (pw, ph) = await pdf.renderPage(pdfFile.path, 1, 72, out);
    expect((pw, ph), (612, 792));
    final rendered = img.decodePng(File(out).readAsBytesSync())!;
    expect(rendered.getPixel(200, 182).r, lessThan(40)); // rectángulo negro (y PDF invertida)
    expect(rendered.getPixel(10, 10).r, 255); // papel blanco

    // 3. Proyecto + importación (PNG y página de PDF)
    final store = container.read(projectStoreProvider);
    var project = await store.create(name: 'E2E dispositivo', type: BuildingType.residential);
    final png = File('${root.path}/planta.png')..writeAsBytesSync(syntheticPlanPng());
    project = await container.read(planImporterProvider).import(project, pdfFile, page: 1, dpi: 100);
    expect(project.activePlan!.dpiSource, 'pdf_render');
    expect((project.activePlan!.width, project.activePlan!.height), (850, 1100));
    project = await container.read(planImporterProvider).import(project, png, originalName: 'planta.png');
    expect(project.activePlan!.width, 1100);

    // 4. Análisis real: isolate de fondo + ONNX Runtime nativo + modelo de prueba
    final ctrl = container.read(analysisControllerProvider(project.id).notifier);
    final sw = Stopwatch()..start();
    final running = ctrl.start(model);
    while (container.read(analysisControllerProvider(project.id)).phase == AnalysisPhase.running ||
        container.read(analysisControllerProvider(project.id)).phase == AnalysisPhase.idle) {
      await t.pump(const Duration(milliseconds: 200));
      if (sw.elapsed > const Duration(minutes: 5)) fail('análisis demasiado lento');
    }
    await running;
    final state = container.read(analysisControllerProvider(project.id));
    expect(state.phase, AnalysisPhase.completed, reason: state.message);
    final rec = state.record!;
    final segMs = rec.timings.firstWhere((e) => e['stage'] == 'segment')['ms'] as int;
    // 1100x800 → rejilla 3x2 = 6 tiles
    debugPrint('E2E_RESULT counts=${rec.counts} timings=${rec.timings} ms_por_tile=${(segMs / 6).toStringAsFixed(1)} total=${sw.elapsedMilliseconds}ms');
    expect(rec.counts['wall'] ?? 0, greaterThan(0));
    expect(rec.isTestModel, isTrue);

    // 5. Resultados persistidos y legibles sin re-procesar
    final saved = await store.load(project.id);
    expect(saved.status, ProjectStatus.analyzed);
    expect(saved.activeAnalysis!.id, rec.id);
    final glb = GlbInfo.parse(store.resolve(project.id, '${rec.dir}/model.glb').readAsBytesSync());
    expect((glb.json['meshes'] as List), isNotEmpty);

    // 6. UI: proyecto → editor 2D → modelo 3D
    final router = container.read(routerProvider);
    router.go('/projects/${project.id}');
    await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
    expect(find.text('E2E dispositivo'), findsOneWidget);
    router.push('/projects/${project.id}/editor');
    await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
    expect(find.text('Segmentación (IA)'), findsOneWidget);
    router.go('/projects/${project.id}/model');
    await t.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));
    expect(find.text('Modelo 3D'), findsOneWidget);
    expect(find.textContaining('Sin escala verificada'), findsOneWidget);
    await t.drag(find.byType(CustomPaint).first, const Offset(120, 40)); // orbitar
    await t.pump();
  });
}
