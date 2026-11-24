import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:structura_mobile/data/project_models.dart';
import 'package:structura_mobile/data/project_store.dart';
import 'package:structura_mobile/services/analysis_service.dart';
import 'package:structura_mobile/services/photo_importer.dart';
import 'package:structura_vision/structura_vision.dart';

import 'helpers.dart';

/// "Foto" JPG: el plano realista en perspectiva sobre una mesa, con sombra lateral.
Uint8List photoJpg() {
  final plan = img.decodePng(realisticPlanPng())!;
  const w = 1000, h = 800;
  final truth = [const Pt(110, 90), const Pt(900, 130), const Pt(860, 700), const Pt(140, 730)];
  final hm = homography(truth, [const Pt(0, 0), Pt(plan.width - 1.0, 0), Pt(plan.width - 1.0, plan.height - 1.0), Pt(0, plan.height - 1.0)]);
  final out = img.Image(width: w, height: h, numChannels: 3);
  final rnd = math.Random(5);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = applyH(hm, x.toDouble(), y.toDouble());
      var v = (p.x >= 0 && p.y >= 0 && p.x < plan.width - 1 && p.y < plan.height - 1)
          ? plan.getPixel(p.x.round(), p.y.round()).r.toDouble()
          : 60.0;
      v = (v * (0.7 + 0.3 * x / w) + rnd.nextInt(13) - 6).clamp(0, 255);
      out.setPixelRgb(x, y, v.round(), v.round(), v.round());
    }
  }
  return img.encodeJpg(out, quality: 90);
}

void main() {
  test('una foto → hoja detectada → rectificada → motor clásico detecta muros, puerta, ventana y columna', () async {
    final dir = tempDir();
    final photoFile = File('${dir.path}/foto plano.jpg')..writeAsBytesSync(photoJpg());
    final prepared = await preparePhoto(photoFile);
    expect(prepared.paperDetected, isTrue);
    expect(prepared.suggested.points.first.dist(const Pt(110, 90)), lessThan(20));

    final store = ProjectStore(Directory('${dir.path}/projects'));
    var project = await store.create(name: 'Foto');
    project = await PhotoImporter(store).import(project, photoFile, prepared, prepared.suggested);
    final plan = project.activePlan!;
    expect(plan.sourceType, 'photo');
    expect(plan.dpi, isNull); // una foto no tiene resolución verificable
    expect(project.status, ProjectStatus.planImported);

    final job = AnalysisJob(
      projectDir: store.projectDir(project.id).path,
      rasterPath: store.resolve(project.id, plan.rasterFile).path,
      rasterSha256: plan.rasterSha256,
      dpi: null,
      planId: plan.id,
      modelJson: const {},
      modelPath: '',
      runId: 'r1',
    );
    final rec = await executeClassicAnalysis(job);
    expect(rec.status, AnalysisStatus.completed, reason: rec.error);
    expect(rec.counts['wall'], greaterThanOrEqualTo(5));
    expect(rec.counts['door'], 1, reason: '${rec.counts}');
    expect(rec.counts['window'], 1, reason: '${rec.counts}');
    expect(rec.counts['column'], 1, reason: '${rec.counts}');
    expect(File('${job.outDir.path}/model.glb').existsSync(), isTrue);
    expect(File('${job.outDir.path}/confidence.png').existsSync(), isFalse); // el motor clásico no inventa confianza
  });
}
