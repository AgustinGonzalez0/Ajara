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
import '../../services/correction_service.dart';
import '../model3d/model_screen.dart' show model3dProvider;
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
  bool _saving = false;

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

  /// Elemento bajo el dedo: el de menor área que contiene el punto (una abertura gana
  /// al muro que la contiene). Tolerancia de unos 10 px de pantalla.
  void _selectAt(Offset o, BuildingModel? model) {
    if (model == null) return;
    final tol = 10 / _scale;
    BuildingElement? best;
    var bestArea = double.infinity;
    for (final e in model.allElements) {
      final b = e.bounds;
      if (o.dx >= b.left - tol && o.dx <= b.right + tol && o.dy >= b.top - tol && o.dy <= b.bottom + tol) {
        final area = b.width * b.height;
        if (area < bestArea) {
          best = e;
          bestArea = area;
        }
      }
    }
    setState(() => _selected = best?.id == _selected ? null : best?.id);
  }

  Future<void> _correct(Correction c, String done) async {
    setState(() => _saving = true);
    try {
      final svc = ref.read(correctionServiceProvider);
      final p = await ref.read(projectStoreProvider).load(widget.projectId);
      final previous = await svc.load(p);
      await svc.apply(p, c);
      _refresh();
      if (!mounted) return;
      setState(() => _selected = c is DeleteElement ? null : _selected);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(done),
        action: SnackBarAction(
          label: 'Deshacer',
          onPressed: () async {
            final fresh = await ref.read(projectStoreProvider).load(widget.projectId);
            await svc.save(fresh, previous);
            _refresh();
          },
        ),
      ));
    } on Object catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo corregir: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _refresh() {
    ref.invalidate(editorDataProvider(widget.projectId));
    refreshProject(ref, widget.projectId);
    ref.invalidate(model3dProvider(widget.projectId));
    ref.invalidate(simModelProvider(widget.projectId));
    ref.invalidate(lastReportProvider(widget.projectId));
  }

  void _showList(EditorData d) => showModalBottomSheet(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (c) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          builder: (c, scroll) => _LayerPanel(
            data: d,
            controller: scroll,
            showLayers: false,
            showPlan: _showPlan,
            showSeg: _showSeg,
            showVectors: _showVectors,
            selected: _selected,
            onToggle: (_, _) {},
            onSelect: (id) {
              setState(() => _selected = id);
              Navigator.pop(c);
            },
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(editorDataProvider(widget.projectId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plano y detecciones'),
        actions: [
          if (async.value?.model != null)
            IconButton(
                key: const Key('elements_list'),
                tooltip: 'Lista de elementos',
                onPressed: () => _showList(async.value!),
                icon: const Icon(Icons.list_alt_rounded)),
        ],
      ),
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(icon: Icons.layers_clear_outlined, title: 'No se puede abrir el editor', message: '$e'),
        data: (d) => _body(context, d),
      ),
    );
  }

  Widget _body(BuildContext context, EditorData d) {
    final plan = d.project.activePlan!;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final selected = _selected == null ? null : d.model?.elementById(_selected!);
    final layers = GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _chip('Plano', _showPlan, true, (v) => setState(() => _showPlan = v)),
          _chip('Segmentación', _showSeg, d.segmentation != null, (v) => setState(() => _showSeg = v)),
          _chip('Vectores', _showVectors, d.model != null, (v) => setState(() => _showVectors = v)),
        ]),
      ),
    );
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
              child: GestureDetector(
                onTapUp: (t) => _selectAt(t.localPosition, d.model),
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
            ),
            Positioned(left: Gap.md, top: Gap.md, right: Gap.md, child: Align(alignment: Alignment.centerLeft, child: layers)),
            Positioned(
              left: Gap.md,
              right: Gap.md,
              bottom: Gap.md,
              child: SafeArea(
                top: false,
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: _ZoomBar(scale: _scale, onFit: () => _fit(plan.width, plan.height)),
                  ),
                  const SizedBox(height: Gap.sm),
                  if (selected != null)
                    _SelectionCard(
                      element: selected,
                      scale: d.model?.scale,
                      busy: _saving,
                      onClose: () => setState(() => _selected = null),
                      onDelete: () => _correct(DeleteElement(selected.id),
                          '${_cap(StructuraColors.classSingular[selected.kind.name] ?? 'elemento')} eliminado. La evaluación anterior se descartó.'),
                      onRetype: selected is Opening
                          ? () => _correct(
                              ChangeOpeningType(selected.id, selected.type == OpeningType.door ? OpeningType.window : OpeningType.door),
                              selected.type == OpeningType.door ? 'Ahora es una ventana.' : 'Ahora es una puerta.')
                          : null,
                    )
                  else if (d.model != null && !wide)
                    GlassPanel(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
                      child: Row(children: [
                        const Icon(Icons.touch_app_outlined, size: 18),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Text('${d.model!.allElements.length} elementos · tocá uno para revisarlo o corregirlo',
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                      ]),
                    ),
                ]),
              ),
            ),
          ]),
        ),
      );
    });
    if (wide) {
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
      return Row(children: [Expanded(child: canvas), SizedBox(width: 340, child: panel)]);
    }
    return canvas;
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _chip(String label, bool value, bool enabled, ValueChanged<bool> onChanged) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: FilterChip(
          label: Text(label),
          selected: value && enabled,
          visualDensity: VisualDensity.compact,
          onSelected: enabled ? onChanged : null,
        ),
      );
}

