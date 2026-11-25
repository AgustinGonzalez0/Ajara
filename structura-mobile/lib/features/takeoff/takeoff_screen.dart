/// Cómputo métrico preliminar: superficies, ambientes, mampostería, aberturas y
/// densidad de muros. Todo en una pantalla, con la planilla y el DXF a un toque.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:structura_geometry/structura_geometry.dart';
import 'package:structura_model/structura_model.dart';

import '../../app/flows.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../services/takeoff_service.dart';
import '../../widgets/common.dart';

String _f(num v, [int d = 2]) => v.toStringAsFixed(d).replaceAll('.', ',');

class TakeoffScreen extends ConsumerStatefulWidget {
  final String projectId;
  const TakeoffScreen({super.key, required this.projectId});
  @override
  ConsumerState<TakeoffScreen> createState() => _TakeoffScreenState();
}

class _TakeoffScreenState extends ConsumerState<TakeoffScreen> {
  QuantityTakeoff? _t;
  BuildingModel? _model;
  TakeoffParams? _params;
  String? _error;
  bool _sharing = false;
  bool _dxf = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([TakeoffParams? params]) async {
    try {
      final p = await ref.read(projectStoreProvider).load(widget.projectId);
      final svc = ref.read(takeoffServiceProvider);
      final (t, m) = await svc.compute(p, params: params);
      if (!mounted) return;
      setState(() {
        _t = t;
        _model = m;
        _params = t.params;
        _error = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _height(double delta) {
    final p = _params ?? const TakeoffParams();
    final h = ((p.wallHeightM + delta).clamp(2.2, 4.5) * 100).round() / 100;
    _load(TakeoffParams(wallHeightM: h, doorHeightM: p.doorHeightM, windowHeightM: p.windowHeightM));
  }

  Future<void> _shareCsv() async {
    final t = _t;
    if (t == null) return;
    setState(() => _sharing = true);
    try {
      final p = await ref.read(projectStoreProvider).load(widget.projectId);
      final path = await ref.read(takeoffServiceProvider).exportCsv(p, t);
      await ref.read(fileSharerProvider).shareFile(path,
          mimeType: mimeCsv,
          subject: 'Cómputo métrico — ${p.name}',
          text: 'Cómputo métrico preliminar generado con STRUCTURA AI desde el plano detectado.');
    } on Object catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo compartir: $e')));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _shareDxf() async {
    setState(() => _dxf = true);
    try {
      await exportAndShareDxf(ref, widget.projectId);
    } on Object catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo exportar el DXF: $e')));
    } finally {
      if (mounted) setState(() => _dxf = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final model = _model;
    return Scaffold(
      appBar: AppBar(title: const Text('Cómputo métrico')),
      bottomNavigationBar: t == null
          ? null
          : ActionBar(children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('takeoff_csv'),
                  onPressed: _sharing ? null : _shareCsv,
                  icon: _sharing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.table_chart_outlined),
                  label: const Text('Compartir planilla'),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('takeoff_dxf'),
                onPressed: _dxf ? null : _shareDxf,
                icon: const Icon(Icons.architecture_rounded),
                label: const Text('DXF'),
              ),
            ]),
      body: _error != null
          ? EmptyState(icon: Icons.square_foot_rounded, title: 'No se pudo calcular', message: _error!)
          : t == null || model == null
              ? const Center(child: CircularProgressIndicator())
              : _Body(t: t, model: model, onHeight: _height),
    );
  }
}

class _Body extends StatelessWidget {
  final QuantityTakeoff t;
  final BuildingModel model;
  final ValueChanged<double> onHeight;
  const _Body({required this.t, required this.model, required this.onHeight});

  @override
  Widget build(BuildContext context) {
    final th = Theme.of(context);
    final muted = th.textTheme.bodySmall?.copyWith(color: th.colorScheme.onSurfaceVariant);
    final doors = t.openings.where((o) => o.type == OpeningType.door);
    final windows = t.openings.where((o) => o.type == OpeningType.window);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
      children: [
        Row(children: [
          Expanded(child: _Metric(key: const Key('takeoff_covered'), label: 'Cubierta', value: '${_f(t.coveredAreaM2, 1)} m²')),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: _Metric(
                  label: 'Útil', value: t.rooms.isEmpty ? '—' : '${_f(t.usefulAreaM2, 1)} m²', color: StructuraColors.teal)),
          const SizedBox(width: Gap.sm),
          Expanded(child: _Metric(label: 'Ambientes', value: '${t.rooms.length}', color: StructuraColors.success)),
        ]),
        const SizedBox(height: Gap.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 230,
            decoration: BoxDecoration(
              color: th.colorScheme.surfaceContainer,
              border: Border.all(color: th.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(14),
            ),
            child: CustomPaint(
              key: const Key('takeoff_plan'),
              painter: _RoomsPainter(model, t, th.colorScheme.onSurface, th.colorScheme.surface),
              size: Size.infinite,
            ),
          ),
        ),
        if (!t.contourClosed)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: NoticeBanner(
              'El contorno no cierra: hay un muro abierto. Se usa el rectángulo envolvente y no se separan '
              'ambientes. Corregilo en "Plano" para obtener superficies por ambiente.',
            ),
          ),
        const SizedBox(height: Gap.md),
        _HeightStepper(value: t.params.wallHeightM, onMinus: () => onHeight(-0.05), onPlus: () => onHeight(0.05)),
        SectionLabel('Mampostería', trailing: Text('${_f(t.wallLengthM, 1)} m de muro', style: muted)),
        for (final w in t.walls)
          _Line(
            title: 'Muro ${_f(w.thicknessM * 100, 0)} cm',
            detail: '${_f(w.lengthM)} m · ${_f(w.netAreaM2)} m² netos'
                '${w.openingsAreaM2 > 0 ? ' (−${_f(w.openingsAreaM2)} m² aberturas)' : ''}',
            value: '${_f(w.volumeM3)} m³',
          ),
        _Line(title: 'Revoque (2 caras)', detail: 'grueso y fino', value: '${_f(t.plasterAreaM2, 1)} m²'),
        if (t.rooms.isNotEmpty)
          _Line(title: 'Contrapiso y piso', detail: 'superficie útil', value: '${_f(t.usefulAreaM2, 1)} m²'),
        SectionLabel('Aberturas y estructura'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final o in doors) _Chip('${o.count} × puerta ${_f(o.widthM)} m', StructuraColors.door),
          for (final o in windows) _Chip('${o.count} × ventana ${_f(o.widthM)} m', StructuraColors.window),
          if (t.columns > 0) _Chip(StructuraColors.count('column', t.columns), StructuraColors.column),
          if (t.stairs > 0) _Chip(StructuraColors.count('stairs', t.stairs), StructuraColors.stairs),
          if (t.openings.isEmpty && t.columns == 0 && t.stairs == 0) Text('Sin aberturas detectadas', style: muted),
        ]),
        if (t.rooms.isNotEmpty) ...[
          SectionLabel('Ambientes'),
          Wrap(
            key: const Key('takeoff_rooms'),
            spacing: 6,
            runSpacing: 6,
            children: [for (final r in t.rooms) _Chip('${r.name}  ${_f(r.areaM2)} m²', StructuraColors.teal)],
          ),
        ],
        SectionLabel('Densidad de muros'),
        Row(children: [
          Expanded(child: _Metric(label: 'Dirección X (horizontal)', value: '${_f(t.wallDensityXPct)} %')),
          const SizedBox(width: Gap.sm),
          Expanded(child: _Metric(label: 'Dirección Y (vertical)', value: '${_f(t.wallDensityYPct)} %')),
        ]),
        const SizedBox(height: 6),
        Text(
          'Área de muros en planta por dirección sobre la superficie cubierta. En mampostería es un indicador rápido '
          'de rigidez ante sismo: una dirección con mucho menos muro que la otra conviene revisarla.',
          style: muted,
        ),
        const SizedBox(height: Gap.lg),
        for (final n in t.notes)
          Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('• $n', style: muted)),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _Metric({super.key, required this.label, required this.value, this.color});
  @override
  Widget build(BuildContext context) {
    final th = Theme.of(context);
    final c = color ?? StructuraColors.accent;
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: th.textTheme.labelSmall?.copyWith(color: th.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: th.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontFeatures: tabular)),
        ),
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  final String title;
  final String detail;
  final String value;
  const _Line({required this.title, required this.detail, required this.value});
  @override
  Widget build(BuildContext context) {
    final th = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: th.textTheme.titleSmall),
            Text(detail, style: th.textTheme.bodySmall?.copyWith(color: th.colorScheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: Gap.sm),
        Text(value, style: th.textTheme.titleMedium?.copyWith(fontFeatures: tabular)),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;
  const _Chip(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontFeatures: tabular)),
      );
}

