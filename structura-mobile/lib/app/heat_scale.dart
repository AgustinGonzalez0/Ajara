/// Escala de colores demanda/capacidad, compartida por el visor 3D y el informe PDF.
/// Dart puro (ARGB como int) para poder usarse en isolates.
library;

/// 0 → verde, 0,7 → amarillo, ≥ 1 → rojo. Sin capacidad (infinito) → rojo oscuro.
int heatColor(double ratio) {
  if (!ratio.isFinite) return 0xFFB3261E;
  final r = ratio.clamp(0.0, 1.2);
  late double rr, gg, bb;
  if (r <= 0.7) {
    final t = r / 0.7;
    rr = 0.24 + t * (0.96 - 0.24);
    gg = 0.75;
    bb = 0.50 - t * 0.30;
  } else {
    final t = ((r - 0.7) / 0.3).clamp(0.0, 1.0);
    rr = 0.96 - t * 0.01;
    gg = 0.75 - t * 0.55;
    bb = 0.20 - t * 0.05;
  }
  return 0xFF000000 | ((rr * 255).round() << 16) | ((gg * 255).round() << 8) | (bb * 255).round();
}

/// Color para elementos sin relación calculada.
const int heatNoData = 0xFFB8BFCC;
