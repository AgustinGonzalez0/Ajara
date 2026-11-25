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
import '../../services/share_service.dart';
import '../../widgets/common.dart';
import 'software_renderer.dart';

class Model3dData {
  final ProjectManifest project;
  final BuildingModel model;
  final File glb;
  final int glbBytes;
  final Map<String, Object?>? report;
  const Model3dData(this.project, this.model, this.glb, this.glbBytes, this.report);
}

final model3dProvider = FutureProvider.autoDispose.family<Model3dData, String>((ref, id) async {
  final store = ref.watch(projectStoreProvider);
  final project = await ref.watch(projectProvider(id).future);
  final a = project.activeAnalysis;
  if (a == null) throw StateError('Todavía no hay un análisis completado.');
  final bm = store.resolve(id, '${a.dir}/building_model.json');
  final model = BuildingModel.fromJson(jsonDecode(await bm.readAsString()) as Map<String, Object?>);
  final glb = store.resolve(id, '${a.dir}/model.glb');
  final bytes = await glb.exists() ? await glb.length() : 0;
  final rep = store.resolve(id, '${a.dir}/screening.json');
  final report = await rep.exists() ? (jsonDecode(await rep.readAsString()) as Map).cast<String, Object?>() : null;
  return Model3dData(project, model, glb, bytes, report);
});

const _hazardNames = {'seismic': 'Sismo', 'tsunami': 'Tsunami', 'wind': 'Viento'};
const _hazardIcons = {'seismic': Icons.vibration_rounded, 'tsunami': Icons.waves_rounded, 'wind': Icons.air_rounded};

class ModelScreen extends ConsumerWidget {
  final String projectId;
  final String? hazard;
  const ModelScreen({super.key, required this.projectId, this.hazard});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(model3dProvider(projectId));
    return async.when(
      loading: () => Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
          appBar: AppBar(title: const Text('Modelo 3D')),
          body: EmptyState(icon: Icons.view_in_ar_outlined, title: 'Modelo no disponible', message: '$e')),
      data: (d) => _Viewer(d, hazard, onShareGlb: () => _shareGlb(context, ref, d)),
    );
  }
}

Future<void> _shareGlb(BuildContext context, WidgetRef ref, Model3dData d) async {
  try {
    await ref.read(fileSharerProvider).shareFile(d.glb.path,
        mimeType: mimeGlb,
        subject: 'Modelo 3D — ${d.project.name}',
        text: 'Modelo 3D (glTF binario) generado con STRUCTURA AI a partir del plano. '
            'Las alturas son supuestos de visualización salvo que se indique lo contrario.');
    await ref.read(projectStoreProvider).appendHistory(d.project.id, 'glb_shared', {'bytes': d.glbBytes});
  } on Object catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo compartir el modelo: $e')));
    }
  }
}

/// Resultado de un peligro tomado del informe guardado.
class _HazardView {
  final String hazard;
  final Map<String, double> ratios;
  final Map<String, Object?> animation;
  final String overall;
  const _HazardView(this.hazard, this.ratios, this.animation, this.overall);

  static List<String> available(Map<String, Object?>? report) =>
      report == null ? const [] : [for (final r in (report['results'] as List).cast<Map>()) r['hazard'] as String];

  static _HazardView? from(Map<String, Object?>? report, String? hazard) {
    if (report == null || hazard == null) return null;
    for (final r in (report['results'] as List).cast<Map>()) {
      if (r['hazard'] == hazard) {
        final ratios = <String, double>{};
        (r['element_ratios'] as Map).forEach((k, v) => ratios[k as String] = v == null ? double.infinity : (v as num).toDouble());
        return _HazardView(hazard, ratios, (r['animation'] as Map).cast<String, Object?>(), r['overall'] as String);
      }
    }
    return null;
  }
}

class _Viewer extends StatefulWidget {
  final Model3dData data;
  final String? hazard;
  final VoidCallback onShareGlb;
  const _Viewer(this.data, this.hazard, {required this.onShareGlb});
  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> with SingleTickerProviderStateMixin {
  late String? _hazardId = widget.hazard;
  late _HazardView? _hz = _HazardView.from(widget.data.report, _hazardId);
  late BuildingMesh _mesh = _buildMesh();
  late RenderMesh _render = RenderMesh.fromBuildingMesh(_mesh);
  late OrbitCamera _cam = _framed();
  late OrbitCamera _home = _cam.copy();
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(seconds: 4));
  final Set<String> _hidden = {};
  double _startDistance = 1;
  RenderStats? _stats;
  bool _playing = false;

