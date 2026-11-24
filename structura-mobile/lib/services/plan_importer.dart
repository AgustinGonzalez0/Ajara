/// Importación de planos: validación, rasterización canónica y registro en el proyecto.
///
/// Misma normalización que structura-data/tools/import_plans.py: orientación EXIF
/// aplicada, transparencia compuesta sobre blanco, 16 bits → 8 bits, salida PNG
/// RGB. Los TIFF multipágina se rechazan (no se pierden páginas en silencio).
/// Los PDF se rasterizan a un DPI explícito con [PdfRasterizer].
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/project_models.dart';
import '../data/project_store.dart';

const supportedExtensions = ['pdf', 'png', 'jpg', 'jpeg', 'tif', 'tiff'];
const maxImportBytes = 200 * 1024 * 1024;
const maxRasterPixels = 60 * 1000 * 1000;
const defaultPdfDpi = 200.0; // igual que structura-data (consistencia de escala en px)

class ImportException implements Exception {
  final String message;
  const ImportException(this.message);
  @override
  String toString() => message;
}

/// Tipo detectado por la firma binaria (no se confía en la extensión).
String? sniffType(Uint8List head) {
  bool starts(List<int> sig) => head.length >= sig.length && List.generate(sig.length, (i) => head[i] == sig[i]).every((x) => x);
  if (starts([0x25, 0x50, 0x44, 0x46])) return 'pdf'; // %PDF
  if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
  if (starts([0xFF, 0xD8, 0xFF])) return 'jpg';
  if (starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])) return 'tiff';
  return null;
}

/// Valida un archivo antes de importarlo. Devuelve el tipo real.
Future<String> validatePlanFile(File file) async {
  if (!await file.exists()) throw const ImportException('El archivo no existe o no es accesible.');
  final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
  if (!supportedExtensions.contains(ext)) {
    throw ImportException('Formato .$ext no soportado. Usá PDF, PNG, JPG o TIFF.');
  }
  final size = await file.length();
  if (size == 0) throw const ImportException('El archivo está vacío.');
  if (size > maxImportBytes) throw ImportException('El archivo supera ${maxImportBytes ~/ (1024 * 1024)} MB.');
  final raf = await file.open();
  final head = await raf.read(16);
  await raf.close();
  final type = sniffType(head);
  if (type == null) throw const ImportException('El contenido no corresponde a un PDF, PNG, JPG o TIFF válido.');
  final normalizedExt = ext == 'jpeg' ? 'jpg' : (ext == 'tif' ? 'tiff' : ext);
  if (type != normalizedExt) {
    throw ImportException('La extensión .$ext no coincide con el contenido ($type).');
  }
  return type;
}

class RasterResult {
  final Uint8List png;
  final int width;
  final int height;
  const RasterResult(this.png, this.width, this.height);
}

/// Decodifica PNG/JPG/TIFF a PNG RGB canónico (ejecutar en isolate).
RasterResult canonicalizeRaster(Uint8List bytes, String type) {
  img.Image? image;
  switch (type) {
    case 'png':
      image = img.decodePng(bytes);
    case 'jpg':
      image = img.decodeJpg(bytes);
      if (image != null) image = img.bakeOrientation(image);
    case 'tiff':
      final dec = img.TiffDecoder();
      final info = dec.startDecode(bytes);
      if (info == null) throw const ImportException('TIFF ilegible.');
      if (info.numFrames > 1) {
        throw ImportException('El TIFF tiene ${info.numFrames} páginas; separalas o convertilas a PDF '
            'para no perder páginas en silencio.');
      }
      image = dec.decodeFrame(0);
    default:
      throw ImportException('Tipo $type no es raster.');
  }
  if (image == null) throw const ImportException('No se pudo decodificar la imagen (¿archivo dañado?).');
  if (image.width * image.height > maxRasterPixels) {
    throw ImportException('La imagen tiene ${(image.width * image.height / 1e6).toStringAsFixed(0)} MP; '
        'el máximo es ${maxRasterPixels ~/ 1000000} MP.');
  }
  if (image.format != img.Format.uint8) image = image.convert(format: img.Format.uint8);
  if (image.hasPalette) image = image.convert(numChannels: image.numChannels);
  if (image.numChannels == 4 || image.hasAlpha) {
    final white = img.Image(width: image.width, height: image.height, numChannels: 3)
      ..clear(img.ColorRgb8(255, 255, 255));
    image = img.compositeImage(white, image);
  }
  if (image.numChannels != 3) image = image.convert(numChannels: 3);
  return RasterResult(img.encodePng(image, level: 6), image.width, image.height);
}

