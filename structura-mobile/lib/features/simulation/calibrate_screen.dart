import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:structura_model/structura_model.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../widgets/common.dart';
import 'simulation_screen.dart';

/// Calibración de escala con dos puntos: el profesional toca los extremos de una cota
/// conocida del plano e ingresa su valor real. Es el método de las apps de medición/CAD
/// y no depende de que la detección haya separado bien los muros.
class CalibrateScreen extends ConsumerStatefulWidget {
  final String projectId;
  const CalibrateScreen({super.key, required this.projectId});
  @override
  ConsumerState<CalibrateScreen> createState() => _CalibrateScreenState();
}

class _CalibrateScreenState extends ConsumerState<CalibrateScreen> {
  final _tc = TransformationController();
  final _meters = TextEditingController();
  final List<Point2> _pts = [];
  Size? _viewport;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _tc.dispose();
    _meters.dispose();
    super.dispose();
  }

  void _fit(int w, int h) {
    final vp = _viewport;
    if (vp == null) return;
    final s = (vp.width / w).clamp(0.0, vp.height / h) * 0.96;
    _tc.value = Matrix4.identity()
      ..translateByDouble((vp.width - w * s) / 2, (vp.height - h * s) / 2, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  Future<void> _save() async {
    final m = double.tryParse(_meters.text.replaceAll(',', '.'));
    if (_pts.length != 2 || m == null) {
      setState(() => _error = 'Marcá los dos extremos de la cota e ingresá su valor en metros.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await ref.read(projectStoreProvider).load(widget.projectId);
      await ref.read(screeningServiceProvider).calibrateWithPoints(p, _pts[0], _pts[1], m);
      ref.invalidate(simModelProvider(widget.projectId));
      if (mounted) context.pop(true);
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(projectProvider(widget.projectId));
    final store = ref.watch(projectStoreProvider);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Calibrar escala')),
      body: project.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(icon: Icons.error_outline, title: 'Error', message: '$e'),
        data: (p) {
          final plan = p.activePlan!;
          final scale = _tc.value.getMaxScaleOnAxis();
          final px = _pts.length == 2 ? _pts[0].distanceTo(_pts[1]) : null;
          return Column(children: [
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                final first = _viewport == null;
                _viewport = c.biggest;
                if (first) WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => _fit(plan.width, plan.height)));
                return ClipRect(
                  child: BlueprintGrid(
                    child: InteractiveViewer(
                      key: const Key('calibrate_viewer'),
                      transformationController: _tc,
                      constrained: false,
                      minScale: 0.05,
                      maxScale: 20,
                      boundaryMargin: const EdgeInsets.all(1500),
                      onInteractionUpdate: (_) => setState(() {}),
                      child: GestureDetector(
                        onTapUp: (d) => setState(() {
                          if (_pts.length == 2) _pts.clear();
                          _pts.add(Point2(d.localPosition.dx, d.localPosition.dy));
                        }),
                        child: SizedBox(
                          width: plan.width.toDouble(),
                          height: plan.height.toDouble(),
                          child: Stack(children: [
                            Positioned.fill(child: Image.file(File(store.resolve(p.id, plan.rasterFile).path), fit: BoxFit.fill)),
                            Positioned.fill(child: CustomPaint(painter: _MeasurePainter(_pts, 1 / scale))),
                          ]),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(
                    _pts.isEmpty
                        ? '1. Tocá un extremo de una cota conocida (podés hacer zoom).'
                        : _pts.length == 1
                            ? '2. Tocá el otro extremo de la cota.'
                            : '3. Ingresá el valor de la cota. Distancia marcada: ${px!.toStringAsFixed(0)} px.',
                    style: t.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: Gap.md),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        key: const Key('calibrate_meters'),
                        controller: _meters,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Valor real (m)', hintText: 'Ej.: 4,50'),
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    IconButton.outlined(
                        tooltip: 'Borrar puntos', onPressed: () => setState(_pts.clear), icon: const Icon(Icons.restart_alt)),
                  ]),
                  if (_error != null) ...[const SizedBox(height: Gap.sm), NoticeBanner(_error!, color: StructuraColors.danger)],
                  const SizedBox(height: Gap.md),
                  FilledButton.icon(
                    key: const Key('calibrate_save'),
                    onPressed: _busy || _pts.length != 2 ? null : _save,
                    icon: const Icon(Icons.straighten_rounded),
                    label: const Text('Guardar escala verificada'),
                  ),
                ]),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class _MeasurePainter extends CustomPainter {
  final List<Point2> pts;
  final double px; // 1 px de pantalla en px del plano
  _MeasurePainter(this.pts, this.px);
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = StructuraColors.accent
      ..strokeWidth = 2.5 * px;
    if (pts.length == 2) canvas.drawLine(Offset(pts[0].x, pts[0].y), Offset(pts[1].x, pts[1].y), line);
    for (final p in pts) {
      final o = Offset(p.x, p.y);
      canvas.drawCircle(o, 10 * px, Paint()..color = StructuraColors.accent.withValues(alpha: 0.3));
      canvas.drawLine(o.translate(-14 * px, 0), o.translate(14 * px, 0), line);
      canvas.drawLine(o.translate(0, -14 * px), o.translate(0, 14 * px), line);
    }
  }

  @override
  bool shouldRepaint(_MeasurePainter o) => o.pts.length != pts.length || o.px != px || (pts.isNotEmpty && o.pts.last != pts.last);
}
