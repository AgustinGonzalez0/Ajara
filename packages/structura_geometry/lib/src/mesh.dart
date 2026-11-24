/// Generación de mallas 3D deterministas a partir del Building Model.
///
/// Sistema de coordenadas (igual que glTF): X = x del plano, Y = arriba,
/// Z = y del plano (hacia el observador). Mano derecha, triángulos CCW.
///
/// ALTURAS: un plano 2D casi nunca indica alturas. Si el Building Model no
/// tiene alturas reales, se usan [DisplayAssumptions]: valores SOLO de
/// visualización, registrados en la malla y en el GLB como supuestos, nunca
/// guardados como medidas del edificio.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:structura_model/structura_model.dart';

/// Supuestos de visualización (no son medidas del edificio).
class DisplayAssumptions {
  /// Unidades de la malla: `m` si hay escala verificada, `plan_px` si no.
  final String units;

  /// Factor plan_px → unidades de malla.
  final double pxToUnits;
  final double wallHeight;
  final double doorHeight;
  final double windowSill;
  final double windowHead;
  final int stairSteps;

  /// Explicación legible de cómo se eligieron los valores.
  final String rationale;

  const DisplayAssumptions({
    required this.units,
    required this.pxToUnits,
    required this.wallHeight,
    required this.doorHeight,
    required this.windowSill,
    required this.windowHead,
    required this.stairSteps,
    required this.rationale,
  });

  /// Elige supuestos a partir del modelo.
  ///
  /// * Con escala verificada: unidades en metros y altura de visualización 2,60 m.
  /// * Sin escala: unidades = píxeles del plano y altura = 18 × espesor mediano de
  ///   muro (relación típica 0,15 m / 2,60 m ≈ 1/17), solo para que la vista sea legible.
  factory DisplayAssumptions.forModel(BuildingModel model) {
    final walls = model.allElements.whereType<Wall>().map((w) => w.thicknessPx).toList()..sort();
    final medianT = walls.isEmpty ? 10.0 : walls[walls.length ~/ 2];
    if (model.hasVerifiedScale) {
      final s = model.scale!;
      final k = s.unit.meters / s.pxPerUnit;
      return DisplayAssumptions(
          units: 'm',
          pxToUnits: k,
          wallHeight: 2.6,
          doorHeight: 2.05,
          windowSill: 0.9,
          windowHead: 2.1,
          stairSteps: 15,
          rationale: 'Escala verificada: planta en metros. Alturas = valores de visualización '
              '(2,60 / 2,05 / 0,90–2,10 m), no medidas del plano.');
    }
    final h = 18 * medianT;
    return DisplayAssumptions(
        units: 'plan_px',
        pxToUnits: 1.0,
        wallHeight: h,
        doorHeight: h * 0.79,
        windowSill: h * 0.35,
        windowHead: h * 0.81,
        stairSteps: 15,
        rationale: 'Sin escala verificada: unidades = píxeles del plano. Altura de muro de visualización = '
            '18 × espesor mediano (${medianT.toStringAsFixed(1)} px). No es una medida.');
  }

  Map<String, Object?> toJson() => {
        'units': units,
        'px_to_units': pxToUnits,
        'wall_height': wallHeight,
        'door_height': doorHeight,
        'window_sill': windowSill,
        'window_head': windowHead,
        'stair_steps': stairSteps,
        'rationale': rationale,
        'is_measurement': false,
      };
}

/// Malla de una categoría (una primitiva glTF).
class MeshPart {
  final String category; // wall, door, window (vidrio), column, stairs, floor
  final List<double> positions = []; // xyz
  final List<double> normals = [];
  final List<int> indices = [];

  /// Por triángulo: id del elemento del Building Model que lo originó.
  final List<String> triangleElementIds = [];

  MeshPart(this.category);

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;

  Float32List positionsF32() => Float32List.fromList(positions);
  Float32List normalsF32() => Float32List.fromList(normals);
  Uint32List indicesU32() => Uint32List.fromList(indices);

  /// (min, max) de posiciones; exigido por glTF para POSITION.
  (List<double>, List<double>) bounds() {
    final mn = [double.infinity, double.infinity, double.infinity];
    final mx = [double.negativeInfinity, double.negativeInfinity, double.negativeInfinity];
    for (var i = 0; i < positions.length; i += 3) {
      for (var k = 0; k < 3; k++) {
        mn[k] = math.min(mn[k], positions[i + k]);
        mx[k] = math.max(mx[k], positions[i + k]);
      }
    }
    return (mn, mx);
  }

  void _quad(List<double> a, List<double> b, List<double> c, List<double> d, List<double> n, String id) {
    final base = vertexCount;
    for (final p in [a, b, c, d]) {
      positions.addAll(p);
      normals.addAll(n);
    }
    // Garantiza CCW respecto de la normal.
    final e1 = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
    final e2 = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
    final cx = e1[1] * e2[2] - e1[2] * e2[1];
    final cy = e1[2] * e2[0] - e1[0] * e2[2];
    final cz = e1[0] * e2[1] - e1[1] * e2[0];
    final ccw = cx * n[0] + cy * n[1] + cz * n[2] >= 0;
    if (ccw) {
      indices.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
    } else {
      indices.addAll([base, base + 2, base + 1, base, base + 3, base + 2]);
    }
    triangleElementIds
      ..add(id)
      ..add(id);
  }

