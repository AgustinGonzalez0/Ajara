/// Parámetros de la evaluación preliminar. Todos los valores por defecto son
/// INDICATIVOS y editables por el profesional; se registran en el informe.
library;

/// Material de muros con propiedades indicativas de diseño (no son valores de norma).
enum WallMaterial {
  adobe('Adobe', 16, 0.03, 0.02, 1.5),
  unreinforcedBrick('Mampostería de ladrillo sin confinar', 18, 0.10, 0.10, 1.5),
  confinedMasonry('Mampostería confinada (con encadenados)', 18, 0.25, 0.15, 2.5),
  reinforcedBlock('Bloque de hormigón armado', 20, 0.30, 0.40, 3.0),
  reinforcedConcrete('Hormigón armado', 24, 0.80, 2.00, 4.0);

  final String label;

  /// Peso específico (kN/m³).
  final double unitWeight;

  /// Resistencia a corte en el plano del muro (MPa), valor de diseño indicativo.
  final double shearStrength;

  /// Resistencia equivalente a flexión fuera del plano (MPa).
  final double flexuralStrength;

  /// Factor de reducción de respuesta sísmica R (ductilidad), indicativo.
  final double responseFactor;

  const WallMaterial(this.label, this.unitWeight, this.shearStrength, this.flexuralStrength, this.responseFactor);
}

/// Suelo de fundación con factor de amplificación indicativo S.
enum SoilClass {
  rock('Roca', 1.0),
  firm('Suelo firme', 1.2),
  medium('Suelo intermedio', 1.35),
  soft('Suelo blando', 1.5);

  final String label;
  final double factor;
  const SoilClass(this.label, this.factor);
}

/// Dirección de avance del agua o del viento en ejes del plano (x → derecha, y → abajo).
enum FlowDirection {
  plusX('Desde la izquierda del plano (→)'),
  minusX('Desde la derecha del plano (←)'),
  plusY('Desde arriba del plano (↓)'),
  minusY('Desde abajo del plano (↑)');

  final String label;
  const FlowDirection(this.label);

  /// true si el flujo avanza en x (lo resisten en el plano los muros horizontales).
  bool get alongX => this == plusX || this == minusX;
}

class SeismicInput {
  /// Aceleración máxima del terreno de diseño (g).
  final double pgaG;
  final SoilClass soil;

  /// Período de esquina de la meseta espectral (s).
  final double cornerPeriodS;
  const SeismicInput({this.pgaG = 0.3, this.soil = SoilClass.firm, this.cornerPeriodS = 0.6});
  Map<String, Object?> toJson() => {'pga_g': pgaG, 'soil': soil.name, 'soil_factor': soil.factor, 'corner_period_s': cornerPeriodS};
}

class TsunamiInput {
  /// Profundidad de inundación sobre el terreno en el sitio (m).
  final double inundationDepthM;

  /// Velocidad del flujo (m/s). null → sqrt(g·h) (simplificación; ver informe).
  final double? flowVelocityMs;
  final FlowDirection direction;
  const TsunamiInput({this.inundationDepthM = 2.0, this.flowVelocityMs, this.direction = FlowDirection.plusY});
  Map<String, Object?> toJson() =>
      {'inundation_depth_m': inundationDepthM, 'flow_velocity_ms': flowVelocityMs, 'direction': direction.name};
}

class WindInput {
  /// Velocidad básica de ráfaga (m/s).
  final double speedMs;
  final FlowDirection direction;
  const WindInput({this.speedMs = 35, this.direction = FlowDirection.plusX});
  Map<String, Object?> toJson() => {'speed_ms': speedMs, 'direction': direction.name};
}

class BuildingInput {
  final int floors;
  final double storyHeightM;
  final WallMaterial material;

  /// Carga sísmica por m² de losa (peso propio + terminaciones + fracción de uso), kPa.
  final double slabLoadKpa;

  /// Coeficiente de rozamiento fundación-suelo para deslizamiento (tsunami).
  final double frictionCoefficient;

  /// Espesor real de muros declarado por el profesional (m). null = usar el
  /// espesor detectado en el plano (puede ser impreciso en fotos).
  final double? wallThicknessM;
  const BuildingInput({
    this.wallThicknessM,
    this.floors = 1,
    this.storyHeightM = 2.6,
    this.material = WallMaterial.confinedMasonry,
    this.slabLoadKpa = 6.0,
    this.frictionCoefficient = 0.5,
  });
  Map<String, Object?> toJson() => {
        'floors': floors,
        'story_height_m': storyHeightM,
        'material': material.name,
        'material_props': {
          'unit_weight_kn_m3': material.unitWeight,
          'shear_strength_mpa': material.shearStrength,
          'flexural_strength_mpa': material.flexuralStrength,
          'response_factor_r': material.responseFactor,
        },
        'slab_load_kpa': slabLoadKpa,
        'wall_thickness_m': wallThicknessM,
        'friction_coefficient': frictionCoefficient,
      };
}
