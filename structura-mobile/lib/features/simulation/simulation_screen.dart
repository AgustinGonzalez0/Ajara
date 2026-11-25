import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:structura_model/structura_model.dart';
import 'package:structura_sim/structura_sim.dart';

import '../../app/flows.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../widgets/common.dart';
import '../model3d/model_screen.dart' show model3dProvider;

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

String statusShort(Status s) => switch (s) {
      Status.ok => 'ESPERABLE',
      Status.attention => 'REVISAR',
      Status.critical => 'SUPERA',
      Status.notApplicable => 'INFO',
    };

const hazardLabels = {Hazard.seismic: 'Sismo / terremoto', Hazard.tsunami: 'Tsunami', Hazard.wind: 'Viento'};
const hazardShort = {Hazard.seismic: 'Sismo', Hazard.tsunami: 'Tsunami', Hazard.wind: 'Viento'};
const hazardIcons = {Hazard.seismic: Icons.vibration_rounded, Hazard.tsunami: Icons.waves_rounded, Hazard.wind: Icons.air_rounded};

/// Zonas sísmicas del reglamento INPRES-CIRSOC 103 (2013) con su aceleración de
/// referencia. Son valores de referencia: el profesional confirma la zona de la localidad.
const seismicZones = [(0, 0.04), (1, 0.10), (2, 0.18), (3, 0.25), (4, 0.35)];

/// Presets de edificación: un toque completa pisos, altura y material.
class BuildingPreset {
  final String label;
  final IconData icon;
  final int floors;
  final double story;
  final WallMaterial material;
  const BuildingPreset(this.label, this.icon, this.floors, this.story, this.material);
}

const buildingPresets = [
  BuildingPreset('Casa 1 planta', Icons.cottage_outlined, 1, 2.6, WallMaterial.confinedMasonry),
  BuildingPreset('Casa 2 plantas', Icons.house_outlined, 2, 2.7, WallMaterial.confinedMasonry),
  BuildingPreset('Edificio 4 pisos', Icons.apartment_rounded, 4, 2.8, WallMaterial.reinforcedConcrete),
];

String fmt(double v, int decimals) => v.toStringAsFixed(decimals).replaceAll('.', ',');

/// Valor de un indicador: relaciones muy altas se muestran acotadas para no
/// transmitir una precisión que el método simplificado no tiene.
String formatIndicator(Indicator i) {
  if (!i.value.isFinite) return 'sin capacidad';
  if (i.unit.isEmpty && i.value >= 10) return '> 10 ×';
  final unit = i.unit.isEmpty ? '' : ' ${i.unit}';
  return '${fmt(i.value, 2)}$unit';
}

const _dirIcons = {
  FlowDirection.plusX: Icons.arrow_forward_rounded,
  FlowDirection.minusX: Icons.arrow_back_rounded,
  FlowDirection.plusY: Icons.arrow_downward_rounded,
  FlowDirection.minusY: Icons.arrow_upward_rounded,
};

class SimulationScreen extends ConsumerStatefulWidget {
  final String projectId;
  const SimulationScreen({super.key, required this.projectId});
  @override
  ConsumerState<SimulationScreen> createState() => _SimulationScreenState();
}

class _SimulationScreenState extends ConsumerState<SimulationScreen> {
  final _scroll = ScrollController();
  // Edificio
  int _floors = 1;
  double _story = 2.6;
  WallMaterial _material = WallMaterial.confinedMasonry;
  bool _declareThickness = false;
  double _thickness = 0.15;
  // Sismo
  double _pga = 0.25;
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
  bool _restored = false;
  bool _exporting = false;
  bool _pdfSaved = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  BuildingInput get _building => BuildingInput(
      floors: _floors, storyHeightM: _story, material: _material, wallThicknessM: _declareThickness ? _thickness : null);
  SeismicInput get _seismic => SeismicInput(pgaG: _pga, soil: _soil);
  TsunamiInput? get _tsunamiInput => _tsunami ? TsunamiInput(inundationDepthM: _depth, direction: _waterDir) : null;
  WindInput? get _windInput => _wind ? WindInput(speedMs: _windSpeed, direction: _windDir) : null;

