/// Renderizador 3D por software sobre Canvas.
///
/// Decisión: no hay un paquete 3D mantenido disponible offline y las alternativas
/// comunes agregan dependencias pesadas o abandonadas. Para mallas arquitectónicas
/// (miles de triángulos planos) alcanza con proyección en perspectiva, descarte de
/// caras traseras, orden por profundidad (pintor) y sombreado plano, dibujando todo
/// en UNA llamada `drawVertices`. Funciona igual en celulares de gama baja.
///
/// Extras para la evaluación preliminar: colores por elemento (mapa de calor de
/// demanda/capacidad), deformación lateral animada (vaivén sísmico, proporcional a
/// la altura) y mallas superpuestas (p. ej., el agua del tsunami).
library;

export '../../app/heat_scale.dart' show heatColor;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:structura_geometry/structura_geometry.dart';
import 'package:vector_math/vector_math_64.dart';

class OrbitCamera {
  double yaw; // radianes
  double pitch;
  double distance;
  Vector3 target;
  final double fovY;
  OrbitCamera({this.yaw = -0.7, this.pitch = 0.75, this.distance = 10, Vector3? target, this.fovY = 45 * math.pi / 180})
      : target = target ?? Vector3.zero();

  Vector3 get eye => target +
      Vector3(math.cos(pitch) * math.sin(yaw), math.sin(pitch), math.cos(pitch) * math.cos(yaw)) * distance;

  OrbitCamera copy() => OrbitCamera(yaw: yaw, pitch: pitch, distance: distance, target: target.clone(), fovY: fovY);
}

/// Triángulos preprocesados de una malla.
class RenderMesh {
  final Float64List positions; // 9 por triángulo
  final Float64List normals; // 3 por triángulo
  final Int32List baseColors; // ARGB por triángulo
  final List<String> categories; // por triángulo
  final List<String> elementIds; // por triángulo (id del Building Model)
  final Aabb3 bounds;
  RenderMesh._(this.positions, this.normals, this.baseColors, this.categories, this.elementIds, this.bounds);

  int get triangleCount => baseColors.length;

  static int argbOf(List<double> c) =>
      (((c[3] * 255).round() & 0xff) << 24) |
      (((c[0] * 255).round() & 0xff) << 16) |
      (((c[1] * 255).round() & 0xff) << 8) |
      ((c[2] * 255).round() & 0xff);

  factory RenderMesh.fromParts(Iterable<MeshPart> parts) {
    final pos = <double>[], nor = <double>[], cols = <int>[], cats = <String>[], ids = <String>[];
    final mn = Vector3.all(double.infinity), mx = Vector3.all(double.negativeInfinity);
    for (final part in parts) {
      final argb = argbOf(categoryColors[part.category] ?? const [0.8, 0.8, 0.8, 1.0]);
      for (var t = 0; t < part.indices.length; t += 3) {
        for (var k = 0; k < 3; k++) {
          final i = part.indices[t + k] * 3;
          final x = part.positions[i], y = part.positions[i + 1], z = part.positions[i + 2];
          pos.addAll([x, y, z]);
          mn.x = math.min(mn.x, x);
          mn.y = math.min(mn.y, y);
          mn.z = math.min(mn.z, z);
          mx.x = math.max(mx.x, x);
          mx.y = math.max(mx.y, y);
          mx.z = math.max(mx.z, z);
        }
        final i0 = part.indices[t] * 3;
        nor.addAll([part.normals[i0], part.normals[i0 + 1], part.normals[i0 + 2]]);
        cols.add(argb);
        cats.add(part.category);
        ids.add(t ~/ 3 < part.triangleElementIds.length ? part.triangleElementIds[t ~/ 3] : '');
      }
    }
    return RenderMesh._(Float64List.fromList(pos), Float64List.fromList(nor), Int32List.fromList(cols), cats, ids,
        cols.isEmpty ? Aabb3.minMax(Vector3.zero(), Vector3.zero()) : Aabb3.minMax(mn, mx));
  }

  factory RenderMesh.fromBuildingMesh(BuildingMesh mesh) => RenderMesh.fromParts(mesh.parts.values);

  /// Cámara inicial que encuadra toda la malla.
  OrbitCamera frame() {
    final center = (bounds.min + bounds.max) * 0.5;
    final radius = math.max(1e-6, (bounds.max - bounds.min).length / 2);
    return OrbitCamera(target: center, distance: radius / math.tan(22.5 * math.pi / 180) * 1.15);
  }
}

