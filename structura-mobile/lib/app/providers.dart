/// Proveedores Riverpod: inyección de dependencias y estado de la app.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:structura_model/structura_model.dart';
import 'package:structura_pipeline/structura_pipeline.dart';

import '../data/project_models.dart';
import '../data/project_store.dart';
import '../platform/native_channels.dart';
import '../services/analysis_service.dart';
import '../services/correction_service.dart';
import '../services/model_registry.dart';
import '../services/photo_importer.dart';
import '../services/plan_importer.dart';
import '../services/report_service.dart';
import '../services/screening_service.dart';
import '../services/share_service.dart';

class AppDirs {
  final Directory projects;
  final Directory models;
  const AppDirs({required this.projects, required this.models});
}

/// Se sobrescriben en `main()` (y en los tests).
final appDirsProvider = Provider<AppDirs>((ref) => throw UnimplementedError('appDirsProvider'));
final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError('prefsProvider'));

final projectStoreProvider = Provider<ProjectStore>((ref) => ProjectStore(ref.watch(appDirsProvider).projects));
final pdfRasterizerProvider = Provider<PdfRasterizer>((ref) => defaultPdfRasterizer());
final planImporterProvider =
    Provider<PlanImporter>((ref) => PlanImporter(ref.watch(projectStoreProvider), ref.watch(pdfRasterizerProvider)));
final modelRegistryProvider =
    Provider<ModelRegistry>((ref) => ModelRegistry(ref.watch(appDirsProvider).models, rootBundle));
final correctionServiceProvider = Provider<CorrectionService>((ref) => CorrectionService(ref.watch(projectStoreProvider)));
final fileSharerProvider = Provider<FileSharer>((ref) => const SystemFileSharer());
final reportServiceProvider =
    Provider<ReportService>((ref) => ReportService(ref.watch(projectStoreProvider), loadFonts: loadBundledReportFonts));
final installedModelsProvider =
    FutureProvider<List<InstalledModel>>((ref) => ref.watch(modelRegistryProvider).installedModels());

/// null = la plataforma no puede ejecutar modelos (se informa en la UI, no se simula).
final analysisRunnerProvider =
    Provider<AnalysisRunner?>((ref) => NativeCapabilities.onnx ? const BackgroundAnalysisRunner() : null);

// ---------------------------------------------------------------- Proyectos
class ProjectsNotifier extends AsyncNotifier<List<ProjectManifest>> {
  @override
  Future<List<ProjectManifest>> build() => ref.watch(projectStoreProvider).list();

  Future<ProjectManifest> create(String name, String description, BuildingType type) async {
    final m = await ref.read(projectStoreProvider).create(name: name, description: description, type: type);
    ref.invalidateSelf();
    return m;
  }

  /// Flujo rápido "foto → 3D": proyecto sin formulario, con nombre automático editable.
  Future<ProjectManifest> createQuick({DateTime? now}) {
    final t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return create('Plano ${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)}', '', BuildingType.unspecified);
  }

  Future<void> rename(String id, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final store = ref.read(projectStoreProvider);
    final m = await store.load(id);
    await store.save(m.copyWith(name: clean));
    await store.appendHistory(id, 'renamed', {'name': clean});
    ref.invalidateSelf();
    ref.invalidate(projectProvider(id));
  }

  Future<void> delete(String id) async {
    await ref.read(projectStoreProvider).delete(id);
    ref.invalidateSelf();
    ref.invalidate(projectProvider(id));
  }

  /// Borra un proyecto rápido que quedó vacío (se canceló la foto o el archivo).
  Future<void> discardIfEmpty(String id) async {
    try {
      final m = await ref.read(projectStoreProvider).load(id);
      if (m.plans.isEmpty && m.analyses.isEmpty) await delete(id);
    } on Object {
      // Si no se puede leer, no se borra nada.
    }
  }
}

final projectsProvider = AsyncNotifierProvider<ProjectsNotifier, List<ProjectManifest>>(ProjectsNotifier.new);

final projectProvider =
    FutureProvider.family<ProjectManifest, String>((ref, id) => ref.watch(projectStoreProvider).load(id));

