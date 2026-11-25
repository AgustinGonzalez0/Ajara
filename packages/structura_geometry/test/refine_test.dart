import 'dart:convert';
import 'dart:io';

import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_model/structura_model.dart';
import 'package:test/test.dart';

const src = Source(Provenance.classicDetected);

Wall h(String id, double x0, double x1, double y, [double t = 10]) =>
    Wall(id: id, source: src, start: Point2(x0, y), end: Point2(x1, y), thicknessPx: t);
Wall v(String id, double y0, double y1, double x, [double t = 10]) =>
    Wall(id: id, source: src, start: Point2(x, y0), end: Point2(x, y1), thicknessPx: t);

Map<String, BuildingElement> refined(List<BuildingElement> els, [RefineReport? out]) {
  final r = const GeometryRefiner().refine(els);
  if (out != null) {
    out
      ..junctionsClosed = r.report.junctionsClosed
      ..wallsAligned = r.report.wallsAligned
      ..segmentsJoined = r.report.segmentsJoined
      ..thicknessUnified = r.report.thicknessUnified
      ..openingsFitted = r.report.openingsFitted
      ..openingsHosted = r.report.openingsHosted
      ..fragmentsRemoved = r.report.fragmentsRemoved;
  }
  return {for (final e in r.elements) e.id: e};
}

