import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/flows.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../data/project_models.dart';
import '../../widgets/common.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsProvider);
    final t = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1200 ? 3 : (width >= 700 ? 2 : 1);
    final cardExtent = 104 * MediaQuery.textScalerOf(context).scale(14) / 14;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () => ref.refresh(projectsProvider.future),
        child: CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 0),
            sliver: SliverToBoxAdapter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('STRUCTURA AI', style: t.textTheme.labelSmall?.copyWith(color: StructuraColors.accent)),
                const SizedBox(height: Gap.md),
                _Hero(
                  onCamera: () => quickStart(context, ref, QuickSource.camera),
                  onGallery: () => quickStart(context, ref, QuickSource.gallery),
                  onFile: () => quickStart(context, ref, QuickSource.file),
                ),
                SectionLabel(
                  'Proyectos',
                  trailing: TextButton.icon(
                    key: const Key('new_project'),
                    onPressed: () => context.push(Routes.newProject),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Nuevo proyecto'),
                  ),
                ),
              ]),
            ),
          ),
          ...projects.when(
            loading: () => [
              const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))),
            ],
            error: (e, _) => [
              SliverToBoxAdapter(
                  child: Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: NoticeBanner('No se pudieron leer los proyectos: $e', color: StructuraColors.danger))),
            ],
            data: (list) {
              final issues = ref.read(projectStoreProvider).lastIssues;
              return [
                if (issues.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
                    sliver: SliverToBoxAdapter(
                      child: NoticeBanner(
                          '${issues.length} carpeta(s) de proyecto no se pudieron abrir (archivo dañado o de una versión más nueva).',
                          color: StructuraColors.warning),
                    ),
                  ),
                if (list.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xl),
                      child: Column(children: [
                        Icon(Icons.architecture_rounded, size: 32, color: t.colorScheme.onSurfaceVariant),
                        const SizedBox(height: Gap.sm),
                        Text('Todavía no hay proyectos', style: t.textTheme.titleSmall),
                        Text('Fotografiá un plano y en segundos vas a ver su modelo 3D.',
                            textAlign: TextAlign.center,
                            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                      ]),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns, mainAxisSpacing: Gap.sm, crossAxisSpacing: Gap.sm, mainAxisExtent: cardExtent),
                      delegate: SliverChildBuilderDelegate((context, i) => _ProjectCard(list[i]), childCount: list.length),
                    ),
                  ),
              ];
            },
          ),
        ]),
      ),
    );
  }
}

/// Acción principal de la app: una foto → modelo 3D.
class _Hero extends StatelessWidget {
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onFile;
  const _Hero({required this.onCamera, required this.onGallery, required this.onFile});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    const deep = Color(0xFF1546B8);
    final outlined = OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: const BorderSide(color: Color(0x80FFFFFF)),
      minimumSize: const Size(0, 44),
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [StructuraColors.accent, deep]),
        boxShadow: [BoxShadow(color: StructuraColors.accent.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: Stack(children: [
        const Positioned.fill(child: Opacity(opacity: 0.18, child: _HeroGrid())),
        Positioned(
          right: -18,
          top: -10,
          child: Icon(Icons.view_in_ar_rounded, size: 150, color: Colors.white.withValues(alpha: 0.12)),
        ),
        Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('De una foto\na un modelo 3D',
                style: t.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w600, height: 1.15)),
            const SizedBox(height: Gap.sm),
            Text('Muros, aberturas y evaluación preliminar de sismo, tsunami y viento. En el teléfono, sin conexión.',
                style: t.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85))),
            const SizedBox(height: Gap.lg),
            FilledButton.icon(
              key: const Key('quick_camera'),
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: deep, minimumSize: const Size(0, 52)),
              onPressed: onCamera,
              icon: const Icon(Icons.photo_camera_rounded),
              label: const Text('Fotografiar plano'),
            ),
            const SizedBox(height: Gap.sm),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                    key: const Key('quick_gallery'),
                    style: outlined,
                    onPressed: onGallery,
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('Galería')),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: OutlinedButton.icon(
                    key: const Key('quick_file'),
                    style: outlined,
                    onPressed: onFile,
                    icon: const Icon(Icons.upload_file_outlined, size: 18),
                    label: const Text('PDF o imagen')),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _HeroGrid extends StatelessWidget {
  const _HeroGrid();
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _HeroGridPainter());
}

class _HeroGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 0.6;
    for (double x = 0; x < size.width; x += 22) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y < size.height; y += 22) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_HeroGridPainter oldDelegate) => false;
}

Color statusColor(ProjectStatus s) => switch (s) {
      ProjectStatus.draft => StructuraColors.textMuted,
      ProjectStatus.planImported => StructuraColors.accent,
      ProjectStatus.analyzed => StructuraColors.success,
      ProjectStatus.failed => StructuraColors.danger,
    };

class _ProjectCard extends ConsumerWidget {
  final ProjectManifest p;
  const _ProjectCard(this.p);
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final plan = p.activePlan;
    final store = ref.watch(projectStoreProvider);
    final running = ref.watch(analysisControllerProvider(p.id).select((s) => s.phase == AnalysisPhase.running));
    final a = p.activeAnalysis;
    final summary = a == null
        ? (plan == null ? 'Sin plano' : 'Plano importado')
        : [
            for (final k in ['wall', 'door', 'window'])
              if ((a.counts[k] ?? 0) > 0) StructuraColors.count(k, a.counts[k]!),
          ].join(' · ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.project(p.id)),
        child: Padding(
          padding: const EdgeInsets.all(Gap.sm),
          child: Row(children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  color: plan == null ? t.colorScheme.surfaceContainerHigh : Colors.white,
                  child: plan == null
                      ? Icon(Icons.crop_free_rounded, color: t.colorScheme.onSurfaceVariant)
                      : Image.file(File(store.resolve(p.id, plan.rasterFile).path),
                          fit: BoxFit.cover, cacheWidth: 256, errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined)),
                ),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text('${formatDate(p.updatedAt)} · $summary',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant, fontFeatures: tabular)),
                const SizedBox(height: Gap.sm),
                running
                    ? const StatusPill('PROCESANDO', color: StructuraColors.teal, icon: Icons.sync_rounded)
                    : StatusPill(p.status.label.toUpperCase(), color: statusColor(p.status)),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: t.colorScheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}
