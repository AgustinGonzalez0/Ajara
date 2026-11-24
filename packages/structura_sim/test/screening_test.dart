import 'dart:math' as math;

import 'package:structura_model/structura_model.dart';
import 'package:structura_sim/structura_sim.dart';
import 'package:test/test.dart';

const user = Source(Provenance.userCreated);
const scale = PlanScale(pxPerUnit: 100, unit: LengthUnit.m, verified: true, source: user);

/// Caja de 10 × 8 m (ejes), muros de 0,20 m, escala 100 px/m.
BuildingModel box({bool withRightWall = true, PlanScale? s = scale}) => BuildingModel(
      id: 'b',
      plan: const PlanReference(widthPx: 1100, heightPx: 900),
      scale: s,
      levels: [
        Level(id: 'L0', elements: [
          const Wall(id: 'top', source: user, start: Point2(10, 10), end: Point2(1010, 10), thicknessPx: 20),
          const Wall(id: 'bottom', source: user, start: Point2(10, 810), end: Point2(1010, 810), thicknessPx: 20),
          const Wall(id: 'left', source: user, start: Point2(10, 10), end: Point2(10, 810), thicknessPx: 20),
          if (withRightWall)
            const Wall(id: 'right', source: user, start: Point2(1010, 10), end: Point2(1010, 810), thicknessPx: 20),
        ]),
      ],
      source: const Source(Provenance.derived),
    );

Indicator ind(HazardResult r, String id) => r.indicators.firstWhere((i) => i.id == id);

