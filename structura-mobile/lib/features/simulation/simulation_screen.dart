import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:structura_model/structura_model.dart';
import 'package:structura_sim/structura_sim.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../services/screening_service.dart';
import '../../widgets/common.dart';

final screeningServiceProvider = Provider<ScreeningService>((ref) => ScreeningService(ref.watch(projectStoreProvider)));

final simModelProvider = FutureProvider.autoDispose.family<BuildingModel, String>((ref, id) async {
  final p = await ref.watch(projectProvider(id).future);
  return ref.watch(screeningServiceProvider).loadModel(p);
});

final lastReportProvider = FutureProvider.autoDispose.family<Map<String, Object?>?, String>((ref, id) async {
  final p = await ref.watch(projectProvider(id).future);
  return ref.watch(screeningServiceProvider).lastReport(p);
});

Color statusColorOf(Status s) => switch (s) {
      Status.ok => StructuraColors.success,
      Status.attention => StructuraColors.warning,
      Status.critical => StructuraColors.danger,
      Status.notApplicable => StructuraColors.textMuted,
    };

String statusLabel(Status s) => switch (s) {
      Status.ok => 'DENTRO DE LO ESPERABLE',
      Status.attention => 'REVISAR',
      Status.critical => 'DEMANDA SUPERA CAPACIDAD ESTIMADA',
      Status.notApplicable => 'INFORMATIVO',
    };

const hazardLabels = {Hazard.seismic: 'Sismo / terremoto', Hazard.tsunami: 'Tsunami', Hazard.wind: 'Viento'};
const hazardIcons = {Hazard.seismic: Icons.vibration_rounded, Hazard.tsunami: Icons.waves_rounded, Hazard.wind: Icons.air_rounded};

class SimulationScreen extends ConsumerStatefulWidget {
  final String projectId;
  const SimulationScreen({super.key, required this.projectId});
  @override
  ConsumerState<SimulationScreen> createState() => _SimulationScreenState();
}

class _SimulationScreenState extends ConsumerState<SimulationScreen> {
  // Edificio
  int _floors = 1;
  double _story = 2.6;
  WallMaterial _material = WallMaterial.confinedMasonry;
  bool _declareThickness = false;
  double _thickness = 0.15;
  // Sismo
  double _pga = 0.3;
  SoilClass _soil = SoilClass.firm;
  // Tsunami
  bool _tsunami = true;
  double _depth = 2.0;
  FlowDirection _waterDir = FlowDirection.plusY;
  // Viento
  bool _wind = true;
  double _windSpeed = 35;
  FlowDirection _windDir = FlowDirection.plusX;

  ScreeningReport? _report;
  String? _error;
  bool _busy = false;

