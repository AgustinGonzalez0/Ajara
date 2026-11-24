import 'dart:convert';

import 'package:structura_model/structura_model.dart';
import 'package:test/test.dart';

const ai = Source(Provenance.aiDetected, modelId: 'vision_ai_synthetic_test', modelTrainingData: 'synthetic');

BuildingModel sample({List<BuildingElement>? elements, PlanScale? scale}) => BuildingModel(
      id: 'bm1',
      plan: const PlanReference(widthPx: 1000, heightPx: 800, dpi: 200),
      scale: scale,
      levels: [
        Level(id: 'L0', elements: elements ??
            const [
              Wall(id: 'w1', source: ai, confidence: 0.9, start: Point2(10, 10), end: Point2(500, 10), thicknessPx: 12),
              Opening(
                  id: 'd1',
                  source: ai,
                  confidence: 0.7,
                  type: OpeningType.door,
                  footprint: Rect2(100, 4, 160, 16),
                  hostWallId: 'w1'),
              ColumnElement(id: 'c1', source: Source(Provenance.userCreated), footprint: Rect2(300, 300, 320, 320)),
              Stairs(id: 's1', source: ai, confidence: 0.5, footprint: Rect2(600, 400, 700, 600)),
            ]),
      ],
      relations: const [Relation(RelationType.hosts, 'w1', 'd1', Source(Provenance.derived))],
      source: const Source(Provenance.derived),
    );

void main() {
  test('modelo válido sin issues y roundtrip JSON exacto', () {
    final m = sample();
    expect(m.validate(), isEmpty);
    final text = jsonEncode(m.toJson());
    final back = BuildingModel.fromJson(jsonDecode(text) as Map<String, Object?>);
    expect(jsonEncode(back.toJson()), text);
    expect(back.elementById('d1'), isA<Opening>());
    expect((back.elementById('w1') as Wall).heightM, isNull); // desconocido se conserva como null
  });

  test('desconocidos se serializan como null explícito', () {
    final j = sample().toJson();
    expect(j.containsKey('scale'), isTrue);
    expect(j['scale'], isNull);
    final wall = ((j['levels'] as List).first as Map)['elements'] as List;
    expect((wall.first as Map).containsKey('height_m'), isTrue);
  });

  test('sin escala verificada no hay conversión a metros', () {
    const unverified = PlanScale(pxPerUnit: 50, unit: LengthUnit.m, verified: false, source: Source(Provenance.userCreated));
    expect(unverified.pxToMeters(100), isNull);
    const verified = PlanScale(pxPerUnit: 50, unit: LengthUnit.m, verified: true, source: Source(Provenance.userCreated));
    expect(verified.pxToMeters(100), 2.0);
    expect(sample(scale: verified).hasVerifiedScale, isTrue);
  });

  test('validación detecta errores', () {
    final m = sample(elements: const [
      Wall(id: 'w1', source: ai, confidence: 1.4, start: Point2(0, 0), end: Point2(0, 0), thicknessPx: 0),
      Wall(id: 'w1', source: ai, confidence: 0.5, start: Point2(0, 0), end: Point2(10, 0), thicknessPx: 3, heightM: 2.6),
      Opening(id: 'd1', source: ai, type: OpeningType.door, footprint: Rect2(0, 0, 5, 5), hostWallId: 'nope'),
    ]);
    final msgs = m.validate().map((i) => i.message).join(' | ');
    expect(msgs, contains('id duplicado'));
    expect(msgs, contains('confianza fuera de [0,1]'));
    expect(msgs, contains('espesor de muro no positivo'));
    expect(msgs, contains('medida real atribuida a la IA'));
    expect(msgs, contains('muro anfitrión inexistente'));
    expect(msgs, contains('detección de IA sin confianza'));
  });

  test('versión de esquema futura se rechaza', () {
    final j = sample().toJson()..['schema_version'] = 99;
    expect(() => BuildingModel.fromJson(j), throwsFormatException);
  });
}
