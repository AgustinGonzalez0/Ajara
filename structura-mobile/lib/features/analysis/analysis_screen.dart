import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:structura_pipeline/structura_pipeline.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../data/project_models.dart';
import '../../services/model_registry.dart';
import '../../widgets/common.dart';

class AnalysisScreen extends ConsumerStatefulWidget {
  final String projectId;
  const AnalysisScreen({super.key, required this.projectId});
  @override
  ConsumerState<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends ConsumerState<AnalysisScreen> {
  String? _modelId;

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(projectProvider(widget.projectId));
    final models = ref.watch(installedModelsProvider);
    final state = ref.watch(analysisControllerProvider(widget.projectId));
    final runnerAvailable = ref.watch(analysisRunnerProvider) != null;
    // Al terminar bien, vuelve al panel del proyecto: ahí está el 3D y la acción siguiente.
    ref.listen(analysisControllerProvider(widget.projectId), (prev, next) {
      if (prev?.phase == AnalysisPhase.running && next.phase == AnalysisPhase.completed && context.canPop()) {
        context.pop();
      }
    });
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Análisis del plano')),
      body: SafeArea(
        child: project.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(icon: Icons.error_outline, title: 'Error', message: '$e'),
          data: (p) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(padding: const EdgeInsets.all(Gap.xl), children: [
                const SectionLabel('Motor de análisis'),
                _EngineTile(
                  key: const Key('engine_classic'),
                  selected: (_modelId ?? 'classic') == 'classic',
                  icon: Icons.bolt_rounded,
                  title: 'Clásico — sin IA',
                  badges: const [('RECOMENDADO', StructuraColors.success), ('CUALQUIER CELULAR', StructuraColors.accent)],
                  detail: 'Visión por computadora determinista: muros por espesor de trazo, vanos y ventanas por huecos '
                      'en los muros, columnas. Instantáneo, sin descargas ni conexión. No detecta escaleras.',
                  onTap: () => setState(() => _modelId = 'classic'),
                ),
                models.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => NoticeBanner('No se pudieron cargar los modelos: $e', color: StructuraColors.danger),
                  data: (list) => Column(children: [
                    for (final m in list)
                      _ModelTile(m, selected: _modelId == m.descriptor.id, onTap: () => setState(() => _modelId = m.descriptor.id)),
                  ]),
                ),
                if (_modelId != null && _modelId != 'classic' && !runnerAvailable)
                  const NoticeBanner('Este dispositivo no puede ejecutar modelos de IA (ONNX Runtime). Usá el motor clásico.',
                      color: StructuraColors.danger, icon: Icons.block_rounded),
                const SectionLabel('Ejecución'),
                _RunPanel(
                  state: state,
                  canRun: p.activePlan != null && ((_modelId ?? 'classic') == 'classic' || runnerAvailable),
                  onRun: () {
                    final ctrl = ref.read(analysisControllerProvider(widget.projectId).notifier);
                    final id = _modelId ?? 'classic';
                    if (id == 'classic') {
                      ctrl.start();
                    } else {
                      ctrl.start(model: models.value!.firstWhere((m) => m.descriptor.id == id));
                    }
                  },
                  onCancel: () => ref.read(analysisControllerProvider(widget.projectId).notifier).cancel(),
                ),
                if (p.activeAnalysis != null) ...[
                  const SectionLabel('Último resultado'),
                  _ResultCard(p.activeAnalysis!),
                  const SizedBox(height: Gap.md),
                  Wrap(spacing: Gap.sm, children: [
                    FilledButton.tonal(onPressed: () => context.push(Routes.editor(p.id)), child: const Text('Revisar en editor 2D')),
                    FilledButton.tonal(onPressed: () => context.push(Routes.model3d(p.id)), child: const Text('Ver modelo 3D')),
                  ]),
                ],
                if (p.analyses.length > 1) ...[
                  SectionLabel('Historial (${p.analyses.length})'),
                  for (final a in p.analyses.reversed)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        switch (a.status) {
                          AnalysisStatus.completed => Icons.check_circle_outline,
                          AnalysisStatus.failed => Icons.error_outline,
                          AnalysisStatus.cancelled => Icons.cancel_outlined,
                        },
                        color: switch (a.status) {
                          AnalysisStatus.completed => StructuraColors.success,
                          AnalysisStatus.failed => StructuraColors.danger,
                          AnalysisStatus.cancelled => StructuraColors.textMuted,
                        },
                      ),
                      title: Text('${formatDate(a.createdAt)} · ${a.model['id']}', style: const TextStyle(fontFeatures: tabular)),
                      subtitle: a.error == null ? null : Text(a.error!, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                ],
                const SizedBox(height: Gap.lg),
                Text('Etapas futuras', style: t.textTheme.titleSmall),
                const SizedBox(height: Gap.sm),
                const PendingFeature(title: 'Dimension AI', detail: 'Lectura de cotas (OCR) y propuesta de escala para verificación humana.'),
                const SizedBox(height: Gap.sm),
                const PendingFeature(title: 'Spatial AI', detail: 'Detección de ambientes y relaciones espaciales.'),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _EngineTile extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String title;
  final String detail;
  final List<(String, Color)> badges;
  final VoidCallback onTap;
  const _EngineTile(
      {super.key, required this.selected, required this.icon, required this.title, required this.detail, required this.badges, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: StructuraColors.accent),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [Icon(icon, size: 18), const SizedBox(width: 6), Flexible(child: Text(title, style: t.textTheme.titleSmall))]),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [for (final (l, c) in badges) StatusPill(l, color: c)]),
                  const SizedBox(height: Gap.sm),
                  Text(detail, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  final InstalledModel m;
  final bool selected;
  final VoidCallback onTap;
  const _ModelTile(this.m, {required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final d = m.descriptor;
    final t = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: StructuraColors.accent),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${d.id} · v${d.version}', style: t.textTheme.titleSmall),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  StatusPill(modelStage(d.trainingData, d.isTestModel),
                      color: d.isTestModel ? StructuraColors.warning : StructuraColors.success, icon: Icons.science_outlined),
                  if (d.headlineMetric != null) StatusPill(d.headlineMetric!, color: StructuraColors.teal),
                  StatusPill(m.hashVerified ? 'SHA-256 OK' : 'SHA-256 NO VERIFICADO',
                      color: m.hashVerified ? StructuraColors.success : StructuraColors.danger),
                  StatusPill('${d.tile}px · overlap ${d.overlap}', color: StructuraColors.textMuted),
                ]),
                const SizedBox(height: Gap.sm),
                Text(d.trustLabel, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                if (d.notes.isNotEmpty) Text(d.notes, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _RunPanel extends StatelessWidget {
  final AnalysisState state;
  final bool canRun;
  final VoidCallback onRun;
  final VoidCallback onCancel;
  const _RunPanel({required this.state, required this.canRun, required this.onRun, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final running = state.phase == AnalysisPhase.running;
    final events = {for (final e in state.stageLog) e.stageId: e};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (i, (id, label)) in AnalysisPipeline.stages.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: _StageRow(index: i + 1, label: events[id]?.stageLabel ?? label, event: events[id], active: state.progress?.stageId == id && running),
            ),
          if (state.message != null && state.phase != AnalysisPhase.running)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: NoticeBanner(state.message!,
                  color: state.phase == AnalysisPhase.cancelled ? StructuraColors.textMuted : StructuraColors.danger),
            ),
          if (state.phase == AnalysisPhase.completed)
            const Padding(
              padding: EdgeInsets.only(bottom: Gap.md),
              child: NoticeBanner('Análisis completado y guardado en el proyecto.', color: StructuraColors.success, icon: Icons.check_circle_outline),
            ),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('run_analysis'),
                onPressed: canRun && !running ? onRun : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(running ? 'Analizando…' : 'Ejecutar análisis'),
              ),
            ),
            if (running) ...[
              const SizedBox(width: Gap.md),
              OutlinedButton(onPressed: onCancel, child: const Text('Cancelar')),
            ],
          ]),
          if (running && state.progress != null) ...[
            const SizedBox(height: Gap.sm),
            Text('Progreso total ${(state.progress!.overall * 100).toStringAsFixed(0)}%',
                style: t.textTheme.bodySmall?.copyWith(fontFeatures: tabular, color: t.colorScheme.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }
}

class _StageRow extends StatelessWidget {
  final int index;
  final String label;
  final ProgressEvent? event;
  final bool active;
  const _StageRow({required this.index, required this.label, required this.event, required this.active});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = event?.fraction;
    final done = f == 1.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('0$index', style: t.textTheme.labelSmall?.copyWith(color: StructuraColors.accent, fontFeatures: tabular)),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(label, style: t.textTheme.bodyMedium)),
        if (done) const Icon(Icons.check_rounded, size: 16, color: StructuraColors.success),
        if (event?.message != null && !done)
          Text(event!.message!, style: t.textTheme.bodySmall?.copyWith(fontFeatures: tabular, color: t.colorScheme.onSurfaceVariant)),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          minHeight: 3,
          value: event == null ? 0 : (active && f == 0 ? null : f),
          color: done ? StructuraColors.success : StructuraColors.accent,
          backgroundColor: t.colorScheme.outlineVariant,
        ),
      ),
    ]);
  }
}

