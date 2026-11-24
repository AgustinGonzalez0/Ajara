import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_model/structura_model.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/project_models.dart';
import '../../widgets/common.dart';
import 'software_renderer.dart';

class Model3dData {
  final ProjectManifest project;
  final BuildingModel model;
  final BuildingMesh mesh;
  final RenderMesh renderMesh;
  final File glb;
  final int glbBytes;
  const Model3dData(this.project, this.model, this.mesh, this.renderMesh, this.glb, this.glbBytes);
}

final model3dProvider = FutureProvider.autoDispose.family<Model3dData, String>((ref, id) async {
  final store = ref.watch(projectStoreProvider);
  final project = await ref.watch(projectProvider(id).future);
  final a = project.activeAnalysis;
  if (a == null) throw StateError('Todavía no hay un análisis completado.');
  final bm = store.resolve(id, '${a.dir}/building_model.json');
  final model = BuildingModel.fromJson(jsonDecode(await bm.readAsString()) as Map<String, Object?>);
  // La malla es determinista: se regenera desde el Building Model (no se re-procesa el plano).
  final mesh = const MeshBuilder().build(model);
  final glb = store.resolve(id, '${a.dir}/model.glb');
  final bytes = await glb.exists() ? await glb.length() : 0;
  return Model3dData(project, model, mesh, RenderMesh.fromBuildingMesh(mesh), glb, bytes);
});

class ModelScreen extends ConsumerWidget {
  final String projectId;
  const ModelScreen({super.key, required this.projectId});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(model3dProvider(projectId));
    return Scaffold(
      appBar: AppBar(title: const Text('Modelo 3D')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(icon: Icons.view_in_ar_outlined, title: 'Modelo no disponible', message: '$e'),
        data: (d) => _Viewer(d),
      ),
    );
  }
}

class _Viewer extends StatefulWidget {
  final Model3dData data;
  const _Viewer(this.data);
  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  late OrbitCamera _cam = widget.data.renderMesh.frame();
  late final OrbitCamera _home = _cam.copy();
  final Set<String> _hidden = {};
  double _startDistance = 1;
  RenderStats? _stats;

  void _reset() => setState(() => _cam = _home.copy());
  void _top() => setState(() => _cam = _home.copy()..pitch = math.pi / 2 - 0.001..yaw = 0);

