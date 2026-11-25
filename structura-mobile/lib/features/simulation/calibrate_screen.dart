import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:structura_model/structura_model.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../widgets/common.dart';

/// Calibración de escala con dos puntos: el profesional toca los extremos de una cota
/// conocida del plano e ingresa su valor real. Los extremos se pueden arrastrar con lupa,
/// y antes de guardar se muestra qué medidas resultan (espesor de muros, tamaño de la
/// planta) para detectar un error de tipeo o de cota al instante.
class CalibrateScreen extends ConsumerStatefulWidget {
  final String projectId;

  /// Al guardar, sigue directo a la evaluación (sin volver atrás).
  final bool thenSimulate;

  /// Después de guardar la escala abre el cómputo métrico.
  final bool thenTakeoff;
  const CalibrateScreen({super.key, required this.projectId, this.thenSimulate = false, this.thenTakeoff = false});
  @override
  ConsumerState<CalibrateScreen> createState() => _CalibrateScreenState();
}

class _CalibrateScreenState extends ConsumerState<CalibrateScreen> {
  final _tc = TransformationController();
  final _meters = TextEditingController();
  final _metersFocus = FocusNode();
  final List<Point2> _pts = [];
  Size? _viewport;
  String? _error;
  bool _busy = false;
  int? _drag;
  Offset? _finger;