  Future<void> _evaluate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await ref.read(projectStoreProvider).load(widget.projectId);
      final r = await ref.read(screeningServiceProvider).evaluate(
            p,
            BuildingInput(
                floors: _floors,
                storyHeightM: _story,
                material: _material,
                wallThicknessM: _declareThickness ? _thickness : null),
            seismic: SeismicInput(pgaG: _pga, soil: _soil),
            tsunami: _tsunami ? TsunamiInput(inundationDepthM: _depth, direction: _waterDir) : null,
            wind: _wind ? WindInput(speedMs: _windSpeed, direction: _windDir) : null,
          );
      ref.invalidate(lastReportProvider(widget.projectId));
      setState(() => _report = r);
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = ref.watch(simModelProvider(widget.projectId));
    return Scaffold(
      appBar: AppBar(title: const Text('Evaluación preliminar')),
      body: SafeArea(
        child: model.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(icon: Icons.analytics_outlined, title: 'Evaluación no disponible', message: '$e'),
          data: (m) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: ListView(padding: const EdgeInsets.all(Gap.xl), children: [
                const NoticeBanner(screeningDisclaimer, color: StructuraColors.warning, icon: Icons.gpp_maybe_outlined),
                const SectionLabel('1 · Escala del plano'),
                _ScaleCard(projectId: widget.projectId, model: m),
                if (m.hasVerifiedScale) ...[
                  const SectionLabel('2 · Edificio'),
                  _buildingCard(context, m),
                  const SectionLabel('3 · Peligros'),
                  _hazardsCard(context),
                  const SizedBox(height: Gap.lg),
                  FilledButton.icon(
                    key: const Key('run_screening'),
                    onPressed: _busy ? null : _evaluate,
                    icon: const Icon(Icons.analytics_rounded),
                    label: Text(_busy ? 'Evaluando…' : 'Evaluar'),
                  ),
                  if (_error != null) ...[const SizedBox(height: Gap.md), NoticeBanner(_error!, color: StructuraColors.danger)],
                  if (_report != null) ...[
                    const SectionLabel('Resultados'),
                    for (final r in _report!.results) _HazardCard(result: r, projectId: widget.projectId),
                  ],
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _num(String label, double value, String unit, ValueChanged<double> onChanged, {double min = 0, double max = 100, int div = 100}) {
    final t = Theme.of(context);
    return Row(children: [
      Expanded(child: Text(label)),
      SizedBox(
        width: 160,
        child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: div, onChanged: onChanged),
      ),
      SizedBox(
          width: 70,
          child: Text('${fmt(value, value < 10 ? 2 : 0)} $unit',
              textAlign: TextAlign.end, style: t.textTheme.bodyMedium?.copyWith(fontFeatures: tabular))),
    ]);
  }

  /// Espesor mediano detectado (m) según la escala verificada.
  double? _detectedThickness(BuildingModel m) {
    final s = m.scale;
    if (s == null || !s.verified) return null;
    final t = m.allElements.whereType<Wall>().map((w) => w.thicknessPx).toList()..sort();
    if (t.isEmpty) return null;
    return s.pxToMeters(t[t.length ~/ 2]);
  }

  Widget _buildingCard(BuildContext context, BuildingModel model) => Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Pisos')),
              IconButton.outlined(onPressed: _floors > 1 ? () => setState(() => _floors--) : null, icon: const Icon(Icons.remove)),
              SizedBox(width: 40, child: Text('$_floors', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontFeatures: tabular))),
              IconButton.outlined(onPressed: _floors < 12 ? () => setState(() => _floors++) : null, icon: const Icon(Icons.add)),
            ]),
            _num('Altura de piso', _story, 'm', (v) => setState(() => _story = v), min: 2.2, max: 4.5, div: 23),
            const SizedBox(height: Gap.sm),
            DropdownButtonFormField<WallMaterial>(
              initialValue: _material,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Material de muros'),
              items: [for (final m in WallMaterial.values) DropdownMenuItem(value: m, child: Text(m.label, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _material = v ?? _material),
            ),
            const SizedBox(height: Gap.sm),
            Text('Valores indicativos: τ = ${_material.shearStrength} MPa · f = ${_material.flexuralStrength} MPa · '
                'γ = ${_material.unitWeight} kN/m³ · R = ${_material.responseFactor}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const Divider(height: Gap.xl),
            SwitchListTile(
              key: const Key('declare_thickness'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Declarar espesor real de muros'),
              subtitle: Text(_detectedThickness(model) == null
                  ? 'Espesor detectado no disponible'
                  : 'Detectado en el plano: ${fmt(_detectedThickness(model)! * 100, 1)} cm. '
                      'En fotos puede ser impreciso: conviene declararlo.'),
              value: _declareThickness,
              onChanged: (v) => setState(() => _declareThickness = v),
            ),
            if (_declareThickness)
              _num('Espesor de muros', _thickness, 'm', (v) => setState(() => _thickness = v), min: 0.08, max: 0.40, div: 32),
          ]),
        ),
      );

  Widget _hazardsCard(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [const Icon(Icons.vibration_rounded, size: 18), const SizedBox(width: 8), Text('Sismo', style: t.textTheme.titleSmall)]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final (v, l) in [(0.1, 'Baja'), (0.2, 'Moderada'), (0.3, 'Alta'), (0.45, 'Muy alta')])
              ChoiceChip(label: Text('$l · ${v}g'), selected: _pga == v, onSelected: (_) => setState(() => _pga = v)),
          ]),
          const SizedBox(height: Gap.sm),
          DropdownButtonFormField<SoilClass>(
            initialValue: _soil,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Suelo'),
            items: [for (final s in SoilClass.values) DropdownMenuItem(value: s, child: Text('${s.label} (S = ${s.factor})'))],
            onChanged: (v) => setState(() => _soil = v ?? _soil),
          ),
          const Divider(height: Gap.xxl),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.waves_rounded),
              title: const Text('Tsunami'),
              value: _tsunami,
              onChanged: (v) => setState(() => _tsunami = v)),
          if (_tsunami) ...[
            _num('Profundidad de inundación', _depth, 'm', (v) => setState(() => _depth = v), min: 0.5, max: 8, div: 30),
            _dirDropdown('Dirección del agua', _waterDir, (v) => setState(() => _waterDir = v)),
          ],
          const Divider(height: Gap.xxl),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.air_rounded),
              title: const Text('Viento'),
              value: _wind,
              onChanged: (v) => setState(() => _wind = v)),
          if (_wind) ...[
            _num('Velocidad de ráfaga', _windSpeed, 'm/s', (v) => setState(() => _windSpeed = v), min: 15, max: 75, div: 60),
            _dirDropdown('Dirección del viento', _windDir, (v) => setState(() => _windDir = v)),
          ],
        ]),
      ),
    );
  }

  Widget _dirDropdown(String label, FlowDirection value, ValueChanged<FlowDirection> onChanged) => Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: DropdownButtonFormField<FlowDirection>(
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [for (final d in FlowDirection.values) DropdownMenuItem(value: d, child: Text(d.label))],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      );
}

