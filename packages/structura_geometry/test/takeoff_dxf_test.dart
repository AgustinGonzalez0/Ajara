import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_model/structura_model.dart';
import 'package:test/test.dart';

const src = Source(Provenance.classicDetected);

Wall h(String id, double x0, double x1, double y, [double t = 20]) =>
    Wall(id: id, source: src, start: Point2(x0, y), end: Point2(x1, y), thicknessPx: t);
Wall v(String id, double y0, double y1, double x, [double t = 20]) =>
    Wall(id: id, source: src, start: Point2(x, y0), end: Point2(x, y1), thicknessPx: t);

/// Planta de 10 × 5 m (100 px/m, muros de 20 cm) con un tabique central y una puerta:
/// dos ambientes de 4,80 × 4,80 m. Ventana de 1,20 m en el muro superior.
BuildingModel twoRooms({bool scaled = true}) => BuildingModel(
      id: 'm',
      plan: const PlanReference(widthPx: 1100, heightPx: 600),
      scale: scaled
          ? const PlanScale(pxPerUnit: 100, unit: LengthUnit.m, verified: true, source: Source(Provenance.userCreated))
          : null,
      levels: [
        Level(id: 'L0', elements: [
          h('top', 0, 1000, 0), h('bottom', 0, 1000, 500), v('left', 0, 500, 0), v('right', 0, 500, 1000),
          v('mid1', 0, 200, 500), v('mid2', 280, 500, 500),
          const Opening(
              id: 'd1', source: src, type: OpeningType.door, footprint: Rect2(490, 200, 510, 280), hostWallId: 'mid1'),
          const Opening(
              id: 'w1', source: src, type: OpeningType.window, footprint: Rect2(200, -10, 320, 10), hostWallId: 'top'),
          const ColumnElement(id: 'c1', source: src, footprint: Rect2(-10, -10, 10, 10)),
        ]),
      ],
      source: const Source(Provenance.derived),
    );

void main() {
  group('evidencia de la imagen', evidenceTests);

  group('ambientes', () {
    test('la puerta separa dos ambientes de ~23 m²', () {
      final a = analyzeFloor(twoRooms());
      expect(a.closed, isTrue);
      expect(a.rooms, hasLength(2));
      for (final r in a.rooms) {
        expect(r.areaM2(100), closeTo(23.04, 0.8));
      }
      expect(a.rooms.first.label.x, lessThan(500)); // A1 = el de la izquierda
      expect(a.rooms.map((r) => r.number), [1, 2]);
    });

    BuildingModel without(Set<String> ids) {
      final m = twoRooms();
      return m.copyWith(levels: [
        m.levels.first.copyWith(elements: m.levels.first.elements.where((e) => !ids.contains(e.id)).toList()),
      ]);
    }

    test('un ambiente abierto al exterior deja de contarse; el cerrado sigue', () {
      final a = analyzeFloor(without({'right'}));
      expect(a.rooms, hasLength(1));
      expect(a.rooms.single.label.x, lessThan(500));
    });

    test('contorno abierto: sin ambientes y piso envolvente', () {
      final a = analyzeFloor(without({'right', 'mid1', 'mid2', 'd1'}));
      expect(a.closed, isFalse);
      expect(a.rooms, isEmpty);
    });
  });

  group('cómputo', () {
    test('superficies, muros por espesor, descuento de aberturas y densidad', () {
      final c = computeTakeoff(twoRooms());
      expect(c.coveredAreaM2, closeTo(10.2 * 5.2, 1.5));
      expect(c.usefulAreaM2, closeTo(46.08, 1.6));
      expect(c.walls, hasLength(1));
      final w = c.walls.single;
      expect(w.thicknessM, closeTo(0.20, 1e-9));
      expect(w.lengthM, closeTo(34.2, 1e-9));
      expect(w.grossAreaM2, closeTo(34.2 * 2.6, 1e-9));
      expect(w.openingsAreaM2, closeTo(0.8 * 2.05 + 1.2 * 1.1, 1e-9));
      expect(w.volumeM3, closeTo(w.netAreaM2 * 0.2, 1e-9));
      expect(c.plasterAreaM2, closeTo(2 * w.netAreaM2, 1e-9));
      expect(c.count(OpeningType.door), 1);
      expect(c.count(OpeningType.window), 1);
      expect(c.openings.firstWhere((o) => o.type == OpeningType.window).widthM, closeTo(1.2, 1e-9));
      expect(c.columns, 1);
      expect(c.wallDensityXPct, closeTo(100 * 20 * 0.2 / c.coveredAreaM2, 1e-9));
      expect(c.wallDensityYPct, closeTo(100 * 14.2 * 0.2 / c.coveredAreaM2, 1e-9));
    });

    test('la altura declarada cambia la mampostería, no las superficies', () {
      final a = computeTakeoff(twoRooms());
      final b = computeTakeoff(twoRooms(), params: const TakeoffParams(wallHeightM: 3.0));
      expect(b.walls.single.grossAreaM2, closeTo(34.2 * 3.0, 1e-9));
      expect(b.coveredAreaM2, a.coveredAreaM2);
    });

    test('sin escala verificada no hay cómputo', () {
      expect(() => computeTakeoff(twoRooms(scaled: false)), throwsArgumentError);
    });

    test('planilla CSV para Excel en español', () {
      final csv = computeTakeoff(twoRooms()).toCsv(project: 'Casa');
      expect(csv.startsWith('﻿'), isTrue);
      expect(csv, contains('Superficie cubierta;'));
      expect(csv, contains('Muro 20 cm: largo;34,20;m'));
      expect(csv, contains('Ambientes;A2;'));
      expect(csv, contains('Puerta 0,80 m;1;u'));
    });
  });

  group('DXF', () {
    test('R12 en metros con capas, Y invertida y solo ASCII', () {
      final d = buildDxf(twoRooms(), title: 'Casa Pérez — PB');
      final s = d.content;
      expect(d.inMeters, isTrue);
      expect(s.startsWith('0\r\nSECTION\r\n2\r\nHEADER'), isTrue);
      expect(s.endsWith('0\r\nEOF\r\n'), isTrue);
      expect(s, contains('AC1009'));
      for (final l in ['MUROS', 'MUROS-RELLENO', 'PUERTAS', 'VENTANAS', 'COLUMNAS', 'AMBIENTES', 'ROTULO']) {
        expect(s, contains('2\r\n$l\r\n'));
      }
      expect(s.runes.every((r) => r < 128), isTrue);
      expect(s, contains('Casa Perez - PB'));
      // 6 muros + 1 ventana + 1 columna = 8 polilíneas, cada una con su SEQEND.
      expect('POLYLINE'.allMatches(s).length, 8);
      expect('SEQEND'.allMatches(s).length, 8);
      expect('\r\nARC\r\n'.allMatches(s).length, 1);
      expect(s, contains('A1'));
      expect(s, contains(' m2'));
      // El muro superior (y = 0 px) queda arriba: Y = 600 px / 100 = 6 m (± medio espesor).
      expect(s, contains('20\r\n6.1\r\n'));
    });

    test('sin escala queda en píxeles y lo dice el rótulo', () {
      final d = buildDxf(twoRooms(scaled: false));
      expect(d.inMeters, isFalse);
      expect(d.content, contains('pixeles del plano'));
      expect(d.content, isNot(contains(' m2')));
    });
  });
}

