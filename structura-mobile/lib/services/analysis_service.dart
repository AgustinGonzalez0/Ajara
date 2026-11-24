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
import 'package:structura_pipeline/structura_pipeline.dart';
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

/// Lógica común del análisis. Escribe los resultados en `job.outDir`.
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
    final out = job.outDir..createSync(recursive: true);
    final seg = result.segmentation;
    final labels = img.Image.fromBytes(width: seg.width, height: seg.height, bytes: seg.labels.buffer, numChannels: 1);
    File(p.join(out.path, 'labels.png')).writeAsBytesSync(img.encodePng(labels, level: 3));
    final conf = Uint8List(seg.width * seg.height);
    final c = seg.confidence!;
    for (var i = 0; i < conf.length; i++) {
      conf[i] = (c[i] * 255).round().clamp(0, 255);
    }
    File(p.join(out.path, 'confidence.png')).writeAsBytesSync(
        img.encodePng(img.Image.fromBytes(width: seg.width, height: seg.height, bytes: conf.buffer, numChannels: 1), level: 3));
    File(p.join(out.path, 'building_model.json'))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result.build.model.toJson()));
    File(p.join(out.path, 'model.glb')).writeAsBytesSync(const GlbWriter().write(result.mesh, extras: {
      'structura_model': modelSummary(d),
      'building_model_id': result.build.model.id,
    }));
    final timings = result.timings.map((t) => t.toJson()).toList();
    final run = {
      'run_id': job.runId,
      'created_at': started.toIso8601String(),
      'model': modelSummary(d),
      'plan': {'id': job.planId, 'width': seg.width, 'height': seg.height, 'sha256': job.rasterSha256},
      'class_pixels': seg.classHistogram(),
      'counts': result.elementCounts,
      'timings': timings,
      'warnings': result.warnings,
      'display_assumptions': result.mesh.assumptions.toJson(),
    };
    File(p.join(out.path, 'run.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(run));
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
