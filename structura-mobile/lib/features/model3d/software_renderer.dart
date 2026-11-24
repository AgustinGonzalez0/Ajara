/// Renderizador 3D por software sobre Canvas.
///
/// Decisión: no hay un paquete 3D mantenido disponible offline en este entorno
/// y las alternativas comunes (WebView + model-viewer, flutter_cube) agregan
/// dependencias pesadas o abandonadas. Para mallas arquitectónicas (miles de
/// triángulos planos) alcanza con: proyección en perspectiva, descarte de caras
/// traseras, orden por profundidad (pintor) y sombreado plano, dibujando todo
/// en UNA llamada `drawVertices`. Si en el futuro se necesitan cientos de miles
/// de triángulos, se reemplaza por un renderer GPU sin tocar la malla.
library;

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
  final Aabb3 bounds;
  RenderMesh._(this.positions, this.normals, this.baseColors, this.categories, this.bounds);

  int get triangleCount => baseColors.length;

  factory RenderMesh.fromBuildingMesh(BuildingMesh mesh) {
    final pos = <double>[], nor = <double>[], cols = <int>[], cats = <String>[];
    final mn = Vector3.all(double.infinity), mx = Vector3.all(double.negativeInfinity);
    for (final part in mesh.parts.values) {
      final c = categoryColors[part.category] ?? const [0.8, 0.8, 0.8, 1.0];
      final argb = (((c[3] * 255).round() & 0xff) << 24) |
          (((c[0] * 255).round() & 0xff) << 16) |
          (((c[1] * 255).round() & 0xff) << 8) |
          ((c[2] * 255).round() & 0xff);
      for (var t = 0; t < part.indices.length; t += 3) {
        for (var k = 0; k < 3; k++) {
          final i = part.indices[t + k] * 3;
          final v = Vector3(part.positions[i], part.positions[i + 1], part.positions[i + 2]);
          pos.addAll([v.x, v.y, v.z]);
          mn.x = math.min(mn.x, v.x);
          mn.y = math.min(mn.y, v.y);
          mn.z = math.min(mn.z, v.z);
          mx.x = math.max(mx.x, v.x);
          mx.y = math.max(mx.y, v.y);
          mx.z = math.max(mx.z, v.z);
        }
        final i0 = part.indices[t] * 3;
        nor.addAll([part.normals[i0], part.normals[i0 + 1], part.normals[i0 + 2]]);
        cols.add(argb);
        cats.add(part.category);
      }
    }
    return RenderMesh._(Float64List.fromList(pos), Float64List.fromList(nor), Int32List.fromList(cols), cats,
        cols.isEmpty ? Aabb3.minMax(Vector3.zero(), Vector3.zero()) : Aabb3.minMax(mn, mx));
  }

  /// Cámara inicial que encuadra toda la malla.
  OrbitCamera frame() {
    final center = (bounds.min + bounds.max) * 0.5;
    final radius = math.max(1e-6, (bounds.max - bounds.min).length / 2);
    return OrbitCamera(target: center, distance: radius / math.tan(22.5 * math.pi / 180) * 1.15);
  }
}

class RenderStats {
  final int drawn;
  final int culled;
  final Duration time;
  const RenderStats(this.drawn, this.culled, this.time);
}

/// Proyecta y ordena los triángulos visibles. Devuelve los vértices listos para dibujar.
(Vertices?, RenderStats) buildFrame(RenderMesh mesh, OrbitCamera cam, Size size, Set<String> hidden) {
  final sw = Stopwatch()..start();
  if (size.isEmpty || mesh.triangleCount == 0) return (null, RenderStats(0, 0, sw.elapsed));
  final view = makeViewMatrix(cam.eye, cam.target, Vector3(0, 1, 0));
  final near = math.max(0.001, cam.distance * 0.01);
  final proj = makePerspectiveMatrix(cam.fovY, size.width / size.height, near, cam.distance * 20);
  final vp = proj * view;
  final eye = cam.eye;
  final light = (eye - cam.target).normalized() + Vector3(0.3, 0.8, 0.2);
  light.normalize();
  final n = mesh.triangleCount;
  final depth = Float64List(n);
  final screen = Float32List(n * 6);
  final visible = <int>[];
  var culled = 0;
  final p = mesh.positions;
  final v = Vector4.zero();
  for (var t = 0; t < n; t++) {
    if (hidden.contains(mesh.categories[t])) continue;
    final b = t * 9;
    // Descarte de caras traseras (normal vs. dirección a la cámara).
    final nx = mesh.normals[t * 3], ny = mesh.normals[t * 3 + 1], nz = mesh.normals[t * 3 + 2];
    final alpha = (mesh.baseColors[t] >> 24) & 0xff;
    if (alpha == 255 && (eye.x - p[b]) * nx + (eye.y - p[b + 1]) * ny + (eye.z - p[b + 2]) * nz <= 0) {
      culled++;
      continue;
    }
    var ok = true;
    var z = 0.0;
    for (var k = 0; k < 3; k++) {
      v.setValues(p[b + k * 3], p[b + k * 3 + 1], p[b + k * 3 + 2], 1);
      vp.transform(v);
      if (v.w <= near) {
        ok = false;
        break;
      }
      screen[t * 6 + k * 2] = ((v.x / v.w) * 0.5 + 0.5) * size.width;
      screen[t * 6 + k * 2 + 1] = (1 - ((v.y / v.w) * 0.5 + 0.5)) * size.height;
      z += v.w;
    }
    if (!ok) {
      culled++;
      continue;
    }
    depth[t] = z;
    visible.add(t);
  }
  visible.sort((a, b) => depth[b].compareTo(depth[a])); // lejos → cerca
  final out = Float32List(visible.length * 6);
  final colors = Int32List(visible.length * 3);
  for (var i = 0; i < visible.length; i++) {
    final t = visible[i];
    out.setRange(i * 6, i * 6 + 6, screen, t * 6);
    final lambert = (mesh.normals[t * 3] * light.x + mesh.normals[t * 3 + 1] * light.y + mesh.normals[t * 3 + 2] * light.z)
        .abs()
        .clamp(0.0, 1.0);
    final k = 0.38 + 0.62 * lambert;
    final c = mesh.baseColors[t];
    final a = (c >> 24) & 0xff;
    final r = (((c >> 16) & 0xff) * k).round(), g = (((c >> 8) & 0xff) * k).round(), bl = ((c & 0xff) * k).round();
    final shaded = (a << 24) | (r << 16) | (g << 8) | bl;
    colors[i * 3] = shaded;
    colors[i * 3 + 1] = shaded;
    colors[i * 3 + 2] = shaded;
  }
  final vertices = Vertices.raw(VertexMode.triangles, out, colors: colors);
  return (vertices, RenderStats(visible.length, culled, sw.elapsed));
}