void refreshProject(WidgetRef ref, String id) {
  ref.invalidate(projectProvider(id));
  ref.invalidate(projectsProvider);
}

// ---------------------------------------------------------------- Ajustes
/// Motor que se usa automáticamente al importar un plano.
enum DefaultEngine { classic, ai }

class AppSettings {
  final bool onboardingDone;
  final double pdfDpi;
  final bool darkMode;
  final DefaultEngine engine;

  /// Generación detallada del 3D (afinado geométrico; con IA, 4 pasadas). Por defecto sí.
  final bool detailed3d;
  const AppSettings(
      {this.onboardingDone = false,
      this.pdfDpi = defaultPdfDpi,
      this.darkMode = true,
      this.engine = DefaultEngine.classic,
      this.detailed3d = true});

  AppSettings copyWith({bool? onboardingDone, double? pdfDpi, bool? darkMode, DefaultEngine? engine, bool? detailed3d}) =>
      AppSettings(
          onboardingDone: onboardingDone ?? this.onboardingDone,
          pdfDpi: pdfDpi ?? this.pdfDpi,
          darkMode: darkMode ?? this.darkMode,
          engine: engine ?? this.engine,
          detailed3d: detailed3d ?? this.detailed3d);
}

class SettingsNotifier extends Notifier<AppSettings> {
  SharedPreferences get _p => ref.read(prefsProvider);
  @override
  AppSettings build() {
    final p = ref.watch(prefsProvider);
    return AppSettings(
      onboardingDone: p.getBool('onboarding_done') ?? false,
      pdfDpi: p.getDouble('pdf_dpi') ?? defaultPdfDpi,
      darkMode: p.getBool('dark_mode') ?? true,
      engine: p.getString('default_engine') == 'ai' ? DefaultEngine.ai : DefaultEngine.classic,
      detailed3d: p.getBool('detailed_3d') ?? true,
    );
  }

  Future<void> setDetailed3d(bool v) async {
    await _p.setBool('detailed_3d', v);
    state = state.copyWith(detailed3d: v);
  }

  Future<void> setEngine(DefaultEngine e) async {
    await _p.setString('default_engine', e.name);
    state = state.copyWith(engine: e);
  }

  Future<void> completeOnboarding() async {
    await _p.setBool('onboarding_done', true);
    state = state.copyWith(onboardingDone: true);
  }

  Future<void> setPdfDpi(double dpi) async {
    await _p.setDouble('pdf_dpi', dpi);
    state = state.copyWith(pdfDpi: dpi);
  }