/// Nivel superior: el cierre solo captura sus argumentos (enviables entre isolates).
Future<RasterResult> _canonicalizeInIsolate(Uint8List bytes, String type) => Isolate.run(() => canonicalizeRaster(bytes, type));

/// Rasterizador de PDF (implementación nativa por plataforma).
abstract interface class PdfRasterizer {
  bool get isAvailable;
  Future<int> pageCount(String pdfPath);

  /// Renderiza la página [page] (1-based) a PNG en [outPath]. Devuelve (ancho, alto).
  Future<(int, int)> renderPage(String pdfPath, int page, double dpi, String outPath, {int maxPixels});
}

class UnavailablePdfRasterizer implements PdfRasterizer {
  const UnavailablePdfRasterizer();
  @override
  bool get isAvailable => false;
  @override
  Future<int> pageCount(String pdfPath) =>
      Future.error(const ImportException('La lectura de PDF no está disponible en esta plataforma.'));
  @override
  Future<(int, int)> renderPage(String pdfPath, int page, double dpi, String outPath, {int maxPixels = maxRasterPixels}) =>
      Future.error(const ImportException('La lectura de PDF no está disponible en esta plataforma.'));
}

class PlanImporter {
  final ProjectStore store;
  final PdfRasterizer pdf;
  static const _uuid = Uuid();
  const PlanImporter(this.store, this.pdf);

  /// Importa [file] (página [page] si es PDF) al proyecto y lo deja como plano activo.
  Future<ProjectManifest> import(ProjectManifest project, File file, {String? originalName, int? page, double dpi = defaultPdfDpi}) async {
    final type = await validatePlanFile(file);
    final planId = _uuid.v4().substring(0, 8);
    final ext = type == 'tiff' ? 'tif' : type;
    final dir = 'sources/$planId';
    final originalRel = '$dir/original.$ext';
    final rasterRel = '$dir/raster.png';
    final original = store.resolve(project.id, originalRel);
    await original.parent.create(recursive: true);
    await file.copy(original.path);
    final originalSha = sha256.convert(await original.readAsBytes()).toString();

    final RasterResult raster;
    double? dpiValue;
    var dpiSource = 'unknown';
    if (type == 'pdf') {
      if (!pdf.isAvailable) throw const ImportException('La lectura de PDF no está disponible en esta plataforma.');
      final pages = await pdf.pageCount(original.path);
      final pg = page ?? 1;
      if (pg < 1 || pg > pages) throw ImportException('Página $pg fuera de rango (el PDF tiene $pages).');
      final out = store.resolve(project.id, rasterRel);
      final (w, h) = await pdf.renderPage(original.path, pg, dpi, out.path);
      raster = RasterResult(await out.readAsBytes(), w, h);
      dpiValue = dpi;
      dpiSource = 'pdf_render';
    } else {
      final bytes = await original.readAsBytes();
      raster = await _canonicalizeInIsolate(bytes, type);
      await store.writeBytes(project.id, rasterRel, raster.png);
    }
    final plan = PlanSource(
      id: planId,
      originalName: originalName ?? p.basename(file.path),
      originalFile: originalRel,
      originalSha256: originalSha,
      sourceType: type,
      page: type == 'pdf' ? (page ?? 1) : null,
      rasterFile: rasterRel,
      rasterSha256: sha256.convert(raster.png).toString(),
      width: raster.width,
      height: raster.height,
      dpi: dpiValue,
      dpiSource: dpiSource,
      importedAt: DateTime.now().toUtc(),
    );
    final updated = await store.save(project.copyWith(
      plans: [...project.plans, plan],
      activePlanId: plan.id,
      status: project.status == ProjectStatus.draft ? ProjectStatus.planImported : project.status,
    ));
    await store.appendHistory(project.id, 'plan_imported',
        {'plan_id': plan.id, 'name': plan.originalName, 'type': type, 'page': plan.page, 'size': [plan.width, plan.height]});
    return updated;
  }
}