class _ResultCard extends StatelessWidget {
  final AnalysisRecord a;
  const _ResultCard(this.a);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (a.isTestModel) ...[
            NoticeBanner('${a.model['trust_label']}. Los resultados sirven para validar el flujo técnico, no para trabajar con planos reales.',
                icon: Icons.science_outlined),
            const SizedBox(height: Gap.md),
          ],
          Wrap(spacing: Gap.lg, runSpacing: Gap.md, children: [
            for (final k in ['wall', 'door', 'window', 'column', 'stairs'])
              _Metric(label: StructuraColors.classLabels[k]!, value: '${a.counts[k] ?? 0}', color: StructuraColors.byClass[k]!),
          ]),
          const SizedBox(height: Gap.md),
          Text('Tiempos: ${a.timings.map((e) => '${e['stage']} ${e['ms']} ms').join(' · ')}',
              style: t.textTheme.bodySmall?.copyWith(fontFeatures: tabular, color: t.colorScheme.onSurfaceVariant)),
          if (a.warnings.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text('Advertencias (${a.warnings.length})', style: t.textTheme.titleSmall),
            for (final w in a.warnings.take(8))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('• $w', style: t.textTheme.bodySmall?.copyWith(color: StructuraColors.warning)),
              ),
          ],
        ]),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Metric({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label.toUpperCase(), style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
      Text(value, style: t.textTheme.headlineSmall?.copyWith(fontFeatures: tabular)),
    ]);
  }
}
