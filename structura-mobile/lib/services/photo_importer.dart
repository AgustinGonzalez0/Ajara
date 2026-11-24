/// Importación de un plano desde UNA foto tomada con el celular.
///
/// 1. [preparePhoto] (isolate): decodifica, endereza por EXIF, reduce a ≤ 2400 px y
///    sugiere las 4 esquinas de la hoja (structura_vision, sin IA).
/// 2. El usuario confirma o ajusta las esquinas en pantalla.
/// 3. [rectifyPhoto] (isolate): corrige la perspectiva y normaliza la iluminación
///    (papel blanco uniforme) → PNG canónico que usan todos los motores.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:structura_vision/structura_vision.dart';
import 'package:uuid/uuid.dart';

import '../data/project_models.dart';
import '../data/project_store.dart';
import 'plan_importer.dart';

const photoMaxSide = 2400;

class PreparedPhoto {
  final int width;
  final int height;
  final Uint8List rgb; // reducida, enderezada
  final Quad suggested;
  final bool paperDetected;
  const PreparedPhoto(this.width, this.height, this.rgb, this.suggested, this.paperDetected);
}

PreparedPhoto preparePhotoSync(Uint8List bytes) {
  var image = img.decodeImage(bytes);
  if (image == null) throw const ImportException('No se pudo leer la foto (¿formato no soportado?).');
  image = img.bakeOrientation(image);
  final long = image.width > image.height ? image.width : image.height;
  if (long > photoMaxSide) {
    final k = photoMaxSide / long;
    image = img.copyResize(image, width: (image.width * k).round(), height: (image.height * k).round(),
        interpolation: img.Interpolation.average);
  }
  if (image.format != img.Format.uint8 || image.numChannels != 3) {
    image = image.convert(format: img.Format.uint8, numChannels: 3);
  }
  final rgb = image.getBytes(order: img.ChannelOrder.rgb);
  final det = detectPaperQuad(GrayImage.fromRgb(image.width, image.height, rgb));
  return PreparedPhoto(image.width, image.height, rgb, det.quad, det.detected);
}

Future<PreparedPhoto> preparePhoto(File file) async => _prepareInIsolate(await file.readAsBytes());

// Funciones de nivel superior: el cierre solo captura sus argumentos (enviables).
Future<PreparedPhoto> _prepareInIsolate(Uint8List bytes) => Isolate.run(() => preparePhotoSync(bytes));
Future<RasterResult> _rectifyInIsolate(PreparedPhoto photo, Quad quad) => Isolate.run(() => rectifyPhotoSync(photo, quad));

RasterResult rectifyPhotoSync(PreparedPhoto photo, Quad quad) {
  final (w, h, rgb) = warpPerspective(photo.width, photo.height, photo.rgb, quad, maxSide: photoMaxSide);
  final clean = normalizeIllumination(GrayImage.fromRgb(w, h, rgb));
  final out = img.Image.fromBytes(width: w, height: h, bytes: clean.toRgb().buffer, numChannels: 3);
  return RasterResult(img.encodePng(out, level: 6), w, h);
}

class PhotoImporter {
  final ProjectStore store;
  static const _uuid = Uuid();
  const PhotoImporter(this.store);

  Future<ProjectManifest> import(ProjectManifest project, File photo, PreparedPhoto prepared, Quad quad,
      {String? originalName}) async {
    final planId = _uuid.v4().substring(0, 8);
    final ext = p.extension(photo.path).replaceFirst('.', '').toLowerCase();
    final originalRel = 'sources/$planId/original.${ext.isEmpty ? 'jpg' : ext}';
    final rasterRel = 'sources/$planId/raster.png';
    final original = store.resolve(project.id, originalRel);
    await original.parent.create(recursive: true);
    await photo.copy(original.path);
    final raster = await _rectifyInIsolate(prepared, quad);
    await store.writeBytes(project.id, rasterRel, raster.png);
    final plan = PlanSource(
      id: planId,
      originalName: originalName ?? p.basename(photo.path),
      originalFile: originalRel,
      originalSha256: sha256.convert(await original.readAsBytes()).toString(),
      sourceType: 'photo',
      rasterFile: rasterRel,
      rasterSha256: sha256.convert(raster.png).toString(),
      width: raster.width,
      height: raster.height,
      dpiSource: 'unknown',
      importedAt: DateTime.now().toUtc(),
    );
    final updated = await store.save(project.copyWith(
      plans: [...project.plans, plan],
      activePlanId: plan.id,
      status: project.status == ProjectStatus.draft ? ProjectStatus.planImported : project.status,
    ));
    await store.appendHistory(project.id, 'photo_imported', {
      'plan_id': planId,
      'quad': quad.points.map((q) => [q.x, q.y]).toList(),
      'paper_detected_auto': prepared.paperDetected,
      'size': [raster.width, raster.height],
    });
    return updated;
  }
}
