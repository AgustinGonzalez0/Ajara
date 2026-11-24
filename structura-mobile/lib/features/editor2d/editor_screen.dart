import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:structura_model/structura_model.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/project_models.dart';
import '../../widgets/common.dart';

/// Datos que muestra el editor para el proyecto activo.
class EditorData {
  final ProjectManifest project;
  final File raster;
  final ui.Image? segmentation; // overlay RGBA ya coloreado
  final BuildingModel? model;
  const EditorData(this.project, this.raster, this.segmentation, this.model);
}

const _palette = <int, (int, int, int)>{1: (220, 60, 60), 2: (60, 180, 75), 3: (65, 105, 225), 4: (245, 190, 50), 5: (170, 80, 190)};

Uint8List _colorize(Uint8List labelsPng) {
  final im = img.decodePng(labelsPng)!;
  final out = Uint8List(im.width * im.height * 4 + 8);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, im.width);
  bd.setUint32(4, im.height);
  var o = 8;
  for (final px in im) {
    final c = _palette[px.r.toInt()];
    if (c != null) {
      out[o] = c.$1;
      out[o + 1] = c.$2;
      out[o + 2] = c.$3;
      out[o + 3] = 150;
    }
    o += 4;
  }
  return out;
}

Future<ui.Image> _rgbaToImage(Uint8List packed) {
  final bd = ByteData.sublistView(packed);
  final w = bd.getUint32(0), h = bd.getUint32(4);
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(Uint8List.sublistView(packed, 8), w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

final editorDataProvider = FutureProvider.autoDispose.family<EditorData, String>((ref, id) async {
  final store = ref.watch(projectStoreProvider);
  final project = await ref.watch(projectProvider(id).future);
  final plan = project.activePlan;
  if (plan == null) throw StateError('El proyecto no tiene plano');
  final raster = store.resolve(id, plan.rasterFile);
  final a = project.activeAnalysis;
  ui.Image? seg;
  BuildingModel? model;
  if (a != null && a.planId == plan.id) {
    final labels = store.resolve(id, '${a.dir}/labels.png');
    if (await labels.exists()) {
      final bytes = await labels.readAsBytes();
      seg = await _rgbaToImage(await Isolate.run(() => _colorize(bytes)));
    }
    final bm = store.resolve(id, '${a.dir}/building_model.json');
    if (await bm.exists()) {
      model = BuildingModel.fromJson(jsonDecode(await bm.readAsString()) as Map<String, Object?>);
    }
  }
  return EditorData(project, raster, seg, model);
});

class EditorScreen extends ConsumerStatefulWidget {
  final String projectId;
  const EditorScreen({super.key, required this.projectId});
  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  final _tc = TransformationController();
  bool _showPlan = true, _showSeg = true, _showVectors = true;
  String? _selected;
  Size? _viewport;
  double _scale = 1;

  @override
  void initState() {
    super.initState();
    _tc.addListener(() {
      final s = _tc.value.getMaxScaleOnAxis();
      if ((s - _scale).abs() > 0.005) setState(() => _scale = s);
    });
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _fit(int w, int h) {
    final vp = _viewport;
    if (vp == null) return;
    final s = (vp.width / w).clamp(0.0, vp.height / h) * 0.95;
    final dx = (vp.width - w * s) / 2, dy = (vp.height - h * s) / 2;
    _tc.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(editorDataProvider(widget.projectId));
    return Scaffold(
      appBar: AppBar(title: const Text('Editor 2D')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(icon: Icons.layers_clear_outlined, title: 'No se puede abrir el editor', message: '$e'),
        data: (d) => _body(context, d),
      ),
    );
  }

  Widget _body(BuildContext context, EditorData d) {
    final plan = d.project.activePlan!;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final canvas = LayoutBuilder(builder: (context, c) {
      final first = _viewport == null;
      _viewport = c.biggest;
      if (first) WidgetsBinding.instance.addPostFrameCallback((_) => _fit(plan.width, plan.height));
      return ClipRect(
        child: BlueprintGrid(
          child: Stack(children: [
            InteractiveViewer(
              transformationController: _tc,
              constrained: false,
              minScale: 0.02,
              maxScale: 16,
              boundaryMargin: const EdgeInsets.all(2000),
              child: SizedBox(
                width: plan.width.toDouble(),
                height: plan.height.toDouble(),
                child: Stack(children: [
                  if (_showPlan) Positioned.fill(child: Image.file(d.raster, fit: BoxFit.fill, filterQuality: FilterQuality.medium)),
                  if (!_showPlan) Positioned.fill(child: Container(color: Colors.white)),
                  if (_showSeg && d.segmentation != null)
                    Positioned.fill(child: RawImage(image: d.segmentation, fit: BoxFit.fill, filterQuality: FilterQuality.none)),
                  if (_showVectors && d.model != null)
                    Positioned.fill(child: CustomPaint(painter: VectorPainter(d.model!, _selected, 1 / _scale))),
                ]),
              ),
            ),
            Positioned(
              right: Gap.md,
              bottom: Gap.md,
              child: _ZoomBar(scale: _scale, onFit: () => _fit(plan.width, plan.height)),
            ),
          ]),
        ),
      );
    });
    final panel = _LayerPanel(
      data: d,
      showPlan: _showPlan,
      showSeg: _showSeg,
      showVectors: _showVectors,
      selected: _selected,
      onToggle: (layer, v) => setState(() {
        if (layer == 'plan') _showPlan = v;
        if (layer == 'seg') _showSeg = v;
        if (layer == 'vec') _showVectors = v;
      }),
      onSelect: (id) => setState(() => _selected = id == _selected ? null : id),
    );
    if (wide) {
      return Row(children: [Expanded(child: canvas), SizedBox(width: 340, child: panel)]);
    }
    return Column(children: [Expanded(flex: 3, child: canvas), const Divider(), Expanded(flex: 2, child: panel)]);
  }
}

class _ZoomBar extends StatelessWidget {
  final double scale;
  final VoidCallback onFit;
  const _ZoomBar({required this.scale, required this.onFit});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          child: Text('${(scale * 100).toStringAsFixed(0)}%', style: const TextStyle(fontFeatures: tabular)),
        ),
        IconButton(tooltip: 'Ajustar a pantalla', icon: const Icon(Icons.fit_screen_rounded), onPressed: onFit),
      ]),
    );
  }
}