void main() {
  const building = BuildingInput(floors: 1, storyHeightM: 2.6, material: WallMaterial.confinedMasonry, slabLoadKpa: 6);

  test('sin escala verificada no se evalúa (no se inventan metros)', () {
    expect(() => runScreening(box(s: null), building), throwsA(isA<SimulationException>()));
    const unverified = PlanScale(pxPerUnit: 100, unit: LengthUnit.m, verified: false, source: user);
    expect(() => runScreening(box(s: unverified), building), throwsA(isA<SimulationException>()));
  });

  test('sismo: valores calculados a mano', () {
    final engine = ScreeningEngine(StructuralLayout.fromModel(box()), building);
    // Planta envolvente 10,2 × 8,2 = 83,64 m²; volumen de muros 36 m × 0,2 × 2,6 = 18,72 m³
    expect(engine.layout.floorArea, closeTo(83.64, 1e-9));
    expect(engine.seismicWeight(), closeTo(6 * 83.64 + 18 * 18.72, 1e-6)); // 838,8 kN
    final r = engine.seismic(const SeismicInput(pgaG: 0.3, soil: SoilClass.firm));
    // T = 0,05·2,6^0,75 = 0,102 s < Tc → Sa = 2,5·0,3·1,2 = 0,9 g; Cs = 0,9/2,5 = 0,36
    final v = 0.36 * 838.8;
    expect(r.animation['base_shear_kn'] as double, closeTo(v, 1e-6));
    expect(ind(r, 'dc_x').value, closeTo(v / (250 * 4.0), 1e-9)); // kx = 2·10·0,2 = 4 m²
    expect(ind(r, 'dc_y').value, closeTo(v / (250 * 3.2), 1e-9)); // ky = 2·8·0,2 = 3,2 m²
    expect(ind(r, 'torsion_x').value, closeTo(0, 1e-9)); // simétrica
    expect(ind(r, 'density_x').value, closeTo(4 / 83.64 * 100, 1e-9));
    expect(r.overall, Status.ok);
    // Con torsión accidental los muros reciben algo más que el reparto directo.
    expect(ind(r, 'dc_max_element').value, greaterThan(ind(r, 'dc_y').value));
  });

  test('sismo: planta asimétrica genera torsión crítica', () {
    final r = ScreeningEngine(StructuralLayout.fromModel(box(withRightWall: false)), building).seismic(const SeismicInput());
    expect(ind(r, 'torsion_y').status, Status.critical);
    expect(r.overall, Status.critical);
  });

  test('sismo: más pisos y suelo blando aumentan la demanda', () {
    final base = ScreeningEngine(StructuralLayout.fromModel(box()), building).seismic(const SeismicInput());
    final worse = ScreeningEngine(StructuralLayout.fromModel(box()),
            const BuildingInput(floors: 3, material: WallMaterial.confinedMasonry))
        .seismic(const SeismicInput(soil: SoilClass.soft));
    expect(ind(worse, 'dc_x').value, greaterThan(ind(base, 'dc_x').value * 3));
  });

  test('viga simple: integración numérica = qL²/8 para carga uniforme', () {
    expect(ScreeningEngine.maxMomentSimpleBeam(3, (_) => 10), closeTo(10 * 9 / 8, 0.01));
  });

  test('tsunami FEMA P-646 simplificado: fuerzas a mano', () {
    final engine = ScreeningEngine(StructuralLayout.fromModel(box()), building);
    final r = engine.tsunami(const TsunamiInput(inundationDepthM: 2, direction: FlowDirection.plusY));
    final u = math.sqrt(9.81 * 2);
    final force = 0.5 * 1100 * 2 * u * u * 2 * 10.2 / 1000; // ancho perpendicular = 10,2 m
    expect(ind(r, 'sliding').value, closeTo(force / (0.5 * 838.8), 1e-6));
    expect(ind(r, 'base_shear').value, closeTo(force / (250 * 3.2), 1e-6));
    // Perpendiculares al flujo (top/bottom) a flexión; paralelos (left/right) a corte.
    expect(r.elementRatios.keys.toSet(), {'top', 'bottom', 'left', 'right'});
    expect(r.elementRatios['left'], closeTo(ind(r, 'base_shear').value, 1e-12));
    expect(ind(r, 'wall_out_of_plane').status, Status.critical); // mampostería no resiste 2 m de agua en flujo
    expect(r.assumptions.join(), contains('√(g·h)'));
  });

  test('viento: presión y flexión de fachadas', () {
    final r = ScreeningEngine(StructuralLayout.fromModel(box()), building)
        .wind(const WindInput(speedMs: 35, direction: FlowDirection.plusX));
    final p = 0.613 * 35 * 35 / 1000 * 1.3;
    final m = p * 2.6 * 2.6 / 8;
    final cap = 150 * 0.2 * 0.2 / 6; // f = 0,15 MPa
    expect(ind(r, 'facade_out_of_plane').value, closeTo(m / cap, 1e-9));
    expect(r.elementRatios['left'], closeTo(m / cap, 1e-9)); // fachada a flexión
    expect(r.elementRatios['top'], closeTo(ind(r, 'base_shear').value, 1e-12)); // paralelo a corte
  });

  test('informe serializable con advertencia', () {
    final rep = runScreening(box(), building);
    final j = rep.toJson();
    expect(j['disclaimer'], contains('No determina que la estructura sea segura'));
    expect((j['results'] as List).length, 3);
  });

  test('espesor declarado reemplaza al detectado y queda en los supuestos', () {
    final detected = runScreening(box(), building).results[2];
    final declared = runScreening(box(), const BuildingInput(material: WallMaterial.confinedMasonry, wallThicknessM: 0.30))
        .results[2];
    // Flexión ∝ 1/t²: de 0,20 a 0,30 m la relación baja a (0,2/0,3)² ≈ 0,44.
    expect(ind(declared, 'facade_out_of_plane').value / ind(detected, 'facade_out_of_plane').value, closeTo(4 / 9, 1e-9));
    expect(declared.assumptions.first, contains('declarado por el profesional'));
    expect(detected.assumptions.first, contains('20.0 cm'));
    expect(() => runScreening(box(), const BuildingInput(wallThicknessM: 5)), throwsA(isA<SimulationException>()));
  });
}