  BuildingMesh _buildMesh() {
    final model = widget.data.model;
    final b = (widget.data.report?['building'] as Map?)?.cast<String, Object?>();
    if (_hz != null && b != null && model.hasVerifiedScale) {
      // Altura declarada por el profesional en la evaluación (no inferida del plano).
      final h = (b['floors'] as int) * (b['story_height_m'] as num).toDouble();
      final k = model.scale!.pxToMeters(1)!;
      return const MeshBuilder().build(model,
          assumptions: DisplayAssumptions(
            units: 'm',
            pxToUnits: k,
            wallHeight: h,
            doorHeight: math.min(2.05, h * 0.8),
            windowSill: 0.9,
            windowHead: math.min(2.1, h * 0.85),
            stairSteps: 15,
            rationale: 'Altura total declarada para la evaluación: ${b['floors']} piso(s) × '
                '${(b['story_height_m'] as num).toStringAsFixed(2).replaceAll('.', ',')} m = '
                '${h.toStringAsFixed(2).replaceAll('.', ',')} m. Planta en metros (escala verificada).',
          ));
    }
    return const MeshBuilder().build(model);
  }

  /// Encuadre con margen: los controles flotantes ocupan parte de la pantalla.
  OrbitCamera _framed() {
    // En un celular vertical el ancho visible es angosto: se aleja la cámara en proporción.
    final s = MediaQuery.sizeOf(context);
    final portrait = s.width > 0 && s.height > s.width ? s.height / s.width * 0.8 : 1.0;
    return _render.frame()..distance *= 1.35 * math.max(1.0, portrait);
  }

  @override
  void didUpdateWidget(_Viewer old) {
    super.didUpdateWidget(old);
    // Llegaron datos nuevos (escala calibrada, evaluación guardada): se reconstruye todo.
    if (old.data != widget.data) _setHazard(_hazardId, reframe: true);
  }

  void _setHazard(String? id, {bool reframe = false}) {
    setState(() {
      _hazardId = id;
      _hz = _HazardView.from(widget.data.report, id);
      _mesh = _buildMesh();
      _render = RenderMesh.fromBuildingMesh(_mesh);
      final framed = _framed();
      if (reframe) {
        _cam = framed.copy();
      } else {
        _cam
          ..distance = framed.distance
          ..target = framed.target;
      }
      _home = framed;
      final animate = _hz != null && _hz!.hazard != 'wind';
      _playing = animate;
      animate ? _anim.repeat() : _anim.stop();
    });
  }