class _HeightStepper extends StatelessWidget {
  final double value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _HeightStepper({required this.value, required this.onMinus, required this.onPlus});
  @override
  Widget build(BuildContext context) {
    final th = Theme.of(context);
    return Container(
      key: const Key('takeoff_height'),
      padding: const EdgeInsets.fromLTRB(Gap.md, 6, 4, 6),
      decoration: BoxDecoration(
        color: th.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: th.colorScheme.outlineVariant),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Altura de muros (declarada)',
                style: th.textTheme.labelSmall?.copyWith(color: th.colorScheme.onSurfaceVariant)),
            Text('${_f(value)} m', style: th.textTheme.titleMedium?.copyWith(fontFeatures: tabular)),
          ]),
        ),
        IconButton(key: const Key('takeoff_height_minus'), onPressed: onMinus, icon: const Icon(Icons.remove_rounded)),
        IconButton(key: const Key('takeoff_height_plus'), onPressed: onPlus, icon: const Icon(Icons.add_rounded)),
      ]),
    );
  }
}

/// Planta con piso, muros, aberturas y el rótulo de cada ambiente.
class _RoomsPainter extends CustomPainter {
  final BuildingModel model;
  final QuantityTakeoff t;
  final Color ink;
  final Color paper;
  _RoomsPainter(this.model, this.t, this.ink, this.paper);