class _LayerPanel extends StatelessWidget {
  final EditorData data;
  final bool showPlan, showSeg, showVectors;
  final String? selected;
  final void Function(String, bool) onToggle;
  final void Function(String) onSelect;
  const _LayerPanel({
    required this.data,
    required this.showPlan,
    required this.showSeg,
    required this.showVectors,
    required this.selected,
    required this.onToggle,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final elements = data.model?.allElements.toList() ?? const <BuildingElement>[];
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      const SectionLabel('Capas'),
      _toggle('Plano', 'plan', showPlan, true),
      _toggle('Segmentación (IA)', 'seg', showSeg, data.segmentation != null),
      _toggle('Vectores (Building Model)', 'vec', showVectors, data.model != null),
      if (data.project.activeAnalysis?.isTestModel == true) ...[
        const SizedBox(height: Gap.md),
        NoticeBanner('Detecciones sin validación con planos reales: ${data.project.activeAnalysis!.model['trust_label']}',
            icon: Icons.science_outlined),
      ],
      if (data.model == null) ...[
        const SizedBox(height: Gap.md),
        const NoticeBanner('Todavía no hay análisis para este plano. Ejecutá el análisis IA para ver detecciones.',
            color: StructuraColors.accent),
      ],
      SectionLabel('Elementos (${elements.length})'),
      for (final e in elements.take(300))
        ListTile(
          dense: true,
          selected: e.id == selected,
          selectedTileColor: StructuraColors.accentSoft,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Container(width: 10, height: 10, color: StructuraColors.byClass[e.kind.name] ?? Colors.grey),
          title: Text('${StructuraColors.classLabels[e.kind.name] ?? e.kind.name} · ${e.id}', style: const TextStyle(fontFeatures: tabular)),
          trailing: ConfidenceBar(e.confidence),
          onTap: () => onSelect(e.id),
        ),
      if (elements.length > 300) Text('… y ${elements.length - 300} más'),
      const SizedBox(height: Gap.md),
      const PendingFeature(
        title: 'Corrección manual',
        detail: 'Editar, agregar o eliminar elementos y guardarlos como "corregido por el usuario" (la procedencia ya está modelada).',
      ),
    ]);
  }

  Widget _toggle(String label, String key, bool value, bool enabled) => SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: value && enabled,
        onChanged: enabled ? (v) => onToggle(key, v) : null,
      );
}

/// Dibuja los elementos del Building Model sobre el plano (coordenadas en px del plano).
class VectorPainter extends CustomPainter {
  final BuildingModel model;
  final String? selected;
  final double px; // grosor de 1 px de pantalla en px del plano
  VectorPainter(this.model, this.selected, this.px);

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in model.allElements) {
      final color = StructuraColors.byClass[e.kind.name] ?? Colors.grey;
      final sel = e.id == selected;
      final stroke = Paint()
        ..color = sel ? Colors.white : color
        ..style = PaintingStyle.stroke
        ..strokeWidth = (sel ? 3 : 1.5) * px;
      final fill = Paint()..color = color.withValues(alpha: sel ? 0.45 : 0.18);
      if (e is Wall) {
        final b = e.bounds;
        final r = Rect.fromLTRB(b.left, b.top, b.right, b.bottom);
        canvas.drawRect(r, fill);
        canvas.drawRect(r, stroke);
        canvas.drawLine(Offset(e.start.x, e.start.y), Offset(e.end.x, e.end.y), Paint()
          ..color = (sel ? Colors.white : color).withValues(alpha: 0.9)
          ..strokeWidth = px);
      } else {
        final b = e.bounds;
        final r = Rect.fromLTRB(b.left, b.top, b.right, b.bottom);
        canvas.drawRect(r, fill);
        canvas.drawRect(r, stroke);
      }
    }
  }

  @override
  bool shouldRepaint(VectorPainter old) => old.model != model || old.selected != selected || old.px != px;
}