SegmentationResult loadRle(String path) {
  final j = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
  final w = j['width'] as int, h = j['height'] as int;
  final labels = Uint8List(w * h);
  var i = 0;
  for (final row in (j['rle_rows'] as List).cast<List>()) {
    for (var k = 0; k < row.length; k += 2) {
      final v = row[k] as int, n = row[k + 1] as int;
      labels.fillRange(i, i + n, v);
      i += n;
    }
  }
  return SegmentationResult(width: w, height: h, labels: labels);
}

void evidenceTests() {
  test('caso real: muros cortados en la foto se prolongan según la imagen y cierran los 2 ambientes', () {
    final seg = loadRle('test/fixtures/foto_etiquetas_ia_v03.json');
    final r = const BuildingModelBuilder().build(seg,
        modelId: 'm', detectorSource: const Source(Provenance.aiDetected, modelId: 'vision_ai_planos_int8'));
    final rooms = analyzeFloor(r.model).rooms;
    expect(rooms, hasLength(2), reason: 'la puerta separa dos locales cerrados');
    final a = rooms.map((x) => x.areaPx2).toList()..sort();
    expect(a.first / a.last, greaterThan(0.85)); // dos locales parecidos
    expect(r.refinement!.wallsExtended, greaterThan(0));
    // Las puertas siguen siendo vano: ningún muro pasa por encima de la puerta.
    final door = r.model.allElements.whereType<Opening>().firstWhere((o) => o.type == OpeningType.door).footprint;
    for (final w in r.model.allElements.whereType<Wall>()) {
      final b = w.bounds;
      final overlap = math.max(0, math.min(b.right, door.right) - math.max(b.left, door.left)) *
          math.max(0, math.min(b.bottom, door.bottom) - math.max(b.top, door.top));
      expect(overlap, lessThan(0.25 * door.width * door.height), reason: 'muro ${w.id} tapa la puerta');
    }
  });

  test('sin evidencia no se prolonga nada', () {
    final seg = SegmentationResult(width: 200, height: 100, labels: Uint8List(200 * 100));
    final r = extendWallsAlongEvidence([h('a', 20, 80, 50, 10)], seg);
    expect(r.extended, 0);
    expect((r.elements.single as Wall).end.x, 80);
  });

  test('se prolonga hasta donde sigue el muro y se detiene en una ventana', () {
    final labels = Uint8List(300 * 100);
    for (var y = 45; y < 55; y++) {
      for (var x = 10; x < 290; x++) {
        labels[y * 300 + x] = x >= 200 && x < 240 ? ClassId.window : ClassId.wall;
      }
    }
    final r = extendWallsAlongEvidence([h('a', 60, 120, 50, 10)], SegmentationResult(width: 300, height: 100, labels: labels));
    final w = r.elements.single as Wall;
    expect(w.start.x, closeTo(10, 1.5)); // hasta el final del trazo
    expect(w.end.x, closeTo(199, 1.5)); // se frena en la ventana
    expect(r.extended, 2);
  });
}