class _ScaleCard extends ConsumerStatefulWidget {
  final String projectId;
  final BuildingModel model;
  const _ScaleCard({required this.projectId, required this.model});
  @override
  ConsumerState<_ScaleCard> createState() => _ScaleCardState();
}

class _ScaleCardState extends ConsumerState<_ScaleCard> {
  String? _wallId;
  final _meters = TextEditingController();
  bool _editing = false;
  bool _wallMethod = false;
  String? _error;

  @override
  void dispose() {
    _meters.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final m = double.tryParse(_meters.text.replaceAll(',', '.'));
    if (_wallId == null || m == null) {
      setState(() => _error = 'Elegí un muro e ingresá su largo en metros.');
      return;
    }
    try {
      final p = await ref.read(projectStoreProvider).load(widget.projectId);
      await ref.read(screeningServiceProvider).calibrate(p, _wallId!, m);
      ref.invalidate(simModelProvider(widget.projectId));
      setState(() {
        _editing = false;
        _error = null;
      });
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = widget.model.scale;
    final walls = widget.model.allElements.whereType<Wall>().toList()
      ..sort((a, b) => longSide(b.bounds).compareTo(longSide(a.bounds)));
    if (s != null && s.verified && !_editing) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.straighten_rounded, color: StructuraColors.success),
          title: Text('Escala verificada: ${s.pxPerUnit.toStringAsFixed(1)} px/m', style: const TextStyle(fontFeatures: tabular)),
          subtitle: Text(s.source.note ?? 'Verificada por el usuario'),
          trailing: TextButton(onPressed: () => setState(() => _editing = true), child: const Text('Recalibrar')),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Para calcular fuerzas reales hace falta una medida verdadera. Marcá sobre el plano los dos extremos '
              'de una cota que conozcas (por ejemplo, el ancho total) e ingresá su valor.', style: t.textTheme.bodyMedium),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            key: const Key('open_calibrate'),
            onPressed: () async {
              await context.push('/projects/${widget.projectId}/calibrate');
              ref.invalidate(simModelProvider(widget.projectId));
            },
            icon: const Icon(Icons.straighten_rounded),
            label: const Text('Calibrar con una cota del plano'),
          ),
          const SizedBox(height: Gap.sm),
          TextButton(
            key: const Key('toggle_wall_method'),
            onPressed: () => setState(() => _wallMethod = !_wallMethod),
            child: Text(_wallMethod ? 'Ocultar método por muro' : 'O usar el largo de un muro detectado'),
          ),
          if (_wallMethod) ...[
          const SizedBox(height: Gap.md),
          DropdownButtonFormField<String>(
            key: const Key('scale_wall'),
            initialValue: _wallId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Muro de referencia'),
            items: [
              for (final w in walls.take(40))
                DropdownMenuItem(
                  value: w.id,
                  child: Text('${w.id} · ${longSide(w.bounds).toStringAsFixed(0)} px · '
                      '${(w.end.x - w.start.x).abs() >= (w.end.y - w.start.y).abs() ? 'horizontal' : 'vertical'}'),
                ),
            ],
            onChanged: (v) => setState(() => _wallId = v),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('scale_meters'),
            controller: _meters,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Largo real del muro (m)', hintText: 'Ej.: 4,50'),
          ),
          if (_error != null) ...[const SizedBox(height: Gap.sm), NoticeBanner(_error!, color: StructuraColors.danger)],
          const SizedBox(height: Gap.md),
          FilledButton.tonal(key: const Key('save_scale'), onPressed: _save, child: const Text('Guardar escala verificada')),
          ],
        ]),
      ),
    );
  }
}

