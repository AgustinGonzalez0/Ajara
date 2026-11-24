/// Ejecución del análisis y persistencia de resultados.
///
/// [executeAnalysis] es la lógica común (decodificar plano → pipeline CORE →
/// guardar resultados). [BackgroundAnalysisRunner] la ejecuta en un isolate
/// aparte (la UI no se bloquea) usando `BackgroundIsolateBinaryMessenger` para
/// hablar con ONNX Runtime nativo. [InProcessAnalysisRunner] la ejecuta en el
/// isolate actual (tests y plataformas sin isolate de fondo).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_model/structura_model.dart';
import 'package:structura_pipeline/structura_pipeline.dart';
import 'package:structura_vision/structura_vision.dart';
import 'package:uuid/uuid.dart';

import '../data/project_models.dart';
import '../platform/native_channels.dart';

/// Todo lo que necesita un análisis, serializable entre isolates.
class AnalysisJob {
  final String projectDir;
  final String rasterPath;
  final String rasterSha256;
  final double? dpi;
  final String planId;
  final Map<String, Object?> modelJson;
  final String modelPath;
  final String runId;
  const AnalysisJob({
    required this.projectDir,
    required this.rasterPath,
    required this.rasterSha256,
    required this.dpi,
    required this.planId,
    required this.modelJson,
    required this.modelPath,
    required this.runId,
  });

  String get relDir => 'analysis/$runId';
  Directory get outDir => Directory(p.join(projectDir, 'analysis', runId));
}

PlanRaster decodeRaster(Uint8List png) {
  final image = img.decodePng(png);
  if (image == null) throw const FormatException('raster.png ilegible');
  final rgb = image.convert(numChannels: 3, format: img.Format.uint8).getBytes(order: img.ChannelOrder.rgb);
  return PlanRaster(image.width, image.height, rgb);
}

Map<String, Object?> modelSummary(ModelDescriptor d) => {
      'id': d.id,
      'version': d.version,
      'training_data': d.trainingData,
      'production_ready': d.productionReady,
      'trust_label': d.trustLabel,
    };