/// Deformación lateral para visualizar el vaivén sísmico (exagerada, no es un resultado).
class Sway {
  final double amplitude; // desplazamiento en la cima (unidades de malla)
  final bool alongX;
  final double height; // altura de referencia (unidades de malla)
  const Sway(this.amplitude, this.alongX, this.height);
}

class RenderStats {
  final int drawn;
  final int culled;
  final Duration time;
  const RenderStats(this.drawn, this.culled, this.time);
}

/// Proyecta y ordena los triángulos visibles de todas las mallas.
(Vertices?, RenderStats) buildFrame(
  RenderMesh mesh,
  OrbitCamera cam,
  Size size,
  Set<String> hidden, {
  Map<String, int>? colorOverride,
  Sway? sway,
  List<RenderMesh> overlays = const [],
}) {
  final sw = Stopwatch()..start();
  final meshes = [mesh, ...overlays];
  final total = meshes.fold<int>(0, (a, m) => a + m.triangleCount);
  if (size.isEmpty || total == 0) return (null, RenderStats(0, 0, sw.elapsed));
  final view = makeViewMatrix(cam.eye, cam.target, Vector3(0, 1, 0));
  final near = math.max(0.001, cam.distance * 0.01);
  final proj = makePerspectiveMatrix(cam.fovY, size.width / size.height, near, cam.distance * 20);
  final vp = proj * view;
  final eye = cam.eye;
  final light = (eye - cam.target).normalized() + Vector3(0.3, 0.8, 0.2);
  light.normalize();
  final depth = Float64List(total);
  final screen = Float32List(total * 6);
  final shadedColor = Int32List(total);
  final visible = <int>[];
  var culled = 0;
  final v = Vector4.zero();
  var base = 0;
  for (final m in meshes) {
    final p = m.positions;
    for (var t = 0; t < m.triangleCount; t++) {
      final gi = base + t;
      if (hidden.contains(m.categories[t])) continue;
      final b = t * 9;
      final nx = m.normals[t * 3], ny = m.normals[t * 3 + 1], nz = m.normals[t * 3 + 2];
      var color = m.baseColors[t];
      final ov = colorOverride?[m.elementIds[t]];
      if (ov != null && m == mesh) color = ov;
      final alpha = (color >> 24) & 0xff;
      if (alpha == 255 && (eye.x - p[b]) * nx + (eye.y - p[b + 1]) * ny + (eye.z - p[b + 2]) * nz <= 0) {
        culled++;
        continue;
      }
      var ok = true;
      var z = 0.0;
      for (var k = 0; k < 3; k++) {
        var x = p[b + k * 3], y = p[b + k * 3 + 1], zz = p[b + k * 3 + 2];
        if (sway != null && m == mesh && sway.height > 0) {
          final d = sway.amplitude * (y / sway.height).clamp(0.0, 1.0);
          if (sway.alongX) {
            x += d;
          } else {
            zz += d;
          }
        }
        v.setValues(x, y, zz, 1);
        vp.transform(v);
        if (v.w <= near) {
          ok = false;
          break;
        }
        screen[gi * 6 + k * 2] = ((v.x / v.w) * 0.5 + 0.5) * size.width;
        screen[gi * 6 + k * 2 + 1] = (1 - ((v.y / v.w) * 0.5 + 0.5)) * size.height;
        z += v.w;
      }
      if (!ok) {
        culled++;
        continue;
      }
      final lambert = (nx * light.x + ny * light.y + nz * light.z).abs().clamp(0.0, 1.0);
      final k = 0.38 + 0.62 * lambert;
      final r = (((color >> 16) & 0xff) * k).round(), g = (((color >> 8) & 0xff) * k).round(), bl = ((color & 0xff) * k).round();
      shadedColor[gi] = (alpha << 24) | (r << 16) | (g << 8) | bl;
      depth[gi] = z;
      visible.add(gi);
    }
    base += m.triangleCount;
  }
  visible.sort((a, b) => depth[b].compareTo(depth[a])); // lejos → cerca
  final out = Float32List(visible.length * 6);
  final colors = Int32List(visible.length * 3);
  for (var i = 0; i < visible.length; i++) {
    final t = visible[i];
    out.setRange(i * 6, i * 6 + 6, screen, t * 6);
    colors[i * 3] = colors[i * 3 + 1] = colors[i * 3 + 2] = shadedColor[t];
  }
  return (Vertices.raw(VertexMode.triangles, out, colors: colors), RenderStats(visible.length, culled, sw.elapsed));
}
