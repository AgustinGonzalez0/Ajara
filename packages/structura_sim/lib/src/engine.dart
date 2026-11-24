/// Motor de evaluación preliminar (screening) de sismo, tsunami y viento.
///
/// ADVERTENCIA (se incluye en todo informe): es una estimación simplificada de
/// orden de magnitud para priorizar y comunicar riesgos. No verifica normas, no
/// conoce armaduras, fundaciones, calidad constructiva ni el estado real de la
/// obra, y NO determina que una estructura sea segura. Requiere evaluación por un
/// profesional habilitado.
///
/// Métodos:
/// * Sismo — fuerza lateral estática equivalente con espectro de meseta
///   Sa = 2,5·PGA·S (·Tc/T si T > Tc), T ≈ 0,05·H^0,75, Cs = Sa/R. Capacidad a corte
///   en el plano: τ·ΣA_muros por dirección. Diafragma rígido con rigidez ∝ área de
///   corte: centro de rigidez, torsión con excentricidad real + accidental (±5 %).
/// * Tsunami — FEMA P-646 simplificado: presión hidrodinámica ½·ρs·Cd·u² (Cd = 2,
///   ρs = 1100 kg/m³ con sedimentos) + hidrostática ρs·g·(h − z) sobre la planta
///   baja; flexión fuera del plano de cada muro perpendicular al flujo (viga simple
///   de luz = altura de piso, integración numérica); deslizamiento global μ·W.
/// * Viento — q = 0,613·V² (Pa), coeficiente neto 1,3 sobre fachadas; flexión fuera
///   del plano de muros exteriores y corte basal.
library;

import 'dart:math' as math;

import 'package:structura_model/structura_model.dart';

import 'inputs.dart';

const String screeningDisclaimer =
    'Evaluación preliminar simplificada. No reemplaza el cálculo estructural ni la verificación '
    'normativa por un profesional habilitado. No determina que la estructura sea segura.';

class SimulationException implements Exception {
  final String message;
  const SimulationException(this.message);
  @override
  String toString() => message;
}

enum Status { ok, attention, critical, notApplicable }

Status statusForRatio(double r, {double attention = 0.7, double critical = 1.0}) {
  if (r.isNaN) return Status.notApplicable;
  if (r > critical) return Status.critical;
  if (r > attention) return Status.attention;
  return Status.ok;
}

class Indicator {
  final String id;
  final String label;
  final double value;
  final String unit;
  final Status status;
  final String explanation;
  const Indicator(this.id, this.label, this.value, this.unit, this.status, this.explanation);
  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'value': value.isFinite ? value : null,
        'unit': unit,
        'status': status.name,
        'explanation': explanation,
      };
}

enum Hazard { seismic, tsunami, wind }

class HazardResult {
  final Hazard hazard;
  final List<Indicator> indicators;

  /// Relación demanda/capacidad por elemento (id del Building Model).
  final Map<String, double> elementRatios;
  final List<String> assumptions;

  /// Datos para la animación (solo visualización).
  final Map<String, Object?> animation;
  const HazardResult(this.hazard, this.indicators, this.elementRatios, this.assumptions, this.animation);

  Status get overall {
    if (indicators.any((i) => i.status == Status.critical)) return Status.critical;
    if (indicators.any((i) => i.status == Status.attention)) return Status.attention;
    if (indicators.every((i) => i.status == Status.notApplicable)) return Status.notApplicable;
    return Status.ok;
  }

  Map<String, Object?> toJson() => {
        'hazard': hazard.name,
        'overall': overall.name,
        'indicators': indicators.map((i) => i.toJson()).toList(),
        'element_ratios': elementRatios.map((k, v) => MapEntry(k, v.isFinite ? v : null)),
        'assumptions': assumptions,
        'animation': animation,
      };
}

/// Elemento resistente en metros.
class StructElement {
  final String id;
  final bool isColumn;
  final bool alongX; // muro: eje paralelo a x
  final double cx, cy; // centro (m)
  final double length; // m (muro) o lado mayor (columna)
  final double thickness; // m
  const StructElement(this.id, this.isColumn, this.alongX, this.cx, this.cy, this.length, this.thickness);

  /// Área de corte en planta (m²).
  double get area => length * thickness;
  bool resistsX() => isColumn || alongX;
  bool resistsY() => isColumn || !alongX;
}

class StructuralLayout {
  final List<StructElement> elements;
  final double minX, minY, maxX, maxY; // m
  const StructuralLayout(this.elements, this.minX, this.minY, this.maxX, this.maxY);

