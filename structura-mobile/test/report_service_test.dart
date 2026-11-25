import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:structura_geometry/structura_geometry.dart' show computeTakeoff;
import 'package:structura_mobile/app/heat_scale.dart';
import 'package:structura_mobile/services/report_service.dart';
import 'package:structura_model/structura_model.dart';
import 'package:structura_sim/structura_sim.dart';

const user = Source(Provenance.userCreated);
const scale = PlanScale(pxPerUnit: 100, unit: LengthUnit.m, verified: true, source: Source(Provenance.userCreated, note: 'cota 10 m'));

/// Caja de 10 × 8 m con una puerta y una columna (escala 100 px/m).
BuildingModel box() => BuildingModel(
      id: 'b',
      plan: const PlanReference(widthPx: 1100, heightPx: 900),
      scale: scale,
      levels: [
        Level(id: 'L0', elements: [
          const Wall(id: 'top', source: user, start: Point2(10, 10), end: Point2(1010, 10), thicknessPx: 20),
          const Wall(id: 'bottom', source: user, start: Point2(10, 810), end: Point2(1010, 810), thicknessPx: 20),
          const Wall(id: 'left', source: user, start: Point2(10, 10), end: Point2(10, 810), thicknessPx: 20),
          const Wall(id: 'right', source: user, start: Point2(1010, 10), end: Point2(1010, 810), thicknessPx: 20),
          const Opening(id: 'd1', source: user, type: OpeningType.door, footprint: Rect2(400, 0, 490, 20), hostWallId: 'top'),
          const ColumnElement(id: 'c1', source: user, footprint: Rect2(500, 400, 530, 430)),
        ]),
      ],
      source: const Source(Provenance.derived),
    );

ReportFonts fonts() => ReportFonts(
      File('assets/fonts/roboto-regular.ttf').readAsBytesSync(),
      File('assets/fonts/roboto-bold.ttf').readAsBytesSync(),
    );

Map<String, Object?> screening({bool tsunami = true, bool wind = false}) {
  const building = BuildingInput(floors: 2, storyHeightM: 2.8, material: WallMaterial.confinedMasonry, wallThicknessM: 0.18);
  final r = runScreening(box(), building,
      seismic: const SeismicInput(pgaG: 0.35, soil: SoilClass.soft),
      tsunami: tsunami ? const TsunamiInput(inundationDepthM: 2.5, direction: FlowDirection.plusX) : null,
      wind: wind ? const WindInput(speedMs: 40, direction: FlowDirection.minusY) : null);
  // Igual que en disco: JSON ida y vuelta.
  return (jsonDecode(jsonEncode(r.toJson())) as Map).cast<String, Object?>();
}

ReportJob job(Map<String, Object?> s, {Uint8List? planImage, Map<String, Object?>? takeoff}) => ReportJob(
      projectName: 'Casa Pérez — Ñuñoa',
      projectDescription: 'Vivienda de 2 plantas',
      buildingType: 'Residencial',
      planName: 'Foto del plano 24-11-2026 10.15.jpg',
      planSourceType: 'photo',
      planSha256: 'a' * 64,
      planWidth: 1100,
      planHeight: 900,
      analysisId: 'run_1',
      analysisAt: DateTime.utc(2026, 11, 24, 13),
      engine: const {'id': 'classic_cv', 'engine': 'classic', 'production_ready': false, 'trust_label': 'motor clásico sin validación'},
      screening: s,
      buildingModel: box().toJson(),
      planImage: planImage,
      takeoff: takeoff,
      fonts: fonts(),
      generatedAt: DateTime.utc(2026, 11, 24, 14),
    );