  T _byName<T extends Enum>(List<T> values, Object? name, T fallback) =>
      values.firstWhere((v) => v.name == name, orElse: () => fallback);

  /// Al volver a la pantalla se recuperan los datos y resultados de la última evaluación
  /// (se recalculan en memoria: el método es determinista y no se reescribe nada).
  void _restoreFrom(Map<String, Object?> j, BuildingModel m) {
    try {
      final b = (j['building'] as Map).cast<String, Object?>();
      final inputs = (j['inputs'] as Map).cast<String, Object?>();
      _floors = (b['floors'] as num).toInt();
      _story = (b['story_height_m'] as num).toDouble();
      _material = _byName(WallMaterial.values, b['material'], _material);
      final t = b['wall_thickness_m'] as num?;
      _declareThickness = t != null;
      if (t != null) _thickness = t.toDouble();
      final s = (inputs['seismic'] as Map).cast<String, Object?>();
      _pga = (s['pga_g'] as num).toDouble();
      _soil = _byName(SoilClass.values, s['soil'], _soil);
      final ts = (inputs['tsunami'] as Map?)?.cast<String, Object?>();
      _tsunami = ts != null;
      if (ts != null) {
        _depth = (ts['inundation_depth_m'] as num).toDouble();
        _waterDir = _byName(FlowDirection.values, ts['direction'], _waterDir);
      }
      final w = (inputs['wind'] as Map?)?.cast<String, Object?>();
      _wind = w != null;
      if (w != null) {
        _windSpeed = (w['speed_ms'] as num).toDouble();
        _windDir = _byName(FlowDirection.values, w['direction'], _windDir);
      }
      _report = runScreening(m, _building, seismic: _seismic, tsunami: _tsunamiInput, wind: _windInput);
    } on Object {
      _report = null; // informe de otra versión: se empieza de cero
    }
  }