  double get lx => maxX - minX;
  double get ly => maxY - minY;
  double get floorArea => lx * ly;
  double get cmX => (minX + maxX) / 2;
  double get cmY => (minY + maxY) / 2;

  /// Construye la geometría estructural. Exige escala verificada (no se inventan metros).
  factory StructuralLayout.fromModel(BuildingModel model, {double? wallThicknessM}) {
    final s = model.scale;
    if (s == null || !s.verified) {
      throw const SimulationException(
          'La evaluación necesita una escala verificada: calibrá el plano con una medida real conocida.');
    }
    final k = s.pxToMeters(1)!;
    final els = <StructElement>[];
    for (final e in model.allElements) {
      if (e is Wall) {
        final dx = e.end.x - e.start.x, dy = e.end.y - e.start.y;
        els.add(StructElement(e.id, false, dx.abs() >= dy.abs(), (e.start.x + e.end.x) / 2 * k,
            (e.start.y + e.end.y) / 2 * k, e.lengthPx * k, wallThicknessM ?? e.thicknessPx * k));
      } else if (e is ColumnElement) {
        final r = e.footprint;
        els.add(StructElement(e.id, true, true, r.center.x * k, r.center.y * k, math.max(r.width, r.height) * k,
            math.min(r.width, r.height) * k));
      }
    }
    if (els.isEmpty) throw const SimulationException('El modelo no tiene muros ni columnas para evaluar.');
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final e in model.allElements.where((e) => e is Wall || e is ColumnElement)) {
      final b = e.bounds;
      minX = math.min(minX, b.left * k);
      minY = math.min(minY, b.top * k);
      maxX = math.max(maxX, b.right * k);
      maxY = math.max(maxY, b.bottom * k);
    }
    return StructuralLayout(els, minX, minY, maxX, maxY);
  }
}

class ScreeningEngine {
  static const double g = 9.81;
  static const double rhoSediment = 1100; // kg/m³
  static const double dragCoefficient = 2.0;
  static const double windNetCp = 1.3;

  final StructuralLayout layout;
  final BuildingInput building;
  const ScreeningEngine(this.layout, this.building);

  double get totalHeight => building.floors * building.storyHeightM;

  /// Espesor mediano de muros usado en el cálculo (m).
  double medianWallThickness() {
    final t = layout.elements.where((e) => !e.isColumn).map((e) => e.thickness).toList()..sort();
    return t.isEmpty ? 0 : t[t.length ~/ 2];
  }

  /// Peso sísmico total (kN).
  double seismicWeight() {
    final wallVolume = layout.elements.fold<double>(0, (a, e) => a + e.area * building.storyHeightM);
    final perFloor = building.slabLoadKpa * layout.floorArea + building.material.unitWeight * wallVolume;
    return perFloor * building.floors;
  }

  double shearCapacity({required bool x}) {
    final a = layout.elements.where((e) => x ? e.resistsX() : e.resistsY()).fold<double>(0, (s, e) => s + e.area);
    return building.material.shearStrength * 1000 * a; // kN
  }

  List<String> _baseAssumptions() => [
        building.wallThicknessM != null
            ? 'Espesor de muros declarado por el profesional: ${building.wallThicknessM!.toStringAsFixed(2)} m.'
            : 'Espesor de muros tomado del plano detectado (mediana ${(medianWallThickness() * 100).toStringAsFixed(1)} cm): verificar.',
        'Material: ${building.material.label} (τ = ${building.material.shearStrength} MPa, '
            'f = ${building.material.flexuralStrength} MPa, γ = ${building.material.unitWeight} kN/m³) — valores indicativos.',
        '${building.floors} piso(s) de ${building.storyHeightM.toStringAsFixed(2)} m; muros de planta baja repetidos en altura.',
        'Planta = rectángulo envolvente de muros (${layout.lx.toStringAsFixed(2)} × ${layout.ly.toStringAsFixed(2)} m); '
            'carga de losa ${building.slabLoadKpa} kPa.',
        'No se consideran armaduras, fundaciones, suelo de apoyo, calidad constructiva ni deterioro.',
      ];

