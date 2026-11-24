import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Etiqueta de sección en mayúsculas con espaciado técnico.
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm, top: Gap.lg),
      child: Row(children: [
        Expanded(
          child: Text(text.toUpperCase(),
              overflow: TextOverflow.ellipsis, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
        ?trailing,
      ]),
    );
  }
}

/// Píldora de estado.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  const StatusPill(this.label, {super.key, required this.color, this.icon});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
          ),
        ]),
      );
}

/// Aviso de función todavía no implementada. Nunca se simula su resultado.
class PendingFeature extends StatelessWidget {
  final String title;
  final String detail;
  const PendingFeature({super.key, required this.title, required this.detail});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.colorScheme.outline, style: BorderStyle.solid),
        color: t.colorScheme.surfaceContainerLow,
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.schedule_rounded, size: 18, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(title, style: t.textTheme.titleSmall)),
              const SizedBox(width: Gap.sm),
              const StatusPill('PENDIENTE', color: StructuraColors.textMuted),
            ]),
            const SizedBox(height: 2),
            Text(detail, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}

/// Banner de advertencia (modelo de prueba, supuestos de visualización, etc.).
class NoticeBanner extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;
  const NoticeBanner(this.text, {super.key, this.color = StructuraColors.warning, this.icon = Icons.info_outline_rounded});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm + 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 13, height: 1.35))),
        ]),
      );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.action});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 40, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(height: Gap.md),
          Text(title, style: t.textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: Gap.xs),
          Text(message,
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: Gap.lg), action!],
        ]),
      ),
    );
  }
}

/// Barra de confianza 0..1 con valor numérico tabular.
class ConfidenceBar extends StatelessWidget {
  final double? value;
  const ConfidenceBar(this.value, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final v = value;
    if (v == null) {
      return Text('sin dato', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant));
    }
    final color = v >= 0.8 ? StructuraColors.success : (v >= 0.5 ? StructuraColors.warning : StructuraColors.danger);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 56,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: v, minHeight: 5, color: color, backgroundColor: t.colorScheme.outlineVariant),
        ),
      ),
      const SizedBox(width: 6),
      Text('${(v * 100).toStringAsFixed(0)}%', style: t.textTheme.bodySmall?.copyWith(fontFeatures: tabular)),
    ]);
  }
}

/// Fondo de grilla de plano técnico.
class BlueprintGrid extends StatelessWidget {
  final Widget? child;
  final double spacing;
  const BlueprintGrid({super.key, this.child, this.spacing = 24});
  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _GridPainter(Theme.of(context).brightness == Brightness.dark ? StructuraColors.grid : const Color(0xFFE6EAF0), spacing),
        child: child,
      );
}

class _GridPainter extends CustomPainter {
  final Color color;
  final double spacing;
  _GridPainter(this.color, this.spacing);
  @override
  void paint(Canvas canvas, Size size) {
    final minor = Paint()
      ..color = color
      ..strokeWidth = 0.5;
    final major = Paint()
      ..color = color.withValues(alpha: 1)
      ..strokeWidth = 1;
    var i = 0;
    for (double x = 0; x < size.width; x += spacing, i++) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), i % 5 == 0 ? major : minor);
    }
    i = 0;
    for (double y = 0; y < size.height; y += spacing, i++) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), i % 5 == 0 ? major : minor);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color || old.spacing != spacing;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String formatDate(DateTime d) {
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
}

/// Barra de acciones fija al pie: la acción principal siempre a la vista, sin scroll.
class ActionBar extends StatelessWidget {
  final List<Widget> children;
  const ActionBar({super.key, required this.children});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: t.colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.md),
        child: Row(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: Gap.sm),
            children[i],
          ],
        ]),
      ),
    );
  }
}

/// Panel semitransparente para controles flotantes sobre el visor 3D o una imagen.
class GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const GlassPanel({super.key, required this.child, this.padding = const EdgeInsets.all(Gap.sm)});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainer.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.colorScheme.outlineVariant),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: child,
    );
  }
}

/// Acceso rápido en grilla: ícono, título, subtítulo de estado y badge opcional.
class QuickTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? accent;
  final bool busy;
  const QuickTile(
      {super.key, required this.icon, required this.title, required this.subtitle, this.onTap, this.accent, this.busy = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final enabled = onTap != null;
    final c = accent ?? StructuraColors.accent;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: t.colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: t.colorScheme.outlineVariant)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                child: busy
                    ? Padding(padding: const EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2, color: c))
                    : Icon(icon, size: 20, color: c),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.2)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