/// Guarda los resultados de un análisis (cualquier motor) en `job.outDir`.
void writeAnalysisOutputs(AnalysisJob job, SegmentationResult seg, BuildingModel model, BuildingMesh mesh,
    Map<String, Object?> engine, List<Map<String, Object?>> timings, List<String> warnings, Map<String, int> counts,
    DateTime started, {Map<String, Object?> extra = const {}}) {
  final out = job.outDir..createSync(recursive: true);
  final labels = img.Image.fromBytes(width: seg.width, height: seg.height, bytes: seg.labels.buffer, numChannels: 1);
  File(p.join(out.path, 'labels.png')).writeAsBytesSync(img.encodePng(labels, level: 3));
  final c = seg.confidence;
  if (c != null) {
    final conf = Uint8List(seg.width * seg.height);
    for (var i = 0; i < conf.length; i++) {
      conf[i] = (c[i] * 255).round().clamp(0, 255);
    }
    File(p.join(out.path, 'confidence.png')).writeAsBytesSync(
        img.encodePng(img.Image.fromBytes(width: seg.width, height: seg.height, bytes: conf.buffer, numChannels: 1), level: 3));
  }
  File(p.join(out.path, 'building_model.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(model.toJson()));
  File(p.join(out.path, 'model.glb'))
      .writeAsBytesSync(const GlbWriter().write(mesh, extras: {'structura_model': engine, 'building_model_id': model.id}));
  final run = {
    'run_id': job.runId,
    'created_at': started.toIso8601String(),
    'model': engine,
    'plan': {'id': job.planId, 'width': seg.width, 'height': seg.height, 'sha256': job.rasterSha256},
    'class_pixels': seg.classHistogram(),
    'counts': counts,
    'timings': timings,
    'warnings': warnings,
    'display_assumptions': mesh.assumptions.toJson(),
    ...extra,
  };
  File(p.join(out.path, 'run.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(run));
}

/// Resumen del motor clásico (sin IA) para el registro del análisis.
const Map<String, Object?> classicEngineSummary = {
  'id': 'classic_cv',
  'version': '0.1.0',
  'engine': 'classic',
  'training_data': 'none',
  'production_ready': false,
  'trust_label': 'Detección clásica sin IA (determinista). Validada solo con planos sintéticos.',
};

/// Motor clásico: visión por computadora sin IA. Corre en cualquier celular.
Future<AnalysisRecord> executeClassicAnalysis(AnalysisJob job, {ProgressSink? onProgress, CancellationToken? token}) async {
  final started = DateTime.now().toUtc();
  AnalysisRecord record(AnalysisStatus s, {Map<String, int> counts = const {}, List<String> warnings = const [],
          List<Map<String, Object?>> timings = const [], String? error}) =>
      AnalysisRecord(
          id: job.runId,
          planId: job.planId,
          createdAt: started,
          status: s,
          dir: job.relDir,
          model: classicEngineSummary,
          counts: counts,
          warnings: warnings,
          timings: timings,
          error: error);
  void report(int i, String id, String label, double f, [String? msg]) =>
      onProgress?.call(ProgressEvent(id, label, i, 3, f, msg));
  try {
    final sw = Stopwatch()..start();
    report(0, 'segment', 'Detección clásica (sin IA)', 0);
    final raster = decodeRaster(await File(job.rasterPath).readAsBytes());
    // detectScaled acota memoria y tiempo en celulares de gama baja (planos grandes).
    final det = const ClassicDetector().detectScaled(GrayImage.fromRgb(raster.width, raster.height, raster.rgb));
    final tDetect = sw.elapsedMilliseconds;
    report(0, 'segment', 'Detección clásica (sin IA)', 1);
    token?.throwIfCancelled();
    report(1, 'vectorize', 'Vectorización y Building Model', 0);
    final build = const BuildingModelBuilder().build(det.segmentation,
        modelId: job.runId,
        detectorSource: Source(Provenance.classicDetected, modelId: 'classic_cv', modelVersion: '0.1.0', timestamp: started),
        imageSha256: job.rasterSha256,
        dpi: job.dpi);
    final tVector = sw.elapsedMilliseconds - tDetect;
    report(1, 'vectorize', 'Vectorización y Building Model', 1);
    report(2, 'mesh', 'Geometría 3D', 0);
    final mesh = const MeshBuilder().build(build.model);
    final tMesh = sw.elapsedMilliseconds - tDetect - tVector;
    report(2, 'mesh', 'Geometría 3D', 1);
    final counts = <String, int>{};
    for (final e in build.model.allElements) {
      counts[e.kind.name] = (counts[e.kind.name] ?? 0) + 1;
    }
    final warnings = [
      ...det.diagnostics.warnings,
      ...build.vectorization.warnings,
      if (build.model.allElements.isEmpty) 'No se detectaron elementos en el plano.',
    ];
    final timings = [
      {'stage': 'segment', 'ms': tDetect},
      {'stage': 'vectorize', 'ms': tVector},
      {'stage': 'mesh', 'ms': tMesh},
    ];
    writeAnalysisOutputs(job, det.segmentation, build.model, mesh, classicEngineSummary, timings, warnings, counts, started,
        extra: {'classic_diagnostics': det.diagnostics.toJson()});
    return record(AnalysisStatus.completed, counts: counts, warnings: warnings, timings: timings);
  } on CancelledException {
    return record(AnalysisStatus.cancelled, error: 'Cancelado por el usuario');
  } on Object catch (e) {
    return record(AnalysisStatus.failed, error: '$e');
  }
}

/// Nivel superior a propósito: el cierre solo captura [job] (un cierre dentro de un
/// método async capturaría su contexto, con Futures no enviables entre isolates).
Future<AnalysisRecord> _classicInIsolate(AnalysisJob job) => Isolate.run(() => executeClassicAnalysis(job));

/// Ejecuta el motor clásico en un isolate (la UI no se bloquea). No necesita runtime nativo.
class ClassicAnalysisRunner implements AnalysisRunner {
  const ClassicAnalysisRunner();
  @override
  AnalysisHandle start(AnalysisJob job, void Function(ProgressEvent) onProgress) {
    var cancelled = false;
    Future<AnalysisRecord> run() async {
      onProgress(const ProgressEvent('segment', 'Detección clásica (sin IA)', 0, 3, null, 'Procesando…'));
      final rec = await _classicInIsolate(job);
      if (cancelled && rec.status == AnalysisStatus.completed) {
        return AnalysisRecord(
            id: rec.id,
            planId: rec.planId,
            createdAt: rec.createdAt,
            status: AnalysisStatus.cancelled,
            dir: rec.dir,
            model: rec.model,
            error: 'Cancelado por el usuario');
      }
      for (var i = 0; i < 3; i++) {
        onProgress(ProgressEvent(['segment', 'vectorize', 'mesh'][i],
            ['Detección clásica (sin IA)', 'Vectorización y Building Model', 'Geometría 3D'][i], i, 3, 1));
      }
      return rec;
    }

    return AnalysisHandle(run(), () => cancelled = true);
  }
}

/// Lógica común del análisis con IA. Escribe los resultados en `job.outDir`.
Future<AnalysisRecord> executeAnalysis(
  AnalysisJob job,
  TileInferencer inferencer, {
  CancellationToken? token,
  ProgressSink? onProgress,
}) async {
  final d = inferencer.descriptor;
  final started = DateTime.now().toUtc();
  AnalysisRecord record(AnalysisStatus s, {Map<String, int> counts = const {}, List<String> warnings = const [],
          List<Map<String, Object?>> timings = const [], String? error}) =>
      AnalysisRecord(
          id: job.runId,
          planId: job.planId,
          createdAt: started,
          status: s,
          dir: job.relDir,
          model: modelSummary(d),
          counts: counts,
          warnings: warnings,
          timings: timings,
          error: error);
  try {
    final raster = decodeRaster(await File(job.rasterPath).readAsBytes());
    final result = await const AnalysisPipeline().run(
      raster: raster,
      inferencer: inferencer,
      buildingModelId: job.runId,
      imageSha256: job.rasterSha256,
      dpi: job.dpi,
      token: token,
      onProgress: onProgress,
    );
    final timings = result.timings.map((t) => t.toJson()).toList();
    writeAnalysisOutputs(job, result.segmentation, result.build.model, result.mesh, modelSummary(d), timings,
        result.warnings, result.elementCounts, started);
    return record(AnalysisStatus.completed, counts: result.elementCounts, warnings: result.warnings, timings: timings);
  } on CancelledException {
    return record(AnalysisStatus.cancelled, error: 'Cancelado por el usuario');
  } on StageFailure catch (e) {
    return record(AnalysisStatus.failed, error: e.toString());
  } on Object catch (e) {
    return record(AnalysisStatus.failed, error: '$e');
  }
}

/// Ejecutor de análisis con progreso y cancelación.
abstract interface class AnalysisRunner {
  /// Inicia el análisis. [onProgress] se invoca en el isolate de la UI.
  AnalysisHandle start(AnalysisJob job, void Function(ProgressEvent) onProgress);
}

class AnalysisHandle {
  final Future<AnalysisRecord> result;
  final void Function() cancel;
  const AnalysisHandle(this.result, this.cancel);
}

class InProcessAnalysisRunner implements AnalysisRunner {
  final InferenceRuntime runtime;
  const InProcessAnalysisRunner(this.runtime);
  @override
  AnalysisHandle start(AnalysisJob job, void Function(ProgressEvent) onProgress) {
    final token = CancellationToken();
    Future<AnalysisRecord> run() async {
      final d = ModelDescriptor.fromJson(job.modelJson);
      final inf = await runtime.load(d, job.modelPath);
      try {
        return await executeAnalysis(job, inf, token: token, onProgress: onProgress);
      } finally {
        await inf.dispose();
      }
    }

    return AnalysisHandle(run(), token.cancel);
  }
}

/// Ejecuta el análisis en un isolate de fondo con ONNX Runtime nativo.
class BackgroundAnalysisRunner implements AnalysisRunner {
  const BackgroundAnalysisRunner();

  @override
  AnalysisHandle start(AnalysisJob job, void Function(ProgressEvent) onProgress) {
    final rootToken = RootIsolateToken.instance!;
    final events = ReceivePort();
    final completer = Completer<AnalysisRecord>();
    SendPort? control;
    events.listen((msg) {
      if (msg is SendPort) {
        control = msg;
      } else if (msg is List && msg.first == 'progress') {
        onProgress(ProgressEvent(msg[1] as String, msg[2] as String, msg[3] as int, msg[4] as int, msg[5] as double?, msg[6] as String?));
      } else if (msg is List && msg.first == 'done') {
        completer.complete(AnalysisRecord.fromJson((jsonDecode(msg[1] as String) as Map).cast<String, Object?>()));
        events.close();
      } else if (msg is List && msg.first == 'error') {
        completer.completeError(StageFailure('isolate', msg[1] as String));
        events.close();
      } else if (!completer.isCompleted) {
        // Error no capturado del isolate (onError envía [error, stack]).
        completer.completeError(StageFailure('isolate', msg is List ? msg.join('\n') : '$msg'));
        events.close();
      }
    });
    Isolate.spawn(_isolateMain, [events.sendPort, rootToken, _jobToJson(job)], onError: events.sendPort,
            errorsAreFatal: true)
        .catchError((Object e) {
      if (!completer.isCompleted) completer.completeError(e);
      events.close();
      return Isolate.current;
    });
    return AnalysisHandle(completer.future, () => control?.send('cancel'));
  }

  static Map<String, Object?> _jobToJson(AnalysisJob j) => {
        'projectDir': j.projectDir,
        'rasterPath': j.rasterPath,
        'rasterSha256': j.rasterSha256,
        'dpi': j.dpi,
        'planId': j.planId,
        'modelJson': jsonEncode(j.modelJson),
        'modelPath': j.modelPath,
        'runId': j.runId,
      };

  static Future<void> _isolateMain(List<Object?> args) async {
    final out = args[0] as SendPort;
    BackgroundIsolateBinaryMessenger.ensureInitialized(args[1] as RootIsolateToken);
    final m = (args[2] as Map).cast<String, Object?>();
    final job = AnalysisJob(
      projectDir: m['projectDir'] as String,
      rasterPath: m['rasterPath'] as String,
      rasterSha256: m['rasterSha256'] as String,
      dpi: m['dpi'] as double?,
      planId: m['planId'] as String,
      modelJson: (jsonDecode(m['modelJson'] as String) as Map).cast<String, Object?>(),
      modelPath: m['modelPath'] as String,
      runId: m['runId'] as String,
    );
    final token = CancellationToken();
    final controlPort = ReceivePort();
    controlPort.listen((msg) {
      if (msg == 'cancel') token.cancel();
    });
    out.send(controlPort.sendPort);
    try {
      final d = ModelDescriptor.fromJson(job.modelJson);
      final inf = await const OnnxChannelRuntime().load(d, job.modelPath);
      final rec = await executeAnalysis(job, inf, token: token, onProgress: (e) {
        out.send(['progress', e.stageId, e.stageLabel, e.stageIndex, e.stageCount, e.fraction, e.message]);
      });
      await inf.dispose();
      out.send(['done', jsonEncode(rec.toJson())]);
    } on Object catch (e) {
      out.send(['error', '$e']);
    } finally {
      controlPort.close();
    }
  }
}

String newRunId() => const Uuid().v4().substring(0, 8);