  // ------------------------------------------------------------------ Sismo
  HazardResult seismic(SeismicInput input) {
    final h = totalHeight;
    final period = 0.05 * math.pow(h, 0.75).toDouble();
    final plateau = 2.5 * input.pgaG * input.soil.factor;
    final sa = period <= input.cornerPeriodS ? plateau : plateau * input.cornerPeriodS / period;
    final cs = sa / building.material.responseFactor;
    final w = seismicWeight();
    final v = cs * w;
    final tau = building.material.shearStrength * 1000; // kPa
    final xs = layout.elements.where((e) => e.resistsX()).toList();
    final ys = layout.elements.where((e) => e.resistsY()).toList();
    final kx = xs.fold<double>(0, (a, e) => a + e.area), ky = ys.fold<double>(0, (a, e) => a + e.area);
    final dcX = kx == 0 ? double.infinity : v / (tau * kx);
    final dcY = ky == 0 ? double.infinity : v / (tau * ky);
    final xCR = ky == 0 ? layout.cmX : ys.fold<double>(0, (a, e) => a + e.area * e.cx) / ky;
    final yCR = kx == 0 ? layout.cmY : xs.fold<double>(0, (a, e) => a + e.area * e.cy) / kx;
    final j = xs.fold<double>(0, (a, e) => a + e.area * math.pow(e.cy - yCR, 2)) +
        ys.fold<double>(0, (a, e) => a + e.area * math.pow(e.cx - xCR, 2));
    final ratios = <String, double>{};
    void loadCase({required bool alongX, required double ecc}) {
      // Fuerza directa (∝ rigidez) + torsión Mt·k·d/J en la dirección resistente de cada elemento.
      final kd = alongX ? kx : ky;
      final mt = v * ecc;
      for (final e in layout.elements) {
        var fx = 0.0, fy = 0.0;
        if (e.resistsX()) {
          if (alongX && kd > 0) fx += v * e.area / kd;
          if (j > 0) fx += mt * e.area * (e.cy - yCR) / j;
        }
        if (e.resistsY()) {
          if (!alongX && kd > 0) fy += v * e.area / kd;
          if (j > 0) fy += mt * e.area * (e.cx - xCR) / j;
        }
        final dc = math.max(fx.abs(), fy.abs()) / (tau * e.area);
        ratios[e.id] = math.max(ratios[e.id] ?? 0, dc);
      }
    }

    final eY = layout.cmY - yCR, eX = layout.cmX - xCR;
    for (final sign in [1.0, -1.0]) {
      loadCase(alongX: true, ecc: eY + sign * 0.05 * layout.ly);
      loadCase(alongX: false, ecc: eX + sign * 0.05 * layout.lx);
    }
    final torX = layout.ly == 0 ? 0.0 : eY.abs() / layout.ly;
    final torY = layout.lx == 0 ? 0.0 : eX.abs() / layout.lx;
    final maxWall = ratios.values.fold<double>(0, math.max);
    double dens(double k) => k / layout.floorArea * 100;
    final indicators = [
      Indicator('dc_x', 'Corte basal dirección X (demanda/capacidad)', dcX, '', statusForRatio(dcX),
          'Fuerza sísmica ${v.toStringAsFixed(0)} kN frente a capacidad de muros en X ${(tau * kx).toStringAsFixed(0)} kN.'),
      Indicator('dc_y', 'Corte basal dirección Y (demanda/capacidad)', dcY, '', statusForRatio(dcY),
          'Capacidad de muros en Y ${(tau * ky).toStringAsFixed(0)} kN.'),
      Indicator('dc_max_element', 'Muro más exigido (con torsión)', maxWall, '', statusForRatio(maxWall),
          'Incluye torsión por excentricidad entre centro de masa y de rigidez y ±5 % accidental.'),
      Indicator('torsion_x', 'Excentricidad en planta (sismo en X)', torX, 'e/L',
          statusForRatio(torX, attention: 0.1, critical: 0.2), 'Muros de un solo lado aumentan la torsión en planta.'),
      Indicator('torsion_y', 'Excentricidad en planta (sismo en Y)', torY, 'e/L',
          statusForRatio(torY, attention: 0.1, critical: 0.2), ''),
      Indicator('density_x', 'Densidad de muros en X', dens(kx), '%', Status.notApplicable,
          'Área de muros en X / área de planta, por piso.'),
      Indicator('density_y', 'Densidad de muros en Y', dens(ky), '%', Status.notApplicable, ''),
    ];
    return HazardResult(Hazard.seismic, indicators, ratios, [
      ..._baseAssumptions(),
      'Espectro de meseta: PGA ${input.pgaG} g, suelo ${input.soil.label} (S = ${input.soil.factor}), Tc = ${input.cornerPeriodS} s.',
      'Período estimado T = ${period.toStringAsFixed(2)} s (T ≈ 0,05·H^0,75); Sa = ${sa.toStringAsFixed(2)} g; '
          'R = ${building.material.responseFactor}; Cs = ${cs.toStringAsFixed(3)}; peso W = ${w.toStringAsFixed(0)} kN.',
      'Diafragma rígido; rigidez de cada muro proporcional a su área de corte.',
    ], {
      'period_s': period,
      'sa_g': sa,
      'base_shear_kn': v,
      'weight_kn': w,
      'cr': [xCR, yCR],
      'cm': [layout.cmX, layout.cmY],
    });
  }