  Future<void> _evaluate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await ref.read(projectStoreProvider).load(widget.projectId);
      final r = await ref
          .read(screeningServiceProvider)
          .evaluate(p, _building, seismic: _seismic, tsunami: _tsunamiInput, wind: _windInput);
      ref.invalidate(lastReportProvider(widget.projectId));
      ref.invalidate(model3dProvider(widget.projectId));
      setState(() {
        _report = r;
        _pdfSaved = false;
      });
      if (_scroll.hasClients) {
        _scroll.animateTo(0, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
      }
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportPdf() async {
    setState(() => _exporting = true);
    try {
      await exportAndShareReport(ref, widget.projectId);
      if (mounted) setState(() => _pdfSaved = true);
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'No se pudo generar el informe: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _showDisclaimer() => showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (c) => const Padding(
          padding: EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            NoticeBanner(screeningDisclaimer, color: StructuraColors.warning, icon: Icons.gpp_maybe_outlined),
            SizedBox(height: Gap.md),
            Text('Métodos simplificados: fuerza lateral estática equivalente (sismo), FEMA P-646 simplificado '
                '(tsunami) y presión de viento q = 0,613·V². Un plano o una foto no contienen armaduras, '
                'fundaciones, suelo de apoyo ni calidad constructiva.'),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final model = ref.watch(simModelProvider(widget.projectId));
    final last = ref.watch(lastReportProvider(widget.projectId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Evaluación preliminar'),
        actions: [IconButton(tooltip: 'Qué es y qué no es', onPressed: _showDisclaimer, icon: const Icon(Icons.info_outline))],
      ),
      body: SafeArea(
        bottom: false,
        child: model.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(icon: Icons.analytics_outlined, title: 'Evaluación no disponible', message: '$e'),
          data: (m) {
            if (!m.hasVerifiedScale) return _NoScale(projectId: widget.projectId);
            if (!_restored && !last.isLoading) {
              _restored = true;
              final j = last.value;
              if (j != null) _restoreFrom(j, m);
            }
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl), children: [
                  _DisclaimerStrip(onTap: _showDisclaimer),
                  if (_report != null) ...[
                    const SizedBox(height: Gap.md),
                    _ResultsPanel(report: _report!, projectId: widget.projectId, pdfSaved: _pdfSaved),
                  ],
                  if (_error != null) ...[const SizedBox(height: Gap.md), NoticeBanner(_error!, color: StructuraColors.danger)],
                  const SizedBox(height: Gap.md),
                  _ScaleRow(projectId: widget.projectId, model: m),
                  const SectionLabel('Edificio'),
                  _buildingCard(context, m),
                  const SectionLabel('Peligros'),
                  _hazardsCard(context),
                ]),
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: model.value?.hasVerifiedScale == true
          ? ActionBar(children: [
              if (_report != null)
                OutlinedButton.icon(
                  key: const Key('export_pdf'),
                  onPressed: _exporting ? null : _exportPdf,
                  icon: _exporting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('PDF'),
                ),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('run_screening'),
                  onPressed: _busy ? null : _evaluate,
                  icon: _busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.analytics_rounded),
                  label: Text(_report == null ? 'Evaluar' : 'Volver a evaluar'),
                ),
              ),
            ])
          : null,
    );
  }

  // ------------------------------------------------------------------ Edificio

  double? _detectedThickness(BuildingModel m) {
    final s = m.scale;
    if (s == null || !s.verified) return null;
    final t = m.allElements.whereType<Wall>().map((w) => w.thicknessPx).toList()..sort();
    if (t.isEmpty) return null;
    return s.pxToMeters(t[t.length ~/ 2]);
  }

  BuildingPreset? get _preset {
    for (final p in buildingPresets) {
      if (p.floors == _floors && (p.story - _story).abs() < 1e-6 && p.material == _material) return p;
    }
    return null;
  }

  Widget _buildingCard(BuildContext context, BuildingModel model) {
    final t = Theme.of(context);
    final detected = _detectedThickness(model);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final p in buildingPresets) ...[
                ChoiceChip(
                  key: Key('preset_${buildingPresets.indexOf(p)}'),
                  avatar: Icon(p.icon, size: 18),
                  label: Text(p.label),
                  selected: _preset == p,
                  onSelected: (_) => setState(() {
                    _floors = p.floors;
                    _story = p.story;
                    _material = p.material;
                  }),
                ),
                const SizedBox(width: Gap.sm),
              ],
            ]),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: _Stepper(
                key: const Key('floors'),
                label: 'Pisos',
                value: '$_floors',
                onMinus: _floors > 1 ? () => setState(() => _floors--) : null,
                onPlus: _floors < 30 ? () => setState(() => _floors++) : null,
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: _Stepper(
                label: 'Altura por piso',
                value: '${fmt(_story, 2)} m',
                onMinus: _story > 2.21 ? () => setState(() => _story = ((_story - 0.1) * 10).roundToDouble() / 10) : null,
                onPlus: _story < 5.99 ? () => setState(() => _story = ((_story + 0.1) * 10).roundToDouble() / 10) : null,
              ),
            ),
          ]),
          const SizedBox(height: Gap.md),
          DropdownButtonFormField<WallMaterial>(
            key: ValueKey('material_$_material'),
            initialValue: _material,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Material de muros', isDense: true),
            items: [
              for (final m in WallMaterial.values) DropdownMenuItem(value: m, child: Text(m.label, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _material = v ?? _material),
          ),
          const SizedBox(height: Gap.xs),
          Text(
              'Valores indicativos: τ ${fmt(_material.shearStrength, 2)} MPa · f ${fmt(_material.flexuralStrength, 2)} MPa · '
              'γ ${fmt(_material.unitWeight, 0)} kN/m³ · R ${fmt(_material.responseFactor, 1)}',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const Divider(height: Gap.xl),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Espesor real de muros', style: t.textTheme.bodyLarge),
                Text(
                    detected == null
                        ? 'Sin dato detectado'
                        : 'Detectado: ${fmt(detected * 100, 0)} cm. En fotos puede ser impreciso.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ]),
            ),
            Switch(
              key: const Key('declare_thickness'),
              value: _declareThickness,
              onChanged: (v) => setState(() {
                _declareThickness = v;
                if (v && detected != null && detected >= 0.08 && detected <= 0.4) {
                  _thickness = (detected * 100).roundToDouble() / 100;
                }
              }),
            ),
          ]),
          if (_declareThickness) ...[
            const SizedBox(height: Gap.sm),
            _Stepper(
              label: 'Espesor declarado',
              value: '${fmt(_thickness * 100, 0)} cm',
              onMinus: _thickness > 0.081 ? () => setState(() => _thickness = ((_thickness - 0.01) * 100).roundToDouble() / 100) : null,
              onPlus: _thickness < 0.399 ? () => setState(() => _thickness = ((_thickness + 0.01) * 100).roundToDouble() / 100) : null,
            ),
          ],
        ]),
      ),
    );
  }

  // ------------------------------------------------------------------ Peligros

  Widget _hazardsCard(BuildContext context) {
    final t = Theme.of(context);
    final zone = seismicZones.where((z) => (z.$2 - _pga).abs() < 1e-9).firstOrNull;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.vibration_rounded, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text('Sismo · zona INPRES-CIRSOC 103', style: t.textTheme.titleSmall)),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (z, a) in seismicZones)
              ChoiceChip(
                key: Key('zone_$z'),
                label: Text('$z · ${fmt(a, 2)} g', style: const TextStyle(fontFeatures: tabular)),
                selected: zone?.$1 == z,
                onSelected: (_) => setState(() => _pga = a),
              ),
            ChoiceChip(
              label: Text(zone == null ? 'Otro · ${fmt(_pga, 2)} g' : 'Otro'),
              selected: zone == null,
              onSelected: (_) => setState(() => _pga = zone == null ? _pga : 0.30),
            ),
          ]),
          if (zone == null)
            Slider(
                value: _pga.clamp(0.02, 0.8),
                min: 0.02,
                max: 0.8,
                divisions: 78,
                label: '${fmt(_pga, 2)} g',
                onChanged: (v) => setState(() => _pga = (v * 100).roundToDouble() / 100)),
          Text('Aceleración de referencia. Confirmá la zona de la localidad en el reglamento vigente.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          Text('Suelo', style: t.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final s in SoilClass.values)
              ChoiceChip(
                key: Key('soil_${s.name}'),
                label: Text('${_cap(s.label.replaceFirst('Suelo ', ''))} · S ${fmt(s.factor, 2)}'),
                selected: _soil == s,
                onSelected: (_) => setState(() => _soil = s),
              ),
          ]),
          const Divider(height: Gap.xl),
          _HazardToggle(
            key: const Key('toggle_tsunami'),
            icon: Icons.waves_rounded,
            title: 'Tsunami',
            summary: 'Agua ${fmt(_depth, 1)} m · ${_short(_waterDir)}',
            value: _tsunami,
            onChanged: (v) => setState(() => _tsunami = v),
            child: Column(children: [
              _Stepper(
                label: 'Profundidad de inundación',
                value: '${fmt(_depth, 1)} m',
                onMinus: _depth > 0.51 ? () => setState(() => _depth = ((_depth - 0.5) * 10).roundToDouble() / 10) : null,
                onPlus: _depth < 9.99 ? () => setState(() => _depth = ((_depth + 0.5) * 10).roundToDouble() / 10) : null,
              ),
              const SizedBox(height: Gap.sm),
              _DirectionPicker(label: 'Dirección del agua', value: _waterDir, onChanged: (d) => setState(() => _waterDir = d)),
            ]),
          ),
          const Divider(height: Gap.xl),
          _HazardToggle(
            key: const Key('toggle_wind'),
            icon: Icons.air_rounded,
            title: 'Viento',
            summary: 'Ráfaga ${fmt(_windSpeed, 0)} m/s (${fmt(_windSpeed * 3.6, 0)} km/h) · ${_short(_windDir)}',
            value: _wind,
            onChanged: (v) => setState(() => _wind = v),
            child: Column(children: [
              _Stepper(
                label: 'Velocidad de ráfaga',
                value: '${fmt(_windSpeed, 0)} m/s',
                onMinus: _windSpeed > 15 ? () => setState(() => _windSpeed -= 5) : null,
                onPlus: _windSpeed < 75 ? () => setState(() => _windSpeed += 5) : null,
              ),
              const SizedBox(height: Gap.sm),
              _DirectionPicker(label: 'Dirección del viento', value: _windDir, onChanged: (d) => setState(() => _windDir = d)),
            ]),
          ),
        ]),
      ),
    );
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  static String _short(FlowDirection d) => switch (d) {
        FlowDirection.plusX => 'desde la izquierda',
        FlowDirection.minusX => 'desde la derecha',
        FlowDirection.plusY => 'desde arriba',
        FlowDirection.minusY => 'desde abajo',
      };
}