  @override
  void paint(Canvas canvas, Size size) {
    final els = model.allElements.toList();
    if (els.isEmpty) return;
    var l = double.infinity, tp = double.infinity, r = -double.infinity, b = -double.infinity;
    for (final e in els) {
      final bb = e.bounds;
      l = math.min(l, bb.left);
      tp = math.min(tp, bb.top);
      r = math.max(r, bb.right);
      b = math.max(b, bb.bottom);
    }
    const pad = 14.0;
    final s = math.min((size.width - 2 * pad) / math.max(1, r - l), (size.height - 2 * pad) / math.max(1, b - tp));
    final ox = (size.width - (r - l) * s) / 2, oy = (size.height - (b - tp) * s) / 2;
    Offset o(double x, double y) => Offset(ox + (x - l) * s, oy + (y - tp) * s);
    Rect rect(Rect2 q) => Rect.fromPoints(o(q.left, q.top), o(q.right, q.bottom));

    final floor = Paint()..color = StructuraColors.teal.withValues(alpha: 0.10);
    for (final q in analyzeFloor(model).floor) {
      canvas.drawRect(rect(q), floor);
    }
    final wallPaint = Paint()..color = ink.withValues(alpha: 0.85);
    for (final w in els.whereType<Wall>()) {
      final dx = w.end.x - w.start.x, dy = w.end.y - w.start.y;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len == 0) continue;
      final nx = -dy / len * w.thicknessPx / 2, ny = dx / len * w.thicknessPx / 2;
      canvas.drawPath(
        Path()
          ..moveTo(o(w.start.x + nx, w.start.y + ny).dx, o(w.start.x + nx, w.start.y + ny).dy)
          ..lineTo(o(w.end.x + nx, w.end.y + ny).dx, o(w.end.x + nx, w.end.y + ny).dy)
          ..lineTo(o(w.end.x - nx, w.end.y - ny).dx, o(w.end.x - nx, w.end.y - ny).dy)
          ..lineTo(o(w.start.x - nx, w.start.y - ny).dx, o(w.start.x - nx, w.start.y - ny).dy)
          ..close(),
        wallPaint,
      );
    }
    for (final op in els.whereType<Opening>()) {
      canvas.drawRect(
          rect(op.footprint), Paint()..color = op.type == OpeningType.door ? StructuraColors.door : StructuraColors.window);
    }
    for (final c in els.whereType<ColumnElement>()) {
      canvas.drawRect(rect(c.footprint), Paint()..color = StructuraColors.column);
    }
    final stair = Paint()
      ..color = StructuraColors.stairs
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final st in els.whereType<Stairs>()) {
      final q = rect(st.footprint);
      canvas.drawRect(q, stair);
      final horizontal = q.width >= q.height;
      for (var i = 1; i < 8; i++) {
        final f = i / 8;
        if (horizontal) {
          canvas.drawLine(Offset(q.left + q.width * f, q.top), Offset(q.left + q.width * f, q.bottom), stair);
        } else {
          canvas.drawLine(Offset(q.left, q.top + q.height * f), Offset(q.right, q.top + q.height * f), stair);
        }
      }
    }
    for (final room in t.rooms) {
      final tp2 = TextPainter(
        text: TextSpan(children: [
          TextSpan(text: '${room.name}\n', style: TextStyle(color: ink, fontSize: 11, fontWeight: FontWeight.w700)),
          TextSpan(text: '${_f(room.areaM2, 1)} m²', style: TextStyle(color: ink, fontSize: 10)),
        ]),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();
      final c = o(room.labelPx.x, room.labelPx.y);
      final box = Rect.fromCenter(center: c, width: tp2.width + 10, height: tp2.height + 6);
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(6)), Paint()..color = paper.withValues(alpha: 0.88));
      tp2.paint(canvas, Offset(c.dx - tp2.width / 2, c.dy - tp2.height / 2));
    }
  }

  @override
  bool shouldRepaint(_RoomsPainter old) => old.t != t || old.model != model || old.ink != ink;
}