  /// Momento máximo (kN·m/m) de una viga simple de luz L con carga distribuida q(z) (kN/m²).
  static double maxMomentSimpleBeam(double span, double Function(double z) q, {int n = 400}) {
    final dz = span / n;
    double total = 0, moment = 0;
    final loads = List<double>.generate(n, (i) => q((i + 0.5) * dz) * dz);
    for (var i = 0; i < n; i++) {
      total += loads[i];
      moment += loads[i] * (i + 0.5) * dz;
    }
    final rTop = moment / span; // reacción en z = L
    final rBottom = total - rTop;
    double shear = rBottom, m = 0, maxM = 0;
    for (var i = 0; i < n; i++) {
      m += shear * dz - loads[i] * dz / 2;
      shear -= loads[i];
      maxM = math.max(maxM, m.abs());
    }
    return maxM;
  }

  double _flexCapacity(double t) => building.material.flexuralStrength * 1000 * t * t / 6; // kN·m/m

  // ------------------------------------------------------------------ Tsunami
  HazardResult tsunami(TsunamiInput input) {
    final h = input.inundationDepthM;
    if (h <= 0) throw const SimulationException('La profundidad de inundación debe ser mayor que 0.');
    final u = input.flowVelocityMs ?? math.sqrt(g * h);
    final hs = building.storyHeightM;
    final pDyn = 0.5 * rhoSediment * dragCoefficient * u * u / 1000; // kPa
    double load(double z) => z <= h ? rhoSediment * g * (h - z) / 1000 + pDyn : 0;
    final mDemand = maxMomentSimpleBeam(hs, load);
    final ratios = <String, double>{};
    final perpendicular = layout.elements.where((e) => !e.isColumn && e.alongX != input.direction.alongX);
    var maxWall = 0.0;
    for (final e in perpendicular) {
      final r = mDemand / _flexCapacity(e.thickness);
      ratios[e.id] = r;
      maxWall = math.max(maxWall, r);
    }
    final width = input.direction.alongX ? layout.ly : layout.lx;
    final force = 0.5 * rhoSediment * dragCoefficient * u * u * h * width / 1000; // kN
    final w = seismicWeight();
    final sliding = force / (building.frictionCoefficient * w);
    final cap = shearCapacity(x: input.direction.alongX);
    final shearDc = cap == 0 ? double.infinity : force / cap;
    // Muros paralelos al flujo: trabajan a corte (reparto ∝ área → misma relación para todos).
    for (final e in layout.elements.where((e) => input.direction.alongX ? e.resistsX() : e.resistsY())) {
      ratios.putIfAbsent(e.id, () => shearDc);
    }
    return HazardResult(Hazard.tsunami, [
      Indicator('wall_out_of_plane', 'Muros perpendiculares al flujo (flexión)', maxWall, '', statusForRatio(maxWall),
          'Momento ${mDemand.toStringAsFixed(1)} kN·m/m por presión hidrodinámica + hidrostática en planta baja.'),
      Indicator('base_shear', 'Corte en muros paralelos al flujo', shearDc, '', statusForRatio(shearDc),
          'Fuerza hidrodinámica total ${force.toStringAsFixed(0)} kN frente a capacidad ${cap.toStringAsFixed(0)} kN.'),
      Indicator('sliding', 'Deslizamiento global', sliding, '', statusForRatio(sliding),
          'Fuerza del agua frente a rozamiento μ·W (μ = ${building.frictionCoefficient}, W = ${w.toStringAsFixed(0)} kN).'),
    ], ratios, [
      ..._baseAssumptions(),
      'Inundación h = ${h.toStringAsFixed(2)} m; velocidad u = ${u.toStringAsFixed(2)} m/s'
          '${input.flowVelocityMs == null ? ' (estimada como √(g·h), simplificación)' : ''}; ${input.direction.label}.',
      'FEMA P-646 simplificado: ρs = 1100 kg/m³, Cd = 2. Sin impacto de escombros, socavación ni subpresión (flotación).',
      'Muros como vigas simples entre fundación y losa (luz ${hs.toStringAsFixed(2)} m).',
    ], {
      'depth_m': h,
      'velocity_ms': u,
      'direction': input.direction.name,
    });
  }

