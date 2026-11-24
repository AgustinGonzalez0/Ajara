import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:structura_mobile/data/project_models.dart';
import 'package:structura_mobile/data/project_store.dart';
import 'package:structura_mobile/services/plan_importer.dart';

import 'helpers.dart';

class FakePdf implements PdfRasterizer {
  @override
  bool get isAvailable => true;
  @override
  Future<int> pageCount(String pdfPath) async => 3;
  @override
  Future<(int, int)> renderPage(String pdfPath, int page, double dpi, String outPath, {int maxPixels = maxRasterPixels}) async {
    final w = (8.5 * dpi).round(), h = (11 * dpi).round();
    File(outPath)
      ..createSync(recursive: true)
      ..writeAsBytesSync(img.encodePng(img.Image(width: w, height: h, numChannels: 3)..clear(img.ColorRgb8(255, 255, 255))));
    return (w, h);
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = tempDir());

  File write(String name, List<int> bytes) => File('${dir.path}/$name')..writeAsBytesSync(bytes);

  group('validación', () {
    test('firma binaria', () {
      expect(sniffType(Uint8List.fromList('%PDF-1.7'.codeUnits)), 'pdf');
      expect(sniffType(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), 'jpg');
      expect(sniffType(Uint8List.fromList([0x49, 0x49, 0x2A, 0x00])), 'tiff');
      expect(sniffType(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('rechaza extensión no soportada, vacío y contenido que no coincide', () async {
      expect(() => validatePlanFile(write('a.docx', [1, 2])), throwsA(isA<ImportException>()));
      expect(() => validatePlanFile(write('vacio.png', [])), throwsA(isA<ImportException>()));
      final fakePdf = write('falso.pdf', img.encodePng(img.Image(width: 2, height: 2)));
      await expectLater(validatePlanFile(fakePdf), throwsA(isA<ImportException>().having((e) => e.message, 'msg', contains('no coincide'))));
      expect(await validatePlanFile(write('ok.png', img.encodePng(img.Image(width: 2, height: 2)))), 'png');
    });
  });

  group('rasterización canónica', () {
    test('transparencia → blanco y salida RGB', () {
      final rgba = img.Image(width: 4, height: 4, numChannels: 4)..clear(img.ColorRgba8(0, 0, 0, 0));
      rgba.setPixelRgba(0, 0, 0, 0, 0, 255);
      final r = canonicalizeRaster(img.encodePng(rgba), 'png');
      final out = img.decodePng(r.png)!;
      expect(out.numChannels, 3);
      expect(out.getPixel(0, 0).r, 0);
      expect(out.getPixel(3, 3).r, 255);
    });

    test('16 bits → 8 bits', () {
      final g16 = img.Image(width: 3, height: 3, numChannels: 1, format: img.Format.uint16);
      for (final px in g16) {
        px.r = 65535; // clear() no escribe en imágenes de un canal
      }
      final out = img.decodePng(canonicalizeRaster(img.encodePng(g16), 'png').png)!;
      expect(out.format, img.Format.uint8);
      expect(out.getPixel(1, 1).r, 255);
    });

    test('JPG con orientación EXIF se endereza', () {
      final im = img.Image(width: 40, height: 20, numChannels: 3);
      im.exif.imageIfd.orientation = 6; // rotar 90°
      final r = canonicalizeRaster(img.encodeJpg(im), 'jpg');
      expect((r.width, r.height), (20, 40));
    });

    test('TIFF de una página', () {
      final r = canonicalizeRaster(img.encodeTiff(img.Image(width: 7, height: 5, numChannels: 3)), 'tiff');
      expect((r.width, r.height), (7, 5));
    });
  });

  group('importación al proyecto', () {
    test('PNG: copia original, raster canónico, hashes y estado', () async {
      final store = ProjectStore(Directory('${dir.path}/projects'));
      final p = await store.create(name: 'P');
      final src = write('Planta baja ñ.png', codedPlanPng(w: 300, h: 200));
      final m = await PlanImporter(store, const UnavailablePdfRasterizer()).import(p, src);
      final plan = m.activePlan!;
      expect(m.status, ProjectStatus.planImported);
      expect((plan.width, plan.height, plan.sourceType, plan.dpiSource), (300, 200, 'png', 'unknown'));
      expect(plan.dpi, isNull); // no se inventa resolución
      final raster = store.resolve(p.id, plan.rasterFile);
      expect(sha256.convert(raster.readAsBytesSync()).toString(), plan.rasterSha256);
      expect(sha256.convert(store.resolve(p.id, plan.originalFile).readAsBytesSync()).toString(),
          sha256.convert(src.readAsBytesSync()).toString());
      expect((await store.history(p.id)).last['action'], 'plan_imported');
    });

    test('PDF con rasterizador nativo: página y DPI registrados', () async {
      final store = ProjectStore(Directory('${dir.path}/projects'));
      final p = await store.create(name: 'P');
      final pdf = write('plano.pdf', '%PDF-1.7\n%fake'.codeUnits);
      final m = await PlanImporter(store, FakePdf()).import(p, pdf, page: 2, dpi: 50);
      expect((m.activePlan!.page, m.activePlan!.dpi, m.activePlan!.dpiSource), (2, 50.0, 'pdf_render'));
      expect(m.activePlan!.width, 425);
      await expectLater(PlanImporter(store, FakePdf()).import(m, pdf, page: 9), throwsA(isA<ImportException>()));
    });

    test('PDF sin rasterizador disponible: error explícito', () async {
      final store = ProjectStore(Directory('${dir.path}/projects'));
      final p = await store.create(name: 'P');
      final pdf = write('plano.pdf', '%PDF-1.7\n%fake'.codeUnits);
      await expectLater(PlanImporter(store, const UnavailablePdfRasterizer()).import(p, pdf),
          throwsA(isA<ImportException>().having((e) => e.message, 'm', contains('no está disponible'))));
    });
  });
}
