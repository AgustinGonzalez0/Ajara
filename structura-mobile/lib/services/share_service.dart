/// Compartir archivos del proyecto (GLB, PDF) con la hoja de compartir del sistema.
///
/// No sube nada a ningún servidor: el sistema le entrega el archivo a la app que el
/// usuario elija (correo, mensajería, Drive, "Guardar en archivos", etc.).
library;

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'report_service.dart';

abstract class FileSharer {
  Future<void> shareFile(String path, {required String mimeType, String? subject, String? text});
}

class SystemFileSharer implements FileSharer {
  const SystemFileSharer();
  @override
  Future<void> shareFile(String path, {required String mimeType, String? subject, String? text}) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(path, mimeType: mimeType)], subject: subject, text: text));
  }
}

const mimeGlb = 'model/gltf-binary';
const mimePdf = 'application/pdf';

/// Fuentes del informe (Roboto, Apache 2.0) empaquetadas en la app: sin red.
Future<ReportFonts> loadBundledReportFonts([AssetBundle? bundle]) async {
  final b = bundle ?? rootBundle;
  final r = await b.load('assets/fonts/roboto-regular.ttf');
  final w = await b.load('assets/fonts/roboto-bold.ttf');
  return ReportFonts(r.buffer.asUint8List(r.offsetInBytes, r.lengthInBytes), w.buffer.asUint8List(w.offsetInBytes, w.lengthInBytes));
}