  Future<void> setDarkMode(bool v) async {
    await _p.setBool('dark_mode', v);
    state = state.copyWith(darkMode: v);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

// ---------------------------------------------------------------- Análisis
enum AnalysisPhase { idle, running, completed, failed, cancelled, unavailable }

class AnalysisState {
  final AnalysisPhase phase;
  final ProgressEvent? progress;
  final List<ProgressEvent> stageLog;
  final AnalysisRecord? record;
  final String? message;
  const AnalysisState({this.phase = AnalysisPhase.idle, this.progress, this.stageLog = const [], this.record, this.message});
}

class AnalysisController extends Notifier<AnalysisState> {
  AnalysisController(this.projectId);
  final String projectId;
  AnalysisHandle? _handle;

  @override
  AnalysisState build() => const AnalysisState();

  /// [model] null = motor clásico sin IA (funciona en cualquier dispositivo).
  Future<void> start({InstalledModel? model}) async {
    if (state.phase == AnalysisPhase.running) return;
    final AnalysisRunner? runner = model == null ? const ClassicAnalysisRunner() : ref.read(analysisRunnerProvider);
    if (runner == null) {
      state = const AnalysisState(
          phase: AnalysisPhase.unavailable,
          message: 'Este dispositivo no puede ejecutar el modelo de IA. Usá el motor clásico (sin IA).');
      return;
    }
    if (model != null && !model.hashVerified) {
      state = const AnalysisState(phase: AnalysisPhase.failed, message: 'El modelo no superó la verificación SHA-256.');
      return;
    }
    final store = ref.read(projectStoreProvider);
    final project = await store.load(projectId);
    final plan = project.activePlan;
    if (plan == null) {
      state = const AnalysisState(phase: AnalysisPhase.failed, message: 'El proyecto no tiene un plano importado.');
      return;
    }
    final job = AnalysisJob(
      projectDir: store.projectDir(projectId).path,
      rasterPath: store.resolve(projectId, plan.rasterFile).path,
      rasterSha256: plan.rasterSha256,
      dpi: plan.dpi,
      planId: plan.id,
      modelJson: model == null ? const {} : _descriptorJson(model),
      modelPath: model?.path ?? '',
      runId: newRunId(),
      detailed: ref.read(settingsProvider).detailed3d,
    );
    state = const AnalysisState(phase: AnalysisPhase.running);
    final log = <String, ProgressEvent>{};
    _handle = runner.start(job, (e) {
      log[e.stageId] = e;
      state = AnalysisState(phase: AnalysisPhase.running, progress: e, stageLog: log.values.toList());
    });
    try {
      final rec = await _handle!.result;
      final fresh = await store.load(projectId);
      await store.save(fresh.copyWith(
        analyses: [...fresh.analyses, rec],
        activeAnalysisId: rec.status == AnalysisStatus.completed ? rec.id : fresh.activeAnalysisId,
        status: rec.status == AnalysisStatus.completed
            ? ProjectStatus.analyzed
            : (rec.status == AnalysisStatus.failed ? ProjectStatus.failed : fresh.status),
      ));
      await store.appendHistory(projectId, 'analysis_${rec.status.name}',
          {'run_id': rec.id, 'model': rec.model['id'], 'counts': rec.counts, 'error': rec.error});
      ref.invalidate(projectProvider(projectId));
      ref.invalidate(projectsProvider);
      state = AnalysisState(
        phase: switch (rec.status) {
          AnalysisStatus.completed => AnalysisPhase.completed,
          AnalysisStatus.cancelled => AnalysisPhase.cancelled,
          AnalysisStatus.failed => AnalysisPhase.failed,
        },
        record: rec,
        stageLog: log.values.toList(),
        message: rec.error,
      );
    } on Object catch (e) {
      state = AnalysisState(phase: AnalysisPhase.failed, message: '$e', stageLog: log.values.toList());
    } finally {
      _handle = null;
    }
  }

  void cancel() => _handle?.cancel();

  Map<String, Object?> _descriptorJson(InstalledModel m) {
    final d = m.descriptor;
    return {
      'format': 'structura-model/1',
      'id': d.id,
      'version': d.version,
      'task': d.task,
      'file': d.file,
      'sha256': d.sha256,
      'input': {'shape': d.inputShape},
      'classes': d.classes,
      'tiling': {'tile': d.tile, 'overlap': d.overlap},
      'training': {'data': d.trainingData, 'production_ready': d.productionReady, 'val_miou': d.valMiou},
      'notes': d.notes,
    };
  }
}

// ---------------------------------------------------------------- Evaluación
final screeningServiceProvider = Provider<ScreeningService>((ref) => ScreeningService(ref.watch(projectStoreProvider)));

/// Building Model del análisis activo (con la escala, si se calibró).
final simModelProvider = FutureProvider.autoDispose.family<BuildingModel, String>((ref, id) async {
  final p = await ref.watch(projectProvider(id).future);
  return ref.watch(screeningServiceProvider).loadModel(p);
});

/// Último informe de evaluación guardado (screening.json) o null.
final lastReportProvider = FutureProvider.autoDispose.family<Map<String, Object?>?, String>((ref, id) async {
  final p = await ref.watch(projectProvider(id).future);
  return ref.watch(screeningServiceProvider).lastReport(p);
});

final photoImporterProvider = Provider<PhotoImporter>((ref) => PhotoImporter(ref.watch(projectStoreProvider)));

final analysisControllerProvider =
    NotifierProvider.family<AnalysisController, AnalysisState, String>(AnalysisController.new);