// ---------------------------------------------------------------------------

class _DisclaimerStrip extends StatelessWidget {
  final VoidCallback onTap;
  const _DisclaimerStrip({required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: const NoticeBanner(
          'Preliminar: estima órdenes de magnitud. No reemplaza el cálculo ni determina que la estructura sea segura.',
          icon: Icons.gpp_maybe_outlined,
        ),
      );
}

class _NoScale extends ConsumerWidget {
  final String projectId;
  const _NoScale({required this.projectId});
  @override
  Widget build(BuildContext context, WidgetRef ref) => EmptyState(
        icon: Icons.straighten_rounded,
        title: 'Falta la escala',
        message: 'Para calcular fuerzas reales hace falta una medida verdadera: marcá una cota conocida del plano.',
        action: FilledButton.icon(
          key: const Key('open_calibrate'),
          onPressed: () => context.pushReplacement(Routes.calibrate(projectId, thenSimulate: true)),
          icon: const Icon(Icons.straighten_rounded),
          label: const Text('Marcar una cota'),
        ),
      );
}

class _ScaleRow extends ConsumerWidget {
  final String projectId;
  final BuildingModel model;
  const _ScaleRow({required this.projectId, required this.model});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final s = model.scale!;
    return Card(
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.straighten_rounded, color: StructuraColors.success),
        title: Text('Escala verificada · ${fmt(s.pxPerUnit, 1)} px/m', style: const TextStyle(fontFeatures: tabular)),
        subtitle: Text(s.source.note ?? 'Verificada por el usuario',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
        trailing: TextButton(
          key: const Key('recalibrate'),
          onPressed: () async {
            await context.push(Routes.calibrate(projectId));
            ref.invalidate(simModelProvider(projectId));
          },
          child: const Text('Cambiar'),
        ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  const _Stepper({super.key, required this.label, required this.value, this.onMinus, this.onPlus});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.md, 6, 4, 6),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHigh.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant, letterSpacing: 0.2)),
            Text(value, style: t.textTheme.titleMedium?.copyWith(fontFeatures: tabular)),
          ]),
        ),
        IconButton(visualDensity: VisualDensity.compact, onPressed: onMinus, icon: const Icon(Icons.remove_rounded)),
        IconButton(visualDensity: VisualDensity.compact, onPressed: onPlus, icon: const Icon(Icons.add_rounded)),
      ]),
    );
  }
}