void main() {
  test('formato de valores igual al de la app', () {
    expect(indicatorValueText({'value': 0.456, 'unit': ''}), '0,46');
    expect(indicatorValueText({'value': 12.0, 'unit': ''}), '> 10 ×');
    expect(indicatorValueText({'value': 12.0, 'unit': '%'}), '12,00 %');
    expect(indicatorValueText({'value': null, 'unit': ''}), 'sin capacidad');
    expect(pdfSafe('Desde la izquierda del plano (→)'), 'Desde la izquierda del plano (->)');
  });

  test('resumen: un renglón por peligro con la relación más alta', () {
    final s = screening(wind: true);
    final rows = summaryRows(s);
    expect(rows.map((r) => r.hazard), ['Sismo / terremoto', 'Tsunami', 'Viento']);
    final seismic = (s['results'] as List).first as Map;
    expect(rows.first.status, seismic['overall']);
    // La peor relación sin unidades del sismo es la mayor entre dc_x, dc_y y el muro más exigido.
    final ratios = (seismic['indicators'] as List)
        .cast<Map>()
        .where((i) => (i['unit'] as String).isEmpty)
        .map((i) => (i['value'] as num).toDouble());
    final worst = ratios.reduce((a, b) => a > b ? a : b);
    expect(rows.first.worst, endsWith(indicatorValueText({'value': worst, 'unit': ''})));
  });

  test('datos declarados legibles (sin nombres internos)', () {
    final rows = {for (final r in declaredRows(screening())) r[0]: r[1]};
    expect(rows['Pisos'], '2');
    expect(rows['Altura de piso'], '2,80 m');
    expect(rows['Material de muros'], WallMaterial.confinedMasonry.label);
    expect(rows['Espesor de muros'], '18 cm (declarado)');
    expect(rows['Sismo: suelo'], startsWith(SoilClass.soft.label));
    expect(rows['Tsunami: velocidad del flujo'], contains('√(g·h)'));
    expect(rows['Tsunami: dirección del agua'], isNot(contains('→')));
    expect(rows['Viento'], 'no evaluado');
  });

  test('procedencia: motor, elementos y escala verificada', () {
    final rows = {for (final r in provenanceRows(job(screening()), box())) r[0]: r[1]};
    expect(rows['Detección'], contains('sin IA'));
    expect(rows['Validación del detector'], contains('sin validación'));
    expect(rows['Elementos detectados'], contains('muros 4'));
    expect(rows['Elementos detectados'], contains('puertas 1'));
    expect(rows['Escala'], contains('100,0 px/m'));
    expect(rows['Escala'], contains('cota 10 m'));
  });

  test('genera un PDF válido con imagen del plano y todos los peligros', () async {
    final plan = img.Image(width: 1100, height: 900, numChannels: 3);
    img.fill(plan, color: img.ColorRgb8(255, 255, 255));
    final thumb = thumbnailForReport(Uint8List.fromList(img.encodePng(plan)), maxSide: 600)!;
    expect(img.decodeJpg(thumb)!.width, 600);
    final bytes = await buildScreeningPdf(job(screening(wind: true), planImage: thumb));
    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(latin1.decode(bytes.sublist(bytes.length - 8)).trim(), endsWith('%%EOF'));
    expect(bytes.length, greaterThan(20000)); // fuentes embebidas + imagen
  });

  test('cómputo métrico en el informe: filas legibles y PDF válido', () async {
    final t = (jsonDecode(jsonEncode(computeTakeoff(box()).toJson())) as Map).cast<String, Object?>();
    final rows = takeoffRows(t);
    expect(rows.first[0], 'Superficie cubierta');
    expect(rows.first[1], endsWith('m²'));
    expect(rows.map((r) => r[0]), contains('Densidad de muros'));
    expect(rows.any((r) => r[0].startsWith('Muro ')), isTrue);
    final bytes = await buildScreeningPdf(job(screening(), takeoff: t));
    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
  });

  test('sin tsunami ni viento también se genera', () async {
    final bytes = await buildScreeningPdf(job(screening(tsunami: false)));
    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
  });

  test('escala de colores: verde, amarillo en 0,7, rojo desde 1', () {
    int g(int c) => (c >> 8) & 0xFF;
    int r(int c) => (c >> 16) & 0xFF;
    expect(g(heatColor(0)) > r(heatColor(0)), isTrue);
    expect(r(heatColor(0.7)), greaterThan(200));
    expect(g(heatColor(0.7)), greaterThan(150));
    expect(g(heatColor(1.0)), lessThan(60));
    expect(heatColor(double.infinity), 0xFFB3261E);
  });
}
