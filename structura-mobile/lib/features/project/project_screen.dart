import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../data/project_models.dart';
import '../../widgets/common.dart';
import '../dashboard/dashboard_screen.dart' show statusColor;

/// Centro del proyecto: flujo Plano → Análisis → Detecciones → Modelo 3D.
class ProjectScreen extends ConsumerWidget {
  final String projectId;
  const ProjectScreen({super.key, required this.projectId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(projectProvider(projectId));
    return async.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: EmptyState(icon: Icons.error_outline, title: 'No se pudo abrir el proyecto', message: '$e'),
      ),
      data: (p) => _ProjectView(p),
    );
  }
}

class _ProjectView extends ConsumerWidget {
  final ProjectManifest p;
  const _ProjectView(this.p);

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Eliminar proyecto'),
        content: Text('Se eliminarán "${p.name}", sus planos y resultados de este dispositivo. No se puede deshacer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: StructuraColors.danger),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await ref.read(projectsProvider.notifier).delete(p.id);
      if (context.mounted) context.go(Routes.home);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final store = ref.watch(projectStoreProvider);
    final plan = p.activePlan;
    final analysis = p.activeAnalysis;
    final running = ref.watch(analysisControllerProvider(p.id)).phase == AnalysisPhase.running;
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final steps = [
      _Step(
        n: 1,
        icon: Icons.description_outlined,
        title: 'Plano',
        detail: plan == null
            ? 'Importá un PDF, PNG, JPG o TIFF.'
            : '${plan.originalName}${plan.page != null ? ' · pág. ${plan.page}' : ''} · ${plan.width}×${plan.height} px'
                '${plan.dpi != null ? ' · ${plan.dpi!.toStringAsFixed(0)} DPI' : ''}',
        done: plan != null,
        actionLabel: plan == null ? 'Importar plano' : 'Reemplazar',
        onAction: () => context.push(Routes.import(p.id)),
        thirdLabel: 'Foto',
        onThird: () => context.push(Routes.photo(p.id)),
        secondaryLabel: plan == null ? null : 'Ver plano',
        onSecondary: () => context.push(Routes.editor(p.id)),
      ),
      _Step(
        n: 2,
        icon: Icons.auto_awesome_mosaic_outlined,
        title: 'Análisis IA',
        detail: running
            ? 'Procesando…'
            : analysis == null
                ? 'Segmentación local con Vision AI.'
                : '${formatDate(analysis.createdAt)} · ${analysis.counts.entries.map((e) => '${e.value} ${StructuraColors.classLabels[e.key]?.toLowerCase() ?? e.key}').join(' · ')}',
        done: analysis != null,
        enabled: plan != null,
        actionLabel: analysis == null ? 'Analizar' : 'Ver análisis',
        onAction: () => context.push(Routes.analysis(p.id)),
        warning: analysis?.isTestModel == true ? 'Resultado no validado con planos reales' : null,
      ),
      _Step(
        n: 3,
        icon: Icons.layers_outlined,
        title: 'Revisar detecciones',
        detail: 'Capas de segmentación y vectores sobre el plano. La corrección manual está pendiente.',
        done: false,
        enabled: analysis != null,
        actionLabel: 'Abrir editor 2D',
        onAction: () => context.push(Routes.editor(p.id)),
      ),
      _Step(
        n: 4,
        icon: Icons.view_in_ar_outlined,
        title: 'Modelo 3D',
        detail: 'Generado por el Geometry Engine a partir del Building Model.',
        done: analysis != null,
        enabled: analysis != null,
        actionLabel: 'Ver modelo 3D',
        onAction: () => context.push(Routes.model3d(p.id)),
      ),
      _Step(
        n: 5,
        icon: Icons.analytics_outlined,
        title: 'Evaluación preliminar',
        detail: 'Sismo, tsunami y viento: indicadores de demanda/capacidad y simulación 3D. '
            'Requiere calibrar la escala con una medida real.',
        done: false,
        enabled: analysis != null,
        actionLabel: 'Evaluar',
        onAction: () => context.push(Routes.simulate(p.id)),
      ),
    ];

    final header = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: Gap.sm, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
        StatusPill(p.status.label.toUpperCase(), color: statusColor(p.status)),
        Text(p.buildingType.label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
      const SizedBox(height: Gap.sm),
      Text(p.name, style: t.textTheme.headlineSmall),
      if (p.description.isNotEmpty) ...[
        const SizedBox(height: Gap.xs),
        Text(p.description, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ],
    ]);

    final preview = plan == null
        ? null
        : ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              color: Colors.white,
              child: Image.file(File(store.resolve(p.id, plan.rasterFile).path), fit: BoxFit.contain, cacheWidth: 1200),
            ),
          );

    final stepList = Column(children: [for (final s in steps) Padding(padding: const EdgeInsets.only(bottom: Gap.md), child: s)]);

    return Scaffold(
      appBar: AppBar(
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'delete') _delete(context, ref);
              if (v == 'history') _showHistory(context, ref);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'history', child: Text('Historial de cambios')),
              PopupMenuItem(value: 'delete', child: Text('Eliminar proyecto')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: wide
            ? Padding(
                padding: const EdgeInsets.all(Gap.xl),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 5, child: ListView(children: [header, const SizedBox(height: Gap.xl), stepList])),
                  const SizedBox(width: Gap.xl),
                  if (preview != null) Expanded(flex: 6, child: preview),
                ]),
              )
            : ListView(padding: const EdgeInsets.all(Gap.xl), children: [
                header,
                if (preview != null) ...[const SizedBox(height: Gap.lg), SizedBox(height: 200, child: preview)],
                const SizedBox(height: Gap.xl),
                stepList,
              ]),
      ),
    );
  }

  Future<void> _showHistory(BuildContext context, WidgetRef ref) async {
    final items = await ref.read(projectStoreProvider).history(p.id);
    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        for (final h in items.reversed)
          ListTile(
            dense: true,
            title: Text('${h['action']}'),
            subtitle: Text('${h['ts']}'),
          ),
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  final int n;
  final IconData icon;
  final String title;
  final String detail;
  final bool done;
  final bool enabled;
  final String actionLabel;
  final VoidCallback onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final String? thirdLabel;
  final VoidCallback? onThird;
  final String? warning;
  const _Step({
    required this.n,
    required this.icon,
    required this.title,
    required this.detail,
    required this.done,
    required this.actionLabel,
    required this.onAction,
    this.enabled = true,
    this.secondaryLabel,
    this.onSecondary,
    this.thirdLabel,
    this.onThird,
    this.warning,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = done ? StructuraColors.success : (enabled ? StructuraColors.accent : t.colorScheme.outline);
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 1.5)),
              child: Center(
                child: done
                    ? Icon(Icons.check_rounded, size: 18, color: color)
                    : Text('$n', style: TextStyle(color: color, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(icon, size: 16, color: t.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Flexible(child: Text(title, style: t.textTheme.titleMedium, overflow: TextOverflow.ellipsis)),
                ]),
                const SizedBox(height: 4),
                Text(detail, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant, fontFeatures: tabular)),
                if (warning != null) ...[
                  const SizedBox(height: Gap.sm),
                  StatusPill(warning!.toUpperCase(), color: StructuraColors.warning, icon: Icons.science_outlined),
                ],
                const SizedBox(height: Gap.md),
                Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                  FilledButton.tonal(onPressed: enabled ? onAction : null, child: Text(actionLabel)),
                  if (thirdLabel != null)
                    TextButton.icon(
                        onPressed: enabled ? onThird : null, icon: const Icon(Icons.photo_camera_outlined, size: 18), label: Text(thirdLabel!)),
                  if (secondaryLabel != null) TextButton(onPressed: enabled ? onSecondary : null, child: Text(secondaryLabel!)),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