  // ------------------------------------------------------------------ Viento
  HazardResult wind(WindInput input) {
    final q = 0.613 * input.speedMs * input.speedMs / 1000; // kPa
    final p = q * windNetCp;
    final hs = building.storyHeightM;
    final mDemand = p * hs * hs / 8;
    final ratios = <String, double>{};
    var maxWall = 0.0;
    for (final e in layout.elements.where((e) => !e.isColumn && e.alongX != input.direction.alongX)) {
      final pos = input.direction.alongX ? e.cx : e.cy;
      final lo = input.direction.alongX ? layout.minX : layout.minY;
      final hi = input.direction.alongX ? layout.maxX : layout.maxY;
      if ((pos - lo).abs() > 0.6 && (hi - pos).abs() > 0.6) continue; // solo fachadas
      final r = mDemand / _flexCapacity(e.thickness);
      ratios[e.id] = r;
      maxWall = math.max(maxWall, r);
    }
    final width = input.direction.alongX ? layout.ly : layout.lx;
    final force = p * width * totalHeight;
    final cap = shearCapacity(x: input.direction.alongX);
    final dc = cap == 0 ? double.infinity : force / cap;
    for (final e in layout.elements.where((e) => input.direction.alongX ? e.resistsX() : e.resistsY())) {
      ratios.putIfAbsent(e.id, () => dc);
    }
    return HazardResult(Hazard.wind, [
      Indicator('facade_out_of_plane', 'Muros de fachada (flexión por presión)', maxWall, '', statusForRatio(maxWall),
          'Presión neta ${(p * 1000).toStringAsFixed(0)} Pa sobre muros exteriores perpendiculares al viento.'),
      Indicator('base_shear', 'Corte basal por viento', dc, '', statusForRatio(dc),
          'Fuerza total ${force.toStringAsFixed(0)} kN frente a capacidad ${cap.toStringAsFixed(0)} kN.'),
    ], ratios, [
      ..._baseAssumptions(),
      'Viento V = ${input.speedMs} m/s; q = 0,613·V² = ${(q * 1000).toStringAsFixed(0)} Pa; Cp neto 1,3; ${input.direction.label}.',
      'Sin factores de exposición, topografía ni ráfaga normativos; sin succión en cubierta.',
    ], {
      'speed_ms': input.speedMs,
      'direction': input.direction.name,
    });
  }
}

class ScreeningReport {
  final DateTime createdAt;
  final BuildingInput building;
  final List<HazardResult> results;
  final Map<String, Object?> inputs;
  const ScreeningReport(this.createdAt, this.building, this.results, this.inputs);
  Map<String, Object?> toJson() => {
        'format': 'structura-screening/1',
        'created_at': createdAt.toUtc().toIso8601String(),
        'disclaimer': screeningDisclaimer,
        'building': building.toJson(),
        'inputs': inputs,
        'results': results.map((r) => r.toJson()).toList(),
      };
}

/// Atajo: ejecuta los tres peligros sobre un Building Model con escala verificada.
ScreeningReport runScreening(BuildingModel model, BuildingInput building,
    {SeismicInput seismic = const SeismicInput(), TsunamiInput? tsunami = const TsunamiInput(), WindInput? wind = const WindInput()}) {
  if (building.floors < 1 || building.storyHeightM <= 0) {
    throw const SimulationException('Cantidad de pisos y altura de piso deben ser positivas.');
  }
  if (building.wallThicknessM != null && !(building.wallThicknessM! > 0.03 && building.wallThicknessM! < 2)) {
    throw const SimulationException('El espesor de muros declarado debe estar entre 0,03 y 2 m.');
  }
  final engine = ScreeningEngine(StructuralLayout.fromModel(model, wallThicknessM: building.wallThicknessM), building);
  return ScreeningReport(DateTime.now(), building, [
    engine.seismic(seismic),
    if (tsunami != null) engine.tsunami(tsunami),
    if (wind != null) engine.wind(wind),
  ], {
    'seismic': seismic.toJson(),
    'tsunami': tsunami?.toJson(),
    'wind': wind?.toJson(),
  });
}