void main() {
  test('esquina en L abierta: ambos muros llegan a la cara exterior del otro', () {
    final rep = RefineReport();
    final m = refined([h('a', 0, 100, 10), v('b', 20, 200, 110)], rep);
    final a = m['a'] as Wall, b = m['b'] as Wall;
    expect(a.end.x, 115); // eje de b (110) + medio espesor
    expect(b.start.y, 5); // eje de a (10) - medio espesor
    expect(rep.junctionsClosed, greaterThanOrEqualTo(1));
  });

  test('fachada en escalón: tramos paralelos cercanos quedan en un mismo eje', () {
    final rep = RefineReport();
    final m = refined([h('a', 0, 100, 10), h('b', 300, 400, 13)], rep);
    expect((m['a'] as Wall).start.y, (m['b'] as Wall).start.y);
    expect((m['a'] as Wall).start.y, closeTo(11.5, 1e-9)); // promedio ponderado por largo
    expect(rep.wallsAligned, 2);
  });

  test('espesores 9 / 10 / 11 se unifican; 30 queda aparte', () {
    final m = refined([h('a', 0, 100, 0, 9), h('b', 0, 100, 200, 10), h('c', 0, 300, 400, 11), h('d', 0, 100, 600, 30)]);
    expect((m['a'] as Wall).thicknessPx, (m['c'] as Wall).thicknessPx);
    expect((m['b'] as Wall).thicknessPx, (m['c'] as Wall).thicknessPx);
    expect((m['d'] as Wall).thicknessPx, 30);
  });

  test('ventana desencajada: toma el espesor y el eje del muro y se pega a los tramos', () {
    final rep = RefineReport();
    final win = Opening(id: 'n1', source: src, type: OpeningType.window, footprint: const Rect2(102, 7, 138, 14));
    final m = refined([h('a', 0, 100, 10), h('b', 140, 240, 10), win], rep);
    final o = m['n1'] as Opening;
    expect([o.footprint.left, o.footprint.top, o.footprint.right, o.footprint.bottom], [100, 5, 140, 15]);
    expect(o.hostWallId, isNotNull);
    expect(rep.openingsHosted, 1);
    expect(m.containsKey('b'), isTrue); // el hueco con ventana NO se rellena
  });

  test('tramo cortado sin abertura se une; el anfitrión de la abertura pasa al muro que queda', () {
    final rep = RefineReport();
    final door = Opening(
        id: 'd1', source: src, type: OpeningType.door, footprint: const Rect2(300, 5, 380, 15), hostWallId: 'b');
    final m = refined([h('a', 0, 100, 10), h('b', 108, 300, 10), h('c', 380, 500, 10), door], rep);
    expect(m.containsKey('b'), isFalse);
    expect((m['a'] as Wall).end.x, 300);
    expect((m['d1'] as Opening).hostWallId, 'a');
    expect(rep.segmentsJoined, 1);
  });

  test('mancha corta y aislada se elimina', () {
    final rep = RefineReport();
    final m = refined([h('a', 0, 300, 10), h('blob', 600, 615, 400)], rep);
    expect(m.containsKey('blob'), isFalse);
    expect(rep.fragmentsRemoved, 1);
  });

  test('piso solo dentro de una planta en L; planta abierta usa el rectángulo envolvente', () {
    // L: 0..200 × 0..100 más 0..100 × 100..200 (falta el cuadrante inferior derecho).
    final walls = [
      h('t', 0, 200, 0), h('m', 100, 200, 100), h('bt', 0, 100, 200),
      v('l', 0, 200, 0), v('r', 0, 100, 200), v('mid', 100, 200, 100),
    ];
    final model = BuildingModel(
        id: 'x',
        plan: const PlanReference(widthPx: 300, heightPx: 300),
        levels: [Level(id: 'L0', elements: walls)],
        source: const Source(Provenance.derived));
    final rects = floorRects(model);
    final area = rects.fold<double>(0, (s, r) => s + r.width * r.height);
    final bboxArea = 210.0 * 210.0;
    expect(area, lessThan(0.85 * bboxArea)); // no cubre el cuadrante vacío
    expect(area, greaterThan(0.6 * bboxArea));
    final open = BuildingModel(
        id: 'y',
        plan: const PlanReference(widthPx: 300, heightPx: 300),
        levels: [Level(id: 'L0', elements: walls.where((w) => w.id != 'r').toList())],
        source: const Source(Provenance.derived));
    expect(floorRects(open), hasLength(1));
  });

  test('muñones cortos montados sobre un muro se eliminan; una T verdadera se conserva', () {
    final rep = RefineReport();
    final m = refined([
      h('top', 0, 400, 10),
      v('stub1', 2, 22, 150), // 2 espesores, casi todo dentro de "top"
      v('stub2', 4, 20, 300),
      v('tee', 10, 300, 200), // muro interior real en T
      v('cross', -6, 20, 350, 6), // corto y atravesando el muro de lado a lado
      h('bump', 250, 268, 11, 17), // ensanche local del trazo sobre el muro (foto)
    ], rep);
    expect(m.containsKey('cross'), isFalse);
    expect(m.containsKey('bump'), isFalse);
    expect(m.containsKey('stub1'), isFalse);
    expect(m.containsKey('stub2'), isFalse);
    expect(m.containsKey('tee'), isTrue);
    expect((m['tee'] as Wall).start.y, 5); // la T llega a la cara del muro superior
  });

  test('muro partido en tramos de distinto espesor (foto) se une en uno solo', () {
    final rep = RefineReport();
    final m = refined([h('a', 0, 200, 10, 6), h('b', 200, 260, 11, 10), h('c', 262, 300, 10, 9), h('d', 300, 500, 10, 10)], rep);
    final walls = m.values.whereType<Wall>().toList();
    expect(walls, hasLength(1));
    expect(walls.single.start.x, 0);
    expect(walls.single.end.x, 500);
    expect(walls.single.thicknessPx, inInclusiveRange(7.5, 10));
  });

  test('caso real: rebanadas verticales sobre el muro superior se vuelven un muro continuo', () {
    final j = jsonDecode(File('test/fixtures/foto_rebanadas_refinado.json').readAsStringSync()) as Map<String, Object?>;
    final model = BuildingModel.fromJson(j);
    final r = const GeometryRefiner().refine(model.allElements.toList());
    final walls = r.elements.whereType<Wall>().toList();
    // Ninguna pieza vertical corta dentro de la banda del muro superior (eje y≈52, espesor 18).
    final slices = walls.where((w) => w.start.x == w.end.x && w.start.y < 66 && w.end.y < 70 && w.lengthPx < 30);
    expect(slices, isEmpty);
    // El muro superior cubre desde la ventana (x=164) hasta la esquina derecha sin huecos.
    final top = walls.where((w) => w.start.y == w.end.y && (w.start.y - 52).abs() < 9).toList()
      ..sort((a, b) => a.start.x.compareTo(b.start.x));
    var reach = 164.0;
    for (final w in top) {
      if (w.end.x <= reach) continue;
      expect(w.start.x, lessThanOrEqualTo(reach + 1), reason: 'hueco en x=$reach');
      reach = w.end.x;
    }
    expect(reach, greaterThanOrEqualTo(958));
    expect(r.report.slicesReoriented, greaterThan(0));
  });

  test('resumen legible solo con lo que ocurrió', () {
    final rep = RefineReport()..junctionsClosed = 1;
    expect(rep.summary(), ['1 esquina cerrada']);
  });
}