  /// Prisma recto: huella cuadrilátera (4 puntos XZ en orden) entre alturas y0 e y1.
  void addPrism(List<(double, double)> footprint, double y0, double y1, String id) {
    if (y1 <= y0) return;
    // Orden CCW visto desde arriba (+Y) con Z hacia el observador.
    var f = footprint;
    double area = 0;
    for (var i = 0; i < f.length; i++) {
      final (x0, z0) = f[i];
      final (x1, z1) = f[(i + 1) % f.length];
      area += x0 * z1 - x1 * z0;
    }
    if (area > 0) f = f.reversed.toList();
    List<double> p(int i, double y) => [f[i].$1, y, f[i].$2];
    _quad(p(0, y1), p(1, y1), p(2, y1), p(3, y1), [0, 1, 0], id); // techo
    _quad(p(3, y0), p(2, y0), p(1, y0), p(0, y0), [0, -1, 0], id); // base
    for (var i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      final dx = f[j].$1 - f[i].$1, dz = f[j].$2 - f[i].$2;
      final len = math.sqrt(dx * dx + dz * dz);
      if (len == 0) continue;
      final n = [dz / len, 0.0, -dx / len];
      _quad(p(i, y0), p(j, y0), p(j, y1), p(i, y1), n, id);
    }
  }

  void addBox(double x0, double z0, double x1, double z1, double y0, double y1, String id) =>
      addPrism([(x0, z0), (x1, z0), (x1, z1), (x0, z1)], y0, y1, id);
}

class BuildingMesh {
  final Map<String, MeshPart> parts;
  final DisplayAssumptions assumptions;
  const BuildingMesh(this.parts, this.assumptions);
  int get triangleCount => parts.values.fold(0, (a, p) => a + p.triangleCount);
}

class MeshBuilder {
  const MeshBuilder();

  BuildingMesh build(BuildingModel model, {DisplayAssumptions? assumptions, bool includeFloor = true}) {
    final a = assumptions ?? DisplayAssumptions.forModel(model);
    final k = a.pxToUnits;
    final parts = {for (final c in ['floor', 'wall', 'door', 'window', 'column', 'stairs']) c: MeshPart(c)};
    for (final e in model.allElements) {
      switch (e) {
        case Wall w:
          final dx = w.end.x - w.start.x, dy = w.end.y - w.start.y;
          final len = math.sqrt(dx * dx + dy * dy);
          if (len == 0) continue;
          final nx = -dy / len * w.thicknessPx / 2, ny = dx / len * w.thicknessPx / 2;
          parts['wall']!.addPrism([
            ((w.start.x + nx) * k, (w.start.y + ny) * k),
            ((w.end.x + nx) * k, (w.end.y + ny) * k),
            ((w.end.x - nx) * k, (w.end.y - ny) * k),
            ((w.start.x - nx) * k, (w.start.y - ny) * k),
          ], 0, a.wallHeight, w.id);
        case Opening o:
          final r = o.footprint;
          if (o.type == OpeningType.door) {
            // Dintel sobre la puerta; el vano queda libre.
            parts['wall']!.addBox(r.left * k, r.top * k, r.right * k, r.bottom * k, a.doorHeight, a.wallHeight, o.id);
            parts['door']!.addBox(r.left * k, r.top * k, r.right * k, r.bottom * k, 0, a.doorHeight * 0.02, o.id);
          } else {
            parts['wall']!.addBox(r.left * k, r.top * k, r.right * k, r.bottom * k, 0, a.windowSill, o.id);
            parts['wall']!.addBox(r.left * k, r.top * k, r.right * k, r.bottom * k, a.windowHead, a.wallHeight, o.id);
            // Vidrio: lámina delgada centrada en el espesor.
            final horizontal = r.width >= r.height;
            if (horizontal) {
              final cz = r.center.y, t = r.height * 0.15;
              parts['window']!.addBox(r.left * k, (cz - t) * k, r.right * k, (cz + t) * k, a.windowSill, a.windowHead, o.id);
            } else {
              final cx = r.center.x, t = r.width * 0.15;
              parts['window']!.addBox((cx - t) * k, r.top * k, (cx + t) * k, r.bottom * k, a.windowSill, a.windowHead, o.id);
            }
          }
        case ColumnElement c:
          final r = c.footprint;
          parts['column']!.addBox(r.left * k, r.top * k, r.right * k, r.bottom * k, 0, a.wallHeight, c.id);
        case Stairs s:
          final r = s.footprint;
          final n = a.stairSteps;
          final alongX = r.width >= r.height;
          for (var i = 0; i < n; i++) {
            final t0 = i / n, t1 = (i + 1) / n;
            final top = a.wallHeight * (i + 1) / n;
            if (alongX) {
              parts['stairs']!.addBox((r.left + r.width * t0) * k, r.top * k, (r.left + r.width * t1) * k, r.bottom * k, 0, top, s.id);
            } else {
              parts['stairs']!.addBox(r.left * k, (r.top + r.height * t0) * k, r.right * k, (r.top + r.height * t1) * k, 0, top, s.id);
            }
          }
        default:
          break; // Room: sin volumen todavía
      }
    }
    if (includeFloor && model.allElements.isNotEmpty) {
      final b = model.allElements.map((e) => e.bounds);
      final l = b.map((r) => r.left).reduce(math.min), t = b.map((r) => r.top).reduce(math.min);
      final rr = b.map((r) => r.right).reduce(math.max), bb = b.map((r) => r.bottom).reduce(math.max);
      parts['floor']!.addBox(l * k, t * k, rr * k, bb * k, -a.wallHeight * 0.01, 0, 'floor');
    }
    parts.removeWhere((_, p) => p.triangleCount == 0);
    return BuildingMesh(parts, a);
  }
}