  @override
  void initState() {
    super.initState();
    _meters.addListener(() => setState(() {}));
    _tc.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tc.dispose();
    _meters.dispose();
    _metersFocus.dispose();
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

  double? get _metersValue {
    final v = double.tryParse(_meters.text.trim().replaceAll(',', '.'));
    return v != null && v > 0 ? v : null;
  }

  void _addPoint(Point2 p) {
    setState(() {
      if (_pts.length == 2) _pts.clear();
      _pts.add(p);
    });
    // El campo se habilita en el próximo frame: recién ahí puede tomar el foco.
    if (_pts.length == 2) WidgetsBinding.instance.addPostFrameCallback((_) => _metersFocus.requestFocus());
  }

  Future<void> _save() async {
    final m = _metersValue;
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
      ref.invalidate(lastReportProvider(widget.projectId));
      if (!mounted) return;
      if (widget.thenSimulate) {
        context.pushReplacement(Routes.simulate(widget.projectId));
      } else if (widget.thenTakeoff) {
        context.pushReplacement(Routes.takeoff(widget.projectId));
      } else {
        context.pop(true);
      }
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Qué medidas resultan con la escala propuesta: ayuda a detectar errores.
  String? _sanity(BuildingModel? model) {
    final m = _metersValue;
    if (model == null || m == null || _pts.length != 2) return null;
    final pxPerM = _pts[0].distanceTo(_pts[1]) / m;
    if (pxPerM <= 0) return null;
    final walls = model.allElements.whereType<Wall>().toList();
    if (walls.isEmpty) return null;
    final t = walls.map((w) => w.thicknessPx).toList()..sort();
    final thicknessCm = t[t.length ~/ 2] / pxPerM * 100;
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final w in walls) {
      final b = w.bounds;
      minX = math.min(minX, b.left);
      minY = math.min(minY, b.top);
      maxX = math.max(maxX, b.right);
      maxY = math.max(maxY, b.bottom);
    }
    String f(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
    return 'Con esta escala: muros ≈ ${thicknessCm.toStringAsFixed(0)} cm · planta ≈ ${f((maxX - minX) / pxPerM)} × ${f((maxY - minY) / pxPerM)} m';
  }

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(projectProvider(widget.projectId));
    final model = ref.watch(simModelProvider(widget.projectId)).value;
    final store = ref.watch(projectStoreProvider);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Escala del plano')),
      body: project.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(icon: Icons.error_outline, title: 'Error', message: '$e'),
        data: (p) {
          final plan = p.activePlan!;
          final scale = _tc.value.getMaxScaleOnAxis();
          Offset toScreen(Point2 q) => MatrixUtils.transformPoint(_tc.value, Offset(q.x, q.y));
          final sanity = _sanity(model);
          final hint = switch (_pts.length) {
            0 => 'Tocá un extremo de una cota que conozcas. Podés hacer zoom con dos dedos.',
            1 => 'Ahora tocá el otro extremo.',
            _ => 'Escribí el valor de la cota. Podés arrastrar los extremos para afinar.',
          };
          return Column(children: [
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                final first = _viewport == null;
                _viewport = c.biggest;
                if (first) WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => _fit(plan.width, plan.height)));
                return ClipRect(
                  child: Stack(children: [
                    Positioned.fill(
                      child: BlueprintGrid(
                        child: InteractiveViewer(
                          key: const Key('calibrate_viewer'),
                          transformationController: _tc,
                          constrained: false,
                          minScale: 0.05,
                          maxScale: 20,
                          boundaryMargin: const EdgeInsets.all(1500),
                          child: GestureDetector(
                            onTapUp: (d) => _addPoint(Point2(d.localPosition.dx, d.localPosition.dy)),
                            child: SizedBox(
                              width: plan.width.toDouble(),
                              height: plan.height.toDouble(),
                              child: Stack(children: [
                                Positioned.fill(
                                    child: Image.file(File(store.resolve(p.id, plan.rasterFile).path), fit: BoxFit.fill)),
                                Positioned.fill(child: CustomPaint(painter: _MeasurePainter(_pts, 1 / scale))),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Manijas arrastrables (encima del visor: el arrastre no mueve el plano).
                    for (var i = 0; i < _pts.length; i++)
                      Positioned(
                        left: toScreen(_pts[i]).dx - 24,
                        top: toScreen(_pts[i]).dy - 24,
                        child: GestureDetector(
                          key: Key('calibrate_handle_$i'),
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (d) => setState(() {
                            _drag = i;
                            _finger = toScreen(_pts[i]);
                          }),
                          onPanUpdate: (d) => setState(() {
                            final q = _pts[i];
                            _pts[i] = Point2(q.x + d.delta.dx / scale, q.y + d.delta.dy / scale);
                            _finger = toScreen(_pts[i]);
                          }),
                          onPanEnd: (_) => setState(() {
                            _drag = null;
                            _finger = null;
                          }),
                          child: const SizedBox(width: 48, height: 48),
                        ),
                      ),
                    if (_drag != null && _finger != null)
                      Positioned(
                        left: _finger!.dx - 60,
                        top: _finger!.dy - 60 - 96,
                        child: const IgnorePointer(
                          child: RawMagnifier(
                            size: Size(120, 120),
                            magnificationScale: 2.5,
                            focalPointOffset: Offset(0, 96),
                            decoration: MagnifierDecoration(
                              shape: CircleBorder(side: BorderSide(color: StructuraColors.accent, width: 2)),
                              shadows: [BoxShadow(color: Color(0x55000000), blurRadius: 10)],
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      left: Gap.md,
                      right: Gap.md,
                      top: Gap.md,
                      child: GlassPanel(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
                        child: Row(children: [
                          CircleAvatar(
                            radius: 11,
                            backgroundColor: StructuraColors.accent,
                            child: Text('${math.min(_pts.length + 1, 3)}',
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(width: Gap.sm),
                          Expanded(child: Text(hint, key: const Key('calibrate_hint'), style: t.textTheme.bodyMedium)),
                        ]),
                      ),
                    ),
                  ]),
                );
              }),
            ),
            Container(
              decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerLow,
                border: Border(top: BorderSide(color: t.colorScheme.outlineVariant)),
              ),
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.all(Gap.lg),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(
                      child: TextField(
                        key: const Key('calibrate_meters'),
                        controller: _meters,
                        focusNode: _metersFocus,
                        enabled: _pts.length == 2,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _save(),
                        decoration: InputDecoration(
                          labelText: 'Valor de la cota',
                          hintText: 'Ej.: 4,50',
                          suffixText: 'm',
                          helperText: _pts.length == 2
                              ? 'Distancia marcada: ${_pts[0].distanceTo(_pts[1]).toStringAsFixed(0)} px'
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    IconButton.outlined(
                        tooltip: 'Borrar puntos', onPressed: () => setState(_pts.clear), icon: const Icon(Icons.restart_alt)),
                  ]),
                  if (sanity != null) ...[
                    const SizedBox(height: Gap.sm),
                    Row(children: [
                      const Icon(Icons.fact_check_outlined, size: 16, color: StructuraColors.teal),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Text(sanity,
                              key: const Key('calibrate_sanity'),
                              style: t.textTheme.bodySmall?.copyWith(color: StructuraColors.teal, fontFeatures: tabular))),
                    ]),
                  ],
                  if (_error != null) ...[const SizedBox(height: Gap.sm), NoticeBanner(_error!, color: StructuraColors.danger)],
                  const SizedBox(height: Gap.md),
                  FilledButton.icon(
                    key: const Key('calibrate_save'),
                    onPressed: _busy || _pts.length != 2 || _metersValue == null ? null : _save,
                    icon: const Icon(Icons.check_rounded),
                    label: Text(widget.thenSimulate || widget.thenTakeoff ? 'Guardar escala y seguir' : 'Guardar escala verificada'),
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
      canvas.drawCircle(o, 12 * px, Paint()..color = StructuraColors.accent.withValues(alpha: 0.25));
      canvas.drawLine(o.translate(-16 * px, 0), o.translate(16 * px, 0), line);
      canvas.drawLine(o.translate(0, -16 * px), o.translate(0, 16 * px), line);
    }
  }

  @override
  bool shouldRepaint(_MeasurePainter o) => true;
}
