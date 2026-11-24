import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
    // Altura de tarjeta proporcional al escalado de texto (accesibilidad).
    final cardExtent = 152 * MediaQuery.textScalerOf(context).scale(14) / 14;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () => ref.refresh(projectsProvider.future),
        child: CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xl, Gap.xl, 0),
            sliver: SliverToBoxAdapter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('STRUCTURA AI', style: t.textTheme.labelSmall?.copyWith(color: StructuraColors.accent)),
                const SizedBox(height: Gap.xs),
                Text('Proyectos', style: t.textTheme.displaySmall),
                const SizedBox(height: Gap.xl),
                Wrap(spacing: Gap.md, runSpacing: Gap.md, children: [
                  _ActionTile(
                    icon: Icons.add_rounded,
                    title: 'Nuevo proyecto',
                    subtitle: 'Crear y configurar',
                    primary: true,
                    onTap: () => context.push(Routes.newProject),
                  ),
                  _ActionTile(
                    icon: Icons.photo_camera_rounded,
                    title: 'Foto de un plano',
                    subtitle: 'Una foto → modelo 3D',
                    onTap: () => context.push('${Routes.newProject}?photo=1'),
                  ),
                  _ActionTile(
                    icon: Icons.upload_file_rounded,
                    title: 'Importar plano',
                    subtitle: 'PDF · PNG · JPG · TIFF',
                    onTap: () => context.push('${Routes.newProject}?import=1'),
                  ),
                ]),
              ]),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
            sliver: SliverToBoxAdapter(
              child: SectionLabel('Recientes',
                  trailing: projects.whenOrNull(
                      data: (l) => Text('${l.length}', style: t.textTheme.labelMedium?.copyWith(fontFeatures: tabular)))),
            ),
          ),
          ...projects.when(
            loading: () => [const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())))],
            error: (e, _) => [SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(Gap.xl), child: NoticeBanner('No se pudieron leer los proyectos: $e', color: StructuraColors.danger)))],
            data: (list) {
              final issues = ref.read(projectStoreProvider).lastIssues;
              return [
                if (issues.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.md),
                    sliver: SliverToBoxAdapter(
                      child: NoticeBanner('${issues.length} carpeta(s) de proyecto no se pudieron abrir (archivo dañado o de una versión más nueva).',
                          color: StructuraColors.warning),
                    ),
                  ),
                if (list.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.architecture_rounded,
                      title: 'Todavía no hay proyectos',
                      message: 'Creá un proyecto e importá un plano para empezar.',
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xxl),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns, mainAxisSpacing: Gap.md, crossAxisSpacing: Gap.md, mainAxisExtent: cardExtent),
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

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool primary;
  final VoidCallback onTap;
  const _ActionTile({required this.icon, required this.title, required this.subtitle, required this.onTap, this.primary = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox(
      width: 220,
      child: Material(
        color: primary ? StructuraColors.accent : t.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Row(children: [
              Icon(icon, color: primary ? Colors.white : StructuraColors.accent),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: t.textTheme.titleSmall?.copyWith(color: primary ? Colors.white : null)),
                  Text(subtitle,
                      style: t.textTheme.bodySmall?.copyWith(color: primary ? Colors.white70 : t.colorScheme.onSurfaceVariant)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
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
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.project(p.id)),
        child: Row(children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              color: t.colorScheme.surfaceContainerLowest,
              child: plan == null
                  ? Icon(Icons.crop_free_rounded, color: t.colorScheme.onSurfaceVariant)
                  : Image.file(File(store.resolve(p.id, plan.rasterFile).path),
                      fit: BoxFit.cover, cacheWidth: 256, errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined)),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text('${p.buildingType.label} · ${formatDate(p.updatedAt)}',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant, fontFeatures: tabular)),
                const SizedBox(height: Gap.sm),
                running
                    ? const StatusPill('PROCESANDO', color: StructuraColors.teal, icon: Icons.sync_rounded)
                    : StatusPill(p.status.label.toUpperCase(), color: statusColor(p.status)),
              ]),
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
        ]),
      ),
    );
  }
}
