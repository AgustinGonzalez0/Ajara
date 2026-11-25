import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:structura_geometry/structura_geometry.dart';

import '../../app/flows.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../data/project_models.dart';
import '../../widgets/common.dart';
import '../model3d/mini_model_view.dart';
import '../model3d/model_screen.dart' show Model3dData, model3dProvider;

/// Panel del proyecto: todo a la vista en una pantalla, con la acción siguiente fija abajo.
///
///   sin plano      → Fotografiar plano
///   plano          → Generar modelo 3D (motor clásico, sin IA)
///   procesando     → progreso sobre el plano
///   modelo listo   → 3D girando + Evaluar sismo, tsunami y viento
///   evaluado       → Compartir informe PDF
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
      data: (p) => _Hub(p),
    );
  }
}

class _Hub extends ConsumerStatefulWidget {
  final ProjectManifest p;
  const _Hub(this.p);
  @override
  ConsumerState<_Hub> createState() => _HubState();
}

class _HubState extends ConsumerState<_Hub> {
  bool _showPlan = false;
  bool _exporting = false;
  bool _exportingDxf = false;

  ProjectManifest get p => widget.p;

  Future<void> _rename() async {
    final c = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nombre del proyecto'),
        content: TextField(
          key: const Key('rename_field'),
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Ej.: Vivienda Martínez'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(key: const Key('rename_save'), onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Guardar')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty && name.trim() != p.name) {
      await ref.read(projectsProvider.notifier).rename(p.id, name);
    }
  }

  Future<void> _delete() async {
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
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(projectsProvider.notifier).delete(p.id);
      if (mounted) context.go(Routes.home);
    }
  }

  Future<void> _showHistory() async {
    final items = await ref.read(projectStoreProvider).history(p.id);
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          for (final h in items.reversed) ListTile(dense: true, title: Text('${h['action']}'), subtitle: Text('${h['ts']}')),
        ],
      ),
    );
  }

  Future<void> _shareDxf() async {
    setState(() => _exportingDxf = true);
    try {
      final meters = await exportAndShareDxf(ref, p.id);
      if (!meters && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('El DXF quedó en píxeles: marcá una medida en Cómputo o Evaluación para tenerlo en metros.')));
      }
    } on Object catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo exportar el DXF: $e')));
    } finally {
      if (mounted) setState(() => _exportingDxf = false);
    }
  }

  Future<void> _sharePdf() async {
    setState(() => _exporting = true);
    try {
      await exportAndShareReport(ref, p.id);
    } on Object catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo generar el informe: $e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final plan = p.activePlan;
    final analysis = p.activeAnalysis;
    final state = ref.watch(analysisControllerProvider(p.id));
    final running = state.phase == AnalysisPhase.running;
    final data = analysis == null ? null : ref.watch(model3dProvider(p.id)).value;
    final report = data?.report;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final height = MediaQuery.sizeOf(context).height;

    final preview = _Preview(
      project: p,
      state: state,
      data: data,
      showPlan: _showPlan,
      onToggle: analysis == null ? null : (v) => setState(() => _showPlan = v),
    );
    final info = _InfoStrip(p: p, running: running, failed: state.phase == AnalysisPhase.failed ? state.message : null);
    final tiles = _Tiles(
      p: p,
      report: report,
      exporting: _exporting,
      exportingDxf: _exportingDxf,
      onEvaluate: () => openEvaluation(context, ref, p.id),
      onTakeoff: () => openTakeoff(context, ref, p.id),
      onPdf: _sharePdf,
      onDxf: _shareDxf,
    );

    final menu = PopupMenuButton<String>(
      key: const Key('project_menu'),
      onSelected: (v) {
        switch (v) {
          case 'rename':
            _rename();
          case 'photo':
            context.push(Routes.photo(p.id));
          case 'file':
            context.push(Routes.import(p.id, auto: true));
          case 'engine':
            context.push(Routes.analysis(p.id));
          case 'history':
            _showHistory();
          case 'delete':
            _delete();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Renombrar')),
        ),
        const PopupMenuItem(
          value: 'photo',
          child: ListTile(leading: Icon(Icons.photo_camera_outlined), title: Text('Nueva foto del plano')),
        ),
        const PopupMenuItem(
          value: 'file',
          child: ListTile(leading: Icon(Icons.upload_file_outlined), title: Text('Plano desde archivo')),
        ),
        if (plan != null)
          const PopupMenuItem(
            value: 'engine',
            child: ListTile(leading: Icon(Icons.tune_rounded), title: Text('Motor de análisis')),
          ),
        const PopupMenuItem(
          value: 'history',
          child: ListTile(leading: Icon(Icons.history_rounded), title: Text('Historial')),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline, color: StructuraColors.danger),
            title: Text('Eliminar'),
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          key: const Key('project_title'),
          borderRadius: BorderRadius.circular(8),
          onTap: _rename,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 6),
                Icon(Icons.edit_outlined, size: 16, color: t.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
        actions: [menu],
      ),
      body: SafeArea(
        bottom: false,
        child: wide
            ? Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xl),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: preview),
                    const SizedBox(width: Gap.xl),
                    SizedBox(
                      width: 380,
                      child: ListView(
                        children: [
                          info,
                          const SizedBox(height: Gap.lg),
                          tiles,
                        ],
                      ),
                    ),
                  ],
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
                children: [
                  SizedBox(height: (height * 0.40).clamp(220.0, 460.0), child: preview),
                  const SizedBox(height: Gap.md),
                  info,
                  const SizedBox(height: Gap.md),
                  tiles,
                ],
              ),
      ),
      bottomNavigationBar: _primaryAction(context, plan: plan, analysis: analysis, state: state, report: report),
    );
  }

  Widget _primaryAction(
    BuildContext context, {
    PlanSource? plan,
    AnalysisRecord? analysis,
    required AnalysisState state,
    Map<String, Object?>? report,
  }) {
    if (state.phase == AnalysisPhase.running) {
      final pct = ((state.progress?.overall ?? 0) * 100).round();
      return ActionBar(
        children: [
          Expanded(
            child: FilledButton.icon(
              key: const Key('primary_action'),
              onPressed: null,
              icon: const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              label: Text('Generando modelo 3D… $pct %'),
            ),
          ),
          TextButton(
            onPressed: () => ref.read(analysisControllerProvider(p.id).notifier).cancel(),
            child: const Text('Cancelar'),
          ),
        ],
      );
    }
    final failed = state.phase == AnalysisPhase.failed && analysis == null;
    final (IconData icon, String label, VoidCallback onTap) = switch ((plan, analysis, report)) {
      (null, _, _) => (Icons.photo_camera_rounded, 'Fotografiar plano', () => context.push(Routes.photo(p.id))),
      (_, null, _) => (
        failed ? Icons.refresh_rounded : Icons.view_in_ar_rounded,
        failed ? 'Reintentar' : 'Generar modelo 3D',
        () => startDefaultAnalysis(ref, p.id),
      ),
      (_, _, null) => (Icons.analytics_rounded, 'Evaluar sismo, tsunami y viento', () => openEvaluation(context, ref, p.id)),
      _ => (Icons.ios_share_rounded, 'Compartir informe PDF', _sharePdf),
    };
    return ActionBar(
      children: [
        Expanded(
          child: FilledButton.icon(
            key: const Key('primary_action'),
            onPressed: _exporting ? null : onTap,
            icon: _exporting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(icon),
            label: Text(label, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _Preview extends ConsumerWidget {
  final ProjectManifest project;
  final AnalysisState state;
  final Model3dData? data;
  final bool showPlan;
  final ValueChanged<bool>? onToggle;
  const _Preview({required this.project, required this.state, required this.data, required this.showPlan, this.onToggle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final store = ref.watch(projectStoreProvider);
    final plan = project.activePlan;
    final running = state.phase == AnalysisPhase.running;
    final dark = t.brightness == Brightness.dark;

    Widget planImage() => Container(
      color: Colors.white,
      child: Image.file(
        File(store.resolve(project.id, plan!.rasterFile).path),
        fit: BoxFit.contain,
        cacheWidth: 1400,
        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
      ),
    );

    final Widget body;
    if (plan == null) {
      body = BlueprintGrid(child: _EmptyPlan(projectId: project.id));
    } else if (running) {
      body = Stack(fit: StackFit.expand, children: [planImage(), _ProgressOverlay(state)]);
    } else if (data != null && !showPlan) {
      body = Stack(
        fit: StackFit.expand,
        children: [
          Container(color: dark ? StructuraColors.ink : const Color(0xFFEFF2F6)),
          MiniModelView(
            key: const Key('mini_3d'),
            mesh: const MeshBuilder().build(data!.model),
            onOpen: () => context.push(Routes.model3d(project.id)),
          ),
          Positioned(
            left: Gap.md,
            bottom: Gap.md,
            child: IgnorePointer(
              child: GlassPanel(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.touch_app_outlined, size: 14),
                    const SizedBox(width: 6),
                    Text('Tocá para abrir · arrastrá para girar', style: t.textTheme.labelSmall?.copyWith(letterSpacing: 0.2)),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      body = GestureDetector(
        onTap: project.activeAnalysis == null ? null : () => context.push(Routes.editor(project.id)),
        child: planImage(),
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(18)),
      foregroundDecoration: BoxDecoration(
        border: Border.all(color: t.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          body,
          if (onToggle != null && !running)
            Positioned(
              top: Gap.sm,
              right: Gap.sm,
              child: SegmentedButton<bool>(
                key: const Key('preview_toggle'),
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: t.colorScheme.surfaceContainer.withValues(alpha: 0.92),
                ),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('3D'), icon: Icon(Icons.view_in_ar_rounded, size: 16)),
                  ButtonSegment(value: true, label: Text('Plano'), icon: Icon(Icons.description_outlined, size: 16)),
                ],
                selected: {showPlan},
                onSelectionChanged: (s) => onToggle!(s.first),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyPlan extends StatelessWidget {
  final String projectId;
  const _EmptyPlan({required this.projectId});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_a_photo_outlined, size: 40, color: StructuraColors.accent.withValues(alpha: 0.9)),
            const SizedBox(height: Gap.md),
            Text('Sumá el plano', style: t.textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(
              'Una foto de frente alcanza: la perspectiva se corrige sola.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Gap.lg),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const Key('empty_gallery'),
                  onPressed: () => context.push(Routes.photo(projectId, camera: false)),
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('Galería'),
                ),
                OutlinedButton.icon(
                  key: const Key('empty_file'),
                  onPressed: () => context.push(Routes.import(projectId, auto: true)),
                  icon: const Icon(Icons.upload_file_outlined, size: 18),
                  label: const Text('PDF o imagen'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Progreso del análisis sobre el plano: barrido animado + etapa + porcentaje.
class _ProgressOverlay extends StatefulWidget {
  final AnalysisState state;
  const _ProgressOverlay(this.state);
  @override
  State<_ProgressOverlay> createState() => _ProgressOverlayState();
}

class _ProgressOverlayState extends State<_ProgressOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _scan = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _scan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = widget.state.progress;
    final pct = p?.overall ?? 0;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: StructuraColors.ink.withValues(alpha: 0.35)),
        AnimatedBuilder(
          animation: _scan,
          builder: (context, _) => CustomPaint(painter: _ScanPainter(Curves.easeInOut.transform(_scan.value))),
        ),
        Positioned(
          left: Gap.md,
          right: Gap.md,
          bottom: Gap.md,
          child: GlassPanel(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        p?.stageLabel ?? 'Preparando…',
                        key: const Key('progress_stage'),
                        style: t.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text('${(pct * 100).round()} %', style: t.textTheme.titleSmall?.copyWith(fontFeatures: tabular)),
                  ],
                ),
                const SizedBox(height: Gap.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: pct > 0 ? pct : null, minHeight: 5),
                ),
                const SizedBox(height: 6),
                Text(
                  'En el teléfono, sin conexión',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ScanPainter extends CustomPainter {
  final double v;
  _ScanPainter(this.v);
  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * v;
    final rect = Rect.fromLTWH(0, y - 40, size.width, 40);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [StructuraColors.accent.withValues(alpha: 0), StructuraColors.accent.withValues(alpha: 0.35)],
        ).createShader(rect),
    );
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = StructuraColors.accent
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_ScanPainter o) => o.v != v;
}

class _InfoStrip extends StatelessWidget {
  final ProjectManifest p;
  final bool running;
  final String? failed;
  const _InfoStrip({required this.p, required this.running, this.failed});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final a = p.activeAnalysis;
    final plan = p.activePlan;
    final chips = <Widget>[];
    if (a != null) {
      final classic = a.model['engine'] == 'classic';
      chips.add(
        InkWell(
          key: const Key('engine_chip'),
          borderRadius: BorderRadius.circular(6),
          onTap: () => context.push(Routes.analysis(p.id)),
          child: StatusPill(classic ? 'MOTOR CLÁSICO · SIN IA  ›' : 'VISION AI  ›', color: StructuraColors.teal, icon: Icons.bolt_rounded),
        ),
      );
      for (final k in ['wall', 'door', 'window', 'column', 'stairs']) {
        final n = a.counts[k] ?? 0;
        if (n == 0) continue;
        chips.add(_CountChip(StructuraColors.byClass[k]!, StructuraColors.count(k, n)));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (failed != null) ...[
          NoticeBanner('El análisis falló: $failed', color: StructuraColors.danger, icon: Icons.error_outline),
          const SizedBox(height: Gap.sm),
        ],
        if (chips.isNotEmpty) Wrap(spacing: 6, runSpacing: 6, children: chips),
      if (a != null && a.refinementSummary.isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.auto_fix_high_rounded, size: 16, color: StructuraColors.teal),
          const SizedBox(width: 6),
          Expanded(
            child: Text('Modelo afinado: ${a.refinementSummary.join(' · ')}',
                key: const Key('refinement_summary'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
        ]),
      ],
        if (a == null && plan != null && !running)
          Text(
            'Plano listo · ${plan.width}×${plan.height} px. El modelo 3D se genera en segundos, sin conexión.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant, fontFeatures: tabular),
          ),
        if (a != null && a.isTestModel && a.model['engine'] != 'classic') ...[
          const SizedBox(height: Gap.sm),
          const StatusPill(
            'IA EN VALIDACIÓN · REVISÁ LAS DETECCIONES',
            color: StructuraColors.warning,
            icon: Icons.science_outlined,
          ),
        ],
      ],
    );
  }
}

class _CountChip extends StatelessWidget {
  final Color color;
  final String label;
  const _CountChip(this.color, this.label);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: t.textTheme.labelMedium?.copyWith(fontFeatures: tabular)),
        ],
      ),
    );
  }
}

class _Tiles extends StatelessWidget {
  final ProjectManifest p;
  final Map<String, Object?>? report;
  final bool exporting;
  final bool exportingDxf;
  final VoidCallback onEvaluate;
  final VoidCallback onTakeoff;
  final VoidCallback onPdf;
  final VoidCallback onDxf;
  const _Tiles(
      {required this.p,
      required this.report,
      required this.exporting,
      required this.exportingDxf,
      required this.onEvaluate,
      required this.onTakeoff,
      required this.onPdf,
      required this.onDxf});

  @override
  Widget build(BuildContext context) {
    final ready = p.activeAnalysis != null;
    final r = report;
    final tiles = [
      QuickTile(
        key: const Key('tile_3d'),
        icon: Icons.view_in_ar_rounded,
        title: 'Modelo 3D',
        subtitle: ready ? 'Ver · GLB' : 'Se genera del plano',
        onTap: ready ? () => context.push(Routes.model3d(p.id)) : null,
      ),
      QuickTile(
        key: const Key('tile_plan'),
        icon: Icons.layers_outlined,
        title: 'Plano',
        subtitle: ready ? 'Detecciones' : (p.activePlan == null ? 'Sin plano' : 'Ver plano'),
        accent: StructuraColors.teal,
        onTap: p.activePlan == null ? null : () => context.push(Routes.editor(p.id)),
      ),
      QuickTile(
        key: const Key('tile_eval'),
        icon: Icons.analytics_outlined,
        title: 'Evaluación',
        subtitle: r == null ? 'Sismo · tsunami · viento' : _evalSummary(r),
        accent: r == null ? StructuraColors.accent : _worstColor(r),
        onTap: ready ? onEvaluate : null,
      ),
      QuickTile(
        key: const Key('tile_takeoff'),
        icon: Icons.square_foot_rounded,
        title: 'Cómputo',
        subtitle: ready ? 'm² y ambientes' : 'Después del modelo',
        accent: StructuraColors.success,
        onTap: ready ? onTakeoff : null,
      ),
      QuickTile(
        key: const Key('tile_dxf'),
        icon: Icons.architecture_rounded,
        title: 'Plano DXF',
        subtitle: ready ? 'Para AutoCAD' : 'Después del modelo',
        accent: StructuraColors.stairs,
        busy: exportingDxf,
        onTap: ready ? onDxf : null,
      ),
      QuickTile(
        key: const Key('tile_pdf'),
        icon: Icons.picture_as_pdf_outlined,
        title: 'Informe PDF',
        subtitle: r == null ? 'Después de evaluar' : 'Compartir',
        accent: StructuraColors.warning,
        busy: exporting,
        onTap: r == null ? null : onPdf,
      ),
    ];
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (context, c) {
        // 6 accesos en 3 columnas compactas: todo el panel entra sin scroll en un teléfono.
        final cols = c.maxWidth >= 560 ? 2 : 3;
        final w = (c.maxWidth - Gap.sm * (cols - 1)) / cols;
        return Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.sm,
          children: [
            for (final tile in tiles)
              SizedBox(
                width: w,
                height: (cols == 3 ? 92 : 78) * scale,
                child: cols == 3
                    ? QuickTile(
                        key: tile.key,
                        icon: tile.icon,
                        title: tile.title,
                        subtitle: tile.subtitle,
                        accent: tile.accent,
                        busy: tile.busy,
                        onTap: tile.onTap,
                        compact: true)
                    : tile,
              ),
          ],
        );
      },
    );
  }

  static const _short = {'ok': 'OK', 'attention': 'revisar', 'critical': 'supera', 'notApplicable': '—'};
  static const _names = {'seismic': 'Sismo', 'tsunami': 'Tsunami', 'wind': 'Viento'};

  /// Lo más importante primero (entra en una línea del acceso compacto): el peligro peor.
  String _evalSummary(Map<String, Object?> r) {
    final hs = (r['results'] as List).cast<Map>().toList();
    for (final level in ['critical', 'attention']) {
      final bad = hs.where((h) => h['overall'] == level).map((h) => _names[h['hazard']]).toList();
      if (bad.isNotEmpty) return '${bad.join(' y ')} ${_short[level]}';
    }
    return '${hs.map((h) => _names[h['hazard']]).join(' · ')} OK';
  }

  Color _worstColor(Map<String, Object?> r) {
    final s = (r['results'] as List).cast<Map>().map((h) => h['overall']).toSet();
    if (s.contains('critical')) return StructuraColors.danger;
    if (s.contains('attention')) return StructuraColors.warning;
    return StructuraColors.success;
  }
}
