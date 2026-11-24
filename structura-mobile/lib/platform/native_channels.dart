/// Puentes nativos (Android): ONNX Runtime y PdfRenderer.
///
/// Implementación Kotlin: android/app/src/main/kotlin/.../{OnnxBridge,PdfBridge}.kt.
/// En plataformas sin implementación, [NativeCapabilities] lo informa y la UI
/// muestra la función como "no disponible" en lugar de simularla.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:structura_pipeline/structura_pipeline.dart';

import '../services/plan_importer.dart';

const _onnx = MethodChannel('structura/onnx');
const _pdf = MethodChannel('structura/pdf');

abstract final class NativeCapabilities {
  static bool get onnx => Platform.isAndroid;
  static bool get pdf => Platform.isAndroid;
}

class OnnxChannelRuntime implements InferenceRuntime {
  const OnnxChannelRuntime();
  @override
  String get name => 'ONNX Runtime (Android, CPU)';

  @override
  Future<TileInferencer> load(ModelDescriptor descriptor, String modelPath) async {
    try {
      final info = await _onnx.invokeMapMethod<String, Object?>('load', {'path': modelPath, 'threads': 4});
      if (info == null) throw const StageFailure('load', 'respuesta vacía del runtime');
      return OnnxChannelInferencer(descriptor, info['session'] as int, (info['provider'] as String?) ?? 'CPU');
    } on PlatformException catch (e) {
      throw StageFailure('load', 'no se pudo cargar el modelo: ${e.message}', e.code);
    }
  }
}

class OnnxChannelInferencer implements TileInferencer {
  @override
  final ModelDescriptor descriptor;
  final int session;
  final String provider;
  OnnxChannelInferencer(this.descriptor, this.session, this.provider);

  @override
  Future<Float32List> infer(Float32List chw) async {
    final t = descriptor.tile;
    final out = await _onnx.invokeMethod<Float32List>('run', {
      'session': session,
      'input': chw,
      'shape': [1, 3, t, t],
    });
    if (out == null) throw StateError('ONNX Runtime devolvió una salida vacía');
    return out;
  }

  @override
  Future<void> dispose() => _onnx.invokeMethod('close', {'session': session});
}

class AndroidPdfRasterizer implements PdfRasterizer {
  const AndroidPdfRasterizer();
  @override
  bool get isAvailable => NativeCapabilities.pdf;

  @override
  Future<int> pageCount(String pdfPath) async {
    try {
      return (await _pdf.invokeMethod<int>('pageCount', {'path': pdfPath}))!;
    } on PlatformException catch (e) {
      throw ImportException('No se pudo abrir el PDF: ${e.message}');
    }
  }

  @override
  Future<(int, int)> renderPage(String pdfPath, int page, double dpi, String outPath,
      {int maxPixels = maxRasterPixels}) async {
    try {
      final r = await _pdf.invokeMapMethod<String, Object?>('render', {
        'path': pdfPath,
        'page': page - 1,
        'dpi': dpi,
        'out': outPath,
        'maxPixels': maxPixels,
      });
      return (r!['width'] as int, r['height'] as int);
    } on PlatformException catch (e) {
      throw ImportException('No se pudo renderizar la página $page: ${e.message}');
    }
  }
}

PdfRasterizer defaultPdfRasterizer() =>
    NativeCapabilities.pdf ? const AndroidPdfRasterizer() : const UnavailablePdfRasterizer();