  @override
  void initState() {
    super.initState();
    _anim.addListener(() => setState(() {}));
    if (_hz != null && _hz!.hazard != 'wind') {
      _anim.repeat();
      _playing = true;
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _reset() => setState(() => _cam = _home.copy());
  void _top() => setState(() => _cam = _home.copy()
    ..pitch = math.pi / 2 - 0.001
    ..yaw = 0);

  void _pan(Offset delta, Size size) {
    final c = _cam;
    final scale = c.distance * 2 * math.tan(c.fovY / 2) / size.height;
    final right = Vector3(math.cos(c.yaw), 0, -math.sin(c.yaw));
    final forward = Vector3(-math.sin(c.yaw), 0, -math.cos(c.yaw));
    c.target = c.target - right * (delta.dx * scale) + forward * (delta.dy * scale) * -1;
  }

  Map<String, int>? get _colors => _hz == null ? null : {for (final e in _hz!.ratios.entries) e.key: heatColor(e.value)};

  Sway? get _sway {
    final hz = _hz;
    if (hz == null || hz.hazard != 'seismic' || !_playing) return null;
    final h = _mesh.assumptions.wallHeight;
    const cycles = 4.0; // oscilaciones por vuelta de animación (continuo, sin pausas)
    final phase = math.sin(_anim.value * 2 * math.pi * cycles);
    return Sway(phase * h * 0.08, true, h);
  }

  List<RenderMesh> get _overlays {
    final hz = _hz;
    if (hz == null || hz.hazard != 'tsunami') return const [];
    final depth = (hz.animation['depth_m'] as num).toDouble();
    final level = depth * (_playing ? Curves.easeInOut.transform((_anim.value * 1.6).clamp(0.0, 1.0)) : 1.0);
    final b = _render.bounds;
    final m = math.max(b.max.x - b.min.x, b.max.z - b.min.z) * 0.15;
    final water = MeshPart('water')..addBox(b.min.x - m, b.min.z - m, b.max.x + m, b.max.z + m, 0, math.max(0.01, level), 'water');
    return [RenderMesh.fromParts([water])];
  }

  // ------------------------------------------------------------------ hojas

  void _showLayers() => showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (c) => StatefulBuilder(
          builder: (c, setSheet) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl), children: [
            Text('Capas', style: Theme.of(c).textTheme.titleMedium),
            ..._layerTiles(() {
              setSheet(() {});
              setState(() {});
            }),
          ]),
        ),
      );

  List<Widget> _layerTiles(VoidCallback changed) => [
        for (final cat in ['wall', 'door', 'window', 'column', 'stairs', 'floor'])
          if (_mesh.parts.containsKey(cat))
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: !_hidden.contains(cat),
              onChanged: (v) {
                v == true ? _hidden.remove(cat) : _hidden.add(cat);
                changed();
              },
              title: Text(StructuraColors.classLabels[cat] ?? (cat == 'floor' ? 'Piso (visualización)' : cat)),
              secondary: Container(width: 12, height: 12, color: StructuraColors.byClass[cat] ?? StructuraColors.textMuted),
            ),
      ];

  void _showInfo() => showModalBottomSheet(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (c) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          builder: (c, scroll) => ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl), children: _info(c)),
        ),
      );

  List<Widget> _info(BuildContext context) {
    final d = widget.data;
    final a = _mesh.assumptions;
    final t = Theme.of(context);
    return [
      NoticeBanner(a.rationale, icon: Icons.straighten_rounded, color: StructuraColors.accent),
      if (d.project.activeAnalysis?.isTestModel == true && d.project.activeAnalysis?.model['engine'] != 'classic') ...[
        const SizedBox(height: Gap.sm),
        NoticeBanner('Geometría detectada sin validación con planos reales: ${d.project.activeAnalysis!.model['trust_label']}',
            icon: Icons.science_outlined),
      ],
      const SectionLabel('Datos'),
      _kv(context, 'Triángulos', '${_mesh.triangleCount}'),
      _kv(context, 'Elementos', '${d.model.allElements.length}'),
      _kv(context, 'Unidades', a.units == 'm' ? 'metros (escala verificada)' : 'píxeles del plano'),
      _kv(context, 'GLB', d.glbBytes > 0 ? formatBytes(d.glbBytes) : 'no generado'),
      if (_stats != null) _kv(context, 'Frame', '${_stats!.drawn} tri · ${(_stats!.time.inMicroseconds / 1000).toStringAsFixed(1)} ms'),
      const SizedBox(height: Gap.sm),
      Text('El GLB se abre en visores glTF, Blender o navegadores. Archivo en el proyecto:\n${d.glb.path}',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ];
  }

  Widget _kv(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Text(v, style: const TextStyle(fontFeatures: tabular)),
        ]),
      );

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final d = widget.data;
    final a = _mesh.assumptions;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final hazards = _HazardView.available(d.report);
    final hz = _hz;

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
            painter: _MeshPainter(_render, _cam, _hidden, (s) => _stats = s,
                colors: _colors, sway: _sway, overlays: _overlays, tick: _anim.value),
          ),
        ),
      );
    });

    final hazardBar = hazards.isEmpty
        ? null
        : GlassPanel(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _modeChip('Modelo', Icons.view_in_ar_rounded, null),
                for (final h in hazards) _modeChip(_hazardNames[h] ?? h, _hazardIcons[h] ?? Icons.warning_amber, h),
              ]),
            ),
          );

    final legend = hz == null
        ? null
        : GlassPanel(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const _HeatLegend(),
              const SizedBox(height: 6),
              Text(
                hz.hazard == 'seismic'
                    ? 'Deformación EXAGERADA para ver el modo de vibración. Colores: demanda/capacidad por muro.'
                    : hz.hazard == 'tsunami'
                        ? 'Agua hasta ${(hz.animation['depth_m'] as num).toStringAsFixed(2).replaceAll('.', ',')} m '
                            '(${(hz.animation['velocity_ms'] as num).toStringAsFixed(1).replaceAll('.', ',')} m/s). Colores: demanda/capacidad por muro.'
                        : 'Colores: demanda/capacidad por muro ante la presión de viento.',
                style: t.textTheme.bodySmall,
              ),
              Text(a.rationale, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          );

    final toolbar = GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(children: [
        _tool(Icons.threed_rotation_rounded, 'Perspectiva', _reset, key: const Key('view_persp')),
        _tool(Icons.crop_square_rounded, 'Planta', _top, key: const Key('view_top')),
        _tool(Icons.layers_outlined, 'Capas', _showLayers, key: const Key('view_layers')),
        if (hz != null && hz.hazard != 'wind')
          _tool(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, _playing ? 'Pausar' : 'Animar', () {
            setState(() {
              _playing = !_playing;
              _playing ? _anim.repeat() : _anim.stop();
            });
          }, key: const Key('view_play')),
        _tool(Icons.info_outline_rounded, 'Info', _showInfo, key: const Key('view_info')),
      ]),
    );

    final status = StatusPill(
        hz != null ? 'SIMULACIÓN PRELIMINAR' : (a.units == 'm' ? 'ALTURAS DE VISUALIZACIÓN' : 'UNIDADES: PX · ALTURA SUPUESTA'),
        color: StructuraColors.warning,
        icon: Icons.info_outline);

    final view = Container(
      color: t.brightness == Brightness.dark ? StructuraColors.ink : const Color(0xFFEFF2F6),
      child: Stack(children: [
        Positioned.fill(child: viewport),
        Positioned(
          left: Gap.md,
          right: Gap.md,
          top: Gap.sm,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ?hazardBar,
            const SizedBox(height: Gap.sm),
            status,
          ]),
        ),
        if (!wide)
          Positioned(
            left: Gap.md,
            right: Gap.md,
            bottom: Gap.md,
            child: SafeArea(
              top: false,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (legend != null) ...[legend, const SizedBox(height: Gap.sm)],
                toolbar,
              ]),
            ),
          ),
      ]),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(hz == null ? 'Modelo 3D' : 'Simulación 3D'),
        actions: [
          IconButton(
            key: const Key('share_glb'),
            tooltip: 'Compartir modelo 3D (GLB)',
            onPressed: d.glbBytes > 0 ? widget.onShareGlb : null,
            icon: const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
      body: wide
          ? Row(children: [
              Expanded(child: view),
              SizedBox(
                width: 340,
                child: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
                  if (legend != null) ...[legend, const SizedBox(height: Gap.md)],
                  toolbar,
                  const SectionLabel('Capas'),
                  ..._layerTiles(() => setState(() {})),
                  ..._info(context),
                ]),
              ),
            ])
          : view,
    );
  }

  Widget _modeChip(String label, IconData icon, String? id) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: ChoiceChip(
          key: Key('mode_${id ?? 'model'}'),
          avatar: Icon(icon, size: 16),
          label: Text(label),
          selected: _hazardId == id,
          visualDensity: VisualDensity.compact,
          onSelected: (_) => _setHazard(id),
        ),
      );

  Widget _tool(IconData icon, String label, VoidCallback onTap, {Key? key}) => Expanded(
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 22),
              const SizedBox(height: 2),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 0.2)),
            ]),
          ),
        ),
      );
}