double longSide(Rect2 r) => r.width > r.height ? r.width : r.height;

/// Número con coma decimal (formato local).
String fmt(double v, int decimals) => v.toStringAsFixed(decimals).replaceAll('.', ',');

/// Valor de un indicador: relaciones muy altas se muestran acotadas para no
/// transmitir una precisión que el método simplificado no tiene.
String formatIndicator(Indicator i) {
  if (!i.value.isFinite) return 'sin capacidad';
  if (i.unit.isEmpty && i.value >= 10) return '> 10 ×';
  final unit = i.unit.isEmpty ? '' : ' ${i.unit}';
  return '${fmt(i.value, 2)}$unit';
}

class _HazardCard extends StatefulWidget {
  final HazardResult result;
  final String projectId;
  const _HazardCard({required this.result, required this.projectId});
  @override
  State<_HazardCard> createState() => _HazardCardState();
}

class _HazardCardState extends State<_HazardCard> {
  bool _showAssumptions = false;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = widget.result;
    final overall = r.overall;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(hazardIcons[r.hazard], color: statusColorOf(overall)),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(hazardLabels[r.hazard]!, style: t.textTheme.titleMedium)),
            ]),
            const SizedBox(height: Gap.sm),
            StatusPill(statusLabel(overall), color: statusColorOf(overall)),
            const SizedBox(height: Gap.md),
            for (final i in r.indicators)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                      margin: const EdgeInsets.only(top: 5),
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: statusColorOf(i.status), shape: BoxShape.circle)),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(i.label),
                      if (i.explanation.isNotEmpty)
                        Text(i.explanation, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    ]),
                  ),
                  const SizedBox(width: Gap.sm),
                  Text(
                    formatIndicator(i),
                    style: t.textTheme.titleSmall?.copyWith(fontFeatures: tabular, color: statusColorOf(i.status)),
                  ),
                ]),
              ),
            const SizedBox(height: Gap.sm),
            Text('Relación demanda/capacidad: < 0,7 esperable · 0,7–1,0 revisar · > 1,0 la demanda supera la capacidad estimada.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, children: [
              FilledButton.tonalIcon(
                key: Key('view3d_${r.hazard.name}'),
                onPressed: () => context.push('/projects/${widget.projectId}/model?hazard=${r.hazard.name}'),
                icon: const Icon(Icons.view_in_ar_rounded),
                label: const Text('Ver en 3D'),
              ),
              TextButton(
                  onPressed: () => setState(() => _showAssumptions = !_showAssumptions),
                  child: Text(_showAssumptions ? 'Ocultar supuestos' : 'Ver supuestos (${r.assumptions.length})')),
            ]),
            if (_showAssumptions)
              for (final a in r.assumptions)
                Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $a', style: t.textTheme.bodySmall)),
          ]),
        ),
      ),
    );
  }
}
