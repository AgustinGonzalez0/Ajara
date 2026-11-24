import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:structura_geometry/structura_geometry.dart';

import 'software_renderer.dart';

/// Vista 3D compacta para el panel del proyecto: da una vuelta lenta al aparecer
/// (y se detiene, para no gastar batería), se puede girar con el dedo y un toque
/// abre el visor completo.
class MiniModelView extends StatefulWidget {
  final BuildingMesh mesh;
  final VoidCallback? onOpen;
  final Map<String, int>? colors;
  const MiniModelView({super.key, required this.mesh, this.onOpen, this.colors});
  @override
  State<MiniModelView> createState() => _MiniModelViewState();
}

class _MiniModelViewState extends State<MiniModelView> with SingleTickerProviderStateMixin {
  late RenderMesh _render = RenderMesh.fromBuildingMesh(widget.mesh);
  late OrbitCamera _cam = _initialCam();
  late double _yaw0 = _cam.yaw;
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(seconds: 18))
    ..addListener(() => setState(() => _cam.yaw = _yaw0 + _spin.value * 2 * math.pi))
    ..forward();

  OrbitCamera _initialCam() => _render.frame()
    ..pitch = 0.62
    ..distance *= 0.92;

  @override
  void didUpdateWidget(MiniModelView old) {
    super.didUpdateWidget(old);
    if (old.mesh != widget.mesh) {
      _render = RenderMesh.fromBuildingMesh(widget.mesh);
      _cam = _initialCam();
      _yaw0 = _cam.yaw;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onOpen,
      onPanStart: (_) => _spin.stop(),
      onPanUpdate: (d) => setState(() {
        _cam.yaw -= d.delta.dx * 0.01;
        _cam.pitch = (_cam.pitch + d.delta.dy * 0.01).clamp(0.1, math.pi / 2 - 0.01);
      }),
      child: CustomPaint(
        painter: _MiniPainter(_render, _cam, widget.colors, _cam.yaw, _cam.pitch),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _MiniPainter extends CustomPainter {
  final RenderMesh mesh;
  final OrbitCamera cam;
  final Map<String, int>? colors;
  final double yaw, pitch;
  _MiniPainter(this.mesh, this.cam, this.colors, this.yaw, this.pitch);

  @override
  void paint(Canvas canvas, Size size) {
    final (vertices, _) = buildFrame(mesh, cam, size, const {}, colorOverride: colors);
    if (vertices != null) canvas.drawVertices(vertices, BlendMode.dst, Paint());
  }

  @override
  bool shouldRepaint(_MiniPainter o) => o.yaw != yaw || o.pitch != pitch || o.mesh != mesh || o.colors != colors;
}