class _HeatLegend extends StatelessWidget {
  const _HeatLegend();
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 8,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: LinearGradient(colors: [for (final r in [0.0, 0.35, 0.7, 0.85, 1.0]) Color(heatColor(r))]),
          ),
        ),
        const SizedBox(height: 3),
        const Row(children: [
          Expanded(child: Text('0 · bajo', style: TextStyle(fontSize: 11))),
          Expanded(child: Text('0,7 · revisar', textAlign: TextAlign.center, style: TextStyle(fontSize: 11))),
          Expanded(child: Text('≥ 1 · supera', textAlign: TextAlign.end, style: TextStyle(fontSize: 11))),
        ]),
      ]);
}

class _MeshPainter extends CustomPainter {
  final RenderMesh mesh;
  final OrbitCamera cam;
  final Set<String> hidden;
  final void Function(RenderStats) onStats;
  final Map<String, int>? colors;
  final Sway? sway;
  final List<RenderMesh> overlays;
  final double tick;
  final double _yaw, _pitch, _dist, _tx, _ty, _tz;
  final int _hiddenHash;
  _MeshPainter(this.mesh, this.cam, this.hidden, this.onStats,
      {this.colors, this.sway, this.overlays = const [], this.tick = 0})
      : _yaw = cam.yaw,
        _pitch = cam.pitch,
        _dist = cam.distance,
        _tx = cam.target.x,
        _ty = cam.target.y,
        _tz = cam.target.z,
        _hiddenHash = Object.hashAllUnordered(hidden);

  @override
  void paint(Canvas canvas, Size size) {
    final (vertices, stats) = buildFrame(mesh, cam, size, hidden, colorOverride: colors, sway: sway, overlays: overlays);
    onStats(stats);
    if (vertices != null) canvas.drawVertices(vertices, BlendMode.dst, Paint());
  }

  @override
  bool shouldRepaint(_MeshPainter o) =>
      o._yaw != _yaw ||
      o._pitch != _pitch ||
      o._dist != _dist ||
      o._tx != _tx ||
      o._ty != _ty ||
      o._tz != _tz ||
      o._hiddenHash != _hiddenHash ||
      o.mesh != mesh ||
      o.colors != colors ||
      o.tick != tick;
}