class _HazardToggle extends StatelessWidget {
  final IconData icon;
  final String title;
  final String summary;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget child;
  const _HazardToggle(
      {super.key,
      required this.icon,
      required this.title,
      required this.summary,
      required this.value,
      required this.onChanged,
      required this.child});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.textTheme.titleSmall),
            Text(value ? summary : 'No se evalúa',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant, fontFeatures: tabular)),
          ]),
        ),
        Switch(value: value, onChanged: onChanged),
      ]),
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        child: value ? Padding(padding: const EdgeInsets.only(top: Gap.sm), child: child) : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}

class _DirectionPicker extends StatelessWidget {
  final String label;
  final FlowDirection value;
  final ValueChanged<FlowDirection> onChanged;
  const _DirectionPicker({required this.label, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(children: [
      Expanded(child: Text(label, style: t.textTheme.bodyMedium)),
      SegmentedButton<FlowDirection>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
        segments: [
          for (final d in FlowDirection.values)
            ButtonSegment(value: d, icon: Icon(_dirIcons[d], size: 18), tooltip: d.label.replaceAll(RegExp(r' \(.*\)'), '')),
        ],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------

class _ResultsPanel extends StatelessWidget {
  final ScreeningReport report;
  final String projectId;
  final bool pdfSaved;
  const _ResultsPanel({required this.report, required this.projectId, required this.pdfSaved});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: const Key('results_panel'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Resultados', style: t.textTheme.titleMedium)),
            if (pdfSaved)
              const Padding(
                padding: EdgeInsets.only(right: Gap.sm),
                child: StatusPill('PDF GUARDADO', key: Key('pdf_saved'), color: StructuraColors.success, icon: Icons.check_rounded),
              ),
          ]),
          const SizedBox(height: Gap.xs),
          for (final r in report.results) _HazardRow(result: r, projectId: projectId),
          const SizedBox(height: Gap.xs),
          Padding(
            padding: const EdgeInsets.only(right: Gap.sm),
            child: Text('Demanda/capacidad: < 0,7 esperable · 0,7–1,0 revisar · > 1,0 supera la capacidad estimada.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

class _HazardRow extends StatefulWidget {
  final HazardResult result;
  final String projectId;
  const _HazardRow({required this.result, required this.projectId});
  @override
  State<_HazardRow> createState() => _HazardRowState();
}

class _HazardRowState extends State<_HazardRow> {
  bool _open = false;
  bool _assumptions = false;

  Indicator? get _worst {
    Indicator? w;
    for (final i in widget.result.indicators) {
      if (i.unit.isNotEmpty || i.status == Status.notApplicable) continue;
      if (w == null || !i.value.isFinite || (w.value.isFinite && i.value > w.value)) w = i;
    }
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = widget.result;
    final c = statusColorOf(r.overall);
    final worst = _worst;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        key: Key('hazard_${r.hazard.name}'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
              child: Icon(hazardIcons[r.hazard], color: c, size: 20),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(hazardShort[r.hazard]!, style: t.textTheme.titleSmall, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: Gap.sm),
                  StatusPill(statusShort(r.overall), color: c),
                ]),
                if (worst != null)
                  Text(worst.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant, fontFeatures: tabular)),
              ]),
            ),
            if (worst != null)
              Text(formatIndicator(worst),
                  style: t.textTheme.titleMedium?.copyWith(color: statusColorOf(worst.status), fontFeatures: tabular)),
            IconButton(
              key: Key('view3d_${r.hazard.name}'),
              tooltip: 'Ver en 3D',
              onPressed: () => context.push(Routes.model3dHazard(widget.projectId, r.hazard.name)),
              icon: const Icon(Icons.view_in_ar_rounded),
            ),
            Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: t.colorScheme.onSurfaceVariant),
          ]),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: !_open
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.fromLTRB(48, 0, Gap.sm, Gap.sm),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(statusLabel(r.overall), style: t.textTheme.labelSmall?.copyWith(color: c)),
                  const SizedBox(height: Gap.xs),
                  for (final i in r.indicators)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                            margin: const EdgeInsets.only(top: 5),
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(color: statusColorOf(i.status), shape: BoxShape.circle)),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(i.label, style: t.textTheme.bodyMedium),
                            if (i.explanation.isNotEmpty)
                              Text(i.explanation, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                          ]),
                        ),
                        const SizedBox(width: Gap.sm),
                        Text(formatIndicator(i),
                            style: t.textTheme.titleSmall?.copyWith(fontFeatures: tabular, color: statusColorOf(i.status))),
                      ]),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _assumptions = !_assumptions),
                      child: Text(_assumptions ? 'Ocultar supuestos' : 'Ver supuestos (${r.assumptions.length})'),
                    ),
                  ),
                  if (_assumptions)
                    for (final a in r.assumptions)
                      Padding(padding: const EdgeInsets.only(top: 2), child: Text('• $a', style: t.textTheme.bodySmall)),
                ]),
              ),
      ),
      Divider(height: 1, color: t.colorScheme.outlineVariant),
    ]);
  }
}