class _SelectionCard extends StatelessWidget {
  final BuildingElement element;
  final bool busy;
  final VoidCallback onClose;
  final VoidCallback onDelete;
  final VoidCallback? onRetype;

  /// Escala verificada (null = medidas en píxeles del plano).
  final PlanScale? scale;
  const _SelectionCard(
      {required this.element, required this.busy, required this.onClose, required this.onDelete, this.onRetype, this.scale});

  String _len(double px) {
    final m = scale?.pxToMeters(px);
    return m == null ? '${px.toStringAsFixed(0)} px' : '${m.toStringAsFixed(2).replaceAll('.', ',')} m';
  }

  String get _measures {
    final e = element;
    if (e is Wall) return 'Largo ${_len(e.lengthPx)} · espesor ${_len(e.thicknessPx)}';
    final b = e.bounds;
    return '${_len(b.width)} × ${_len(b.height)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final e = element;
    final kind = e.kind.name;
    final origin = switch (e.source.provenance) {
      Provenance.classicDetected => 'Detectado sin IA',
      Provenance.aiDetected => 'Detectado por IA',
      Provenance.userCorrected => 'Corregido por vos',
      Provenance.userCreated => 'Creado por vos',
      _ => 'Origen: ${e.source.provenance.name}',
    };
    final name = StructuraColors.classSingular[kind] ?? kind;
    return GlassPanel(
      key: const Key('selection_card'),
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: StructuraColors.byClass[kind] ?? Colors.grey, shape: BoxShape.circle)),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${name[0].toUpperCase()}${name.substring(1)} · ${e.id}', style: t.textTheme.titleSmall),
              Text('$origin · $_measures',
                  key: const Key('selection_measures'),
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant, fontFeatures: tabular)),
            ]),
          ),
          if (e.confidence != null) ConfidenceBar(e.confidence),
          IconButton(visualDensity: VisualDensity.compact, tooltip: 'Cerrar', onPressed: onClose, icon: const Icon(Icons.close_rounded)),
        ]),
        const SizedBox(height: Gap.xs),
        Row(children: [
          if (onRetype != null) ...[
            Expanded(
              child: FilledButton.tonalIcon(
                key: const Key('retype_element'),
                onPressed: busy ? null : onRetype,
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: Text(e is Opening && e.type == OpeningType.door ? 'Es ventana' : 'Es puerta'),
              ),
            ),
            const SizedBox(width: Gap.sm),
          ],
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('delete_element'),
              style: OutlinedButton.styleFrom(foregroundColor: StructuraColors.danger),
              onPressed: busy ? null : onDelete,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Eliminar'),
            ),
          ),
          const SizedBox(width: Gap.sm),
        ]),
      ]),
    );
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
  final ScrollController? controller;
  final bool showLayers;
  final bool showPlan, showSeg, showVectors;
  final String? selected;
  final void Function(String, bool) onToggle;
  final void Function(String) onSelect;
  const _LayerPanel({
    required this.data,
    this.controller,
    this.showLayers = true,
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
    return ListView(controller: controller, padding: const EdgeInsets.all(Gap.lg), children: [
      if (showLayers) ...[
        const SectionLabel('Capas'),
        _toggle('Plano', 'plan', showPlan, true),
        _toggle('Segmentación (capa)', 'seg', showSeg, data.segmentation != null),
        _toggle('Vectores (Building Model)', 'vec', showVectors, data.model != null),
      ],
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
      Text('Tocá un elemento en el plano para eliminarlo o cambiar puerta ↔ ventana. Cada cambio queda registrado '
          'como "corregido por el usuario" y regenera el modelo 3D.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