  void _pan(Offset delta, Size size) {
    final c = _cam;
    final scale = c.distance * 2 * math.tan(c.fovY / 2) / size.height;
    final right = Vector3(math.cos(c.yaw), 0, -math.sin(c.yaw));
    final forward = Vector3(-math.sin(c.yaw), 0, -math.cos(c.yaw));
    c.target = c.target - right * (delta.dx * scale) + forward * (delta.dy * scale) * -1;
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final a = d.mesh.assumptions;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final viewport = LayoutBuilder(builder: (context, c) {
      final size = c.biggest;
      return Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) setState(() => _cam.distance = (_cam.distance * math.pow(1.0015, e.scrollDelta.dy)).toDouble());
        },
        child: GestureDetector(
          onScaleStart: (_) => _startDistance = _cam.distance,
          onScaleUpdate: (s) => setState(() {
            if (s.pointerCount >= 2) {
              _cam.distance = (_startDistance / s.scale).clamp(_home.distance * 0.05, _home.distance * 8);
              _pan(s.focalPointDelta, size);
            } else {
              _cam.yaw -= s.focalPointDelta.dx * 0.008;
              _cam.pitch = (_cam.pitch + s.focalPointDelta.dy * 0.008).clamp(0.05, math.pi / 2 - 0.001);
            }
          }),
          child: CustomPaint(
            size: size,
            painter: _MeshPainter(d.renderMesh, _cam, _hidden, (s) => _stats = s),
          ),
        ),
      );
    });

    final controls = ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      NoticeBanner(a.rationale, icon: Icons.straighten_rounded, color: StructuraColors.accent),
      if (d.project.activeAnalysis?.isTestModel == true) ...[
        const SizedBox(height: Gap.sm),
        const NoticeBanner('Geometría derivada de un modelo de prueba (datos sintéticos).', icon: Icons.science_outlined),
      ],
      const SectionLabel('Capas'),
      for (final cat in ['wall', 'door', 'window', 'column', 'stairs', 'floor'])
        if (d.mesh.parts.containsKey(cat))
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: !_hidden.contains(cat),
            onChanged: (v) => setState(() => v == true ? _hidden.remove(cat) : _hidden.add(cat)),
            title: Text(StructuraColors.classLabels[cat] ?? (cat == 'floor' ? 'Piso (visualización)' : cat)),
            secondary: Container(
              width: 12,
              height: 12,
              color: StructuraColors.byClass[cat] ?? StructuraColors.textMuted,
            ),
          ),
      const SectionLabel('Vista'),
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        OutlinedButton.icon(onPressed: _reset, icon: const Icon(Icons.threed_rotation_rounded), label: const Text('Perspectiva')),
        OutlinedButton.icon(onPressed: _top, icon: const Icon(Icons.crop_square_rounded), label: const Text('Planta')),
      ]),
      const SectionLabel('Datos'),
      _kv(context, 'Triángulos', '${d.mesh.triangleCount}'),
      _kv(context, 'Elementos', '${d.model.allElements.length}'),
      _kv(context, 'Unidades', a.units == 'm' ? 'metros (escala verificada)' : 'píxeles del plano'),
      _kv(context, 'GLB', d.glbBytes > 0 ? formatBytes(d.glbBytes) : 'no generado'),
      if (_stats != null) _kv(context, 'Frame', '${_stats!.drawn} tri · ${_stats!.time.inMicroseconds / 1000} ms'),
      const SizedBox(height: Gap.sm),
      Text('Archivo GLB guardado en el proyecto:\n${d.glb.path}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),
      const PendingFeature(title: 'Edición 3D', detail: 'Mover, agregar o eliminar elementos desde el visor.'),
      const SizedBox(height: Gap.sm),
      const PendingFeature(title: 'Compartir / exportar GLB', detail: 'Envío del archivo a otras apps mediante el sistema.'),
    ]);

    final view = Container(
      color: Theme.of(context).brightness == Brightness.dark ? StructuraColors.ink : const Color(0xFFEFF2F6),
      child: Stack(children: [
        Positioned.fill(child: viewport),
        Positioned(
          left: Gap.md,
          top: Gap.md,
          child: StatusPill(a.units == 'm' ? 'ALTURAS DE VISUALIZACIÓN' : 'UNIDADES: PX · ALTURA SUPUESTA',
              color: StructuraColors.warning, icon: Icons.info_outline),
        ),
      ]),
    );
    if (wide) return Row(children: [Expanded(child: view), SizedBox(width: 340, child: controls)]);
    return Column(children: [Expanded(flex: 3, child: view), const Divider(), Expanded(flex: 2, child: controls)]);
  }

  Widget _kv(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Text(v, style: const TextStyle(fontFeatures: tabular)),
        ]),
      );
}

class _MeshPainter extends CustomPainter {
  final RenderMesh mesh;
  final OrbitCamera cam;
  final Set<String> hidden;
  final void Function(RenderStats) onStats;
  // Se copian los parámetros para detectar cambios aunque la cámara sea mutable.
  final double _yaw, _pitch, _dist, _tx, _ty, _tz;
  final int _hiddenHash;
  _MeshPainter(this.mesh, this.cam, this.hidden, this.onStats)
      : _yaw = cam.yaw,
        _pitch = cam.pitch,
        _dist = cam.distance,
        _tx = cam.target.x,
        _ty = cam.target.y,
        _tz = cam.target.z,
        _hiddenHash = Object.hashAllUnordered(hidden);

  @override
  void paint(Canvas canvas, Size size) {
    final (vertices, stats) = buildFrame(mesh, cam, size, hidden);
    onStats(stats);
    if (vertices != null) canvas.drawVertices(vertices, BlendMode.dst, Paint());
  }

  @override
  bool shouldRepaint(_MeshPainter o) =>
      o._yaw != _yaw || o._pitch != _pitch || o._dist != _dist || o._tx != _tx || o._ty != _ty || o._tz != _tz ||
      o._hiddenHash != _hiddenHash || o.mesh != mesh;
}
