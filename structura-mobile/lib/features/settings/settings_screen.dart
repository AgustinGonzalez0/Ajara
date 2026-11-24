import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../platform/native_channels.dart';
import '../../widgets/common.dart';

final storageUsageProvider = FutureProvider.autoDispose<(int, int)>((ref) async {
  final store = ref.watch(projectStoreProvider);
  final projects = await ref.watch(projectsProvider.future);
  var total = 0;
  for (final p in projects) {
    total += await store.sizeOf(p.id);
  }
  return (projects.length, total);
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final usage = ref.watch(storageUsageProvider);
    final models = ref.watch(installedModelsProvider);
    final dirs = ref.watch(appDirsProvider);
    final t = Theme.of(context);
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(padding: const EdgeInsets.all(Gap.xl), children: [
            Text('Configuración', style: t.textTheme.displaySmall),
            const SectionLabel('Preferencias'),
            Card(
              child: Column(children: [
                SwitchListTile(
                  title: const Text('Tema oscuro'),
                  value: s.darkMode,
                  onChanged: (v) => ref.read(settingsProvider.notifier).setDarkMode(v),
                ),
                const Divider(),
                ListTile(
                  title: const Text('Resolución de PDF por defecto'),
                  subtitle: const Text('200 DPI coincide con el dataset de entrenamiento'),
                  trailing: DropdownButton<double>(
                    value: s.pdfDpi,
                    underline: const SizedBox.shrink(),
                    items: const [150.0, 200.0, 300.0]
                        .map((v) => DropdownMenuItem(value: v, child: Text('${v.toInt()} DPI')))
                        .toList(),
                    onChanged: (v) => v == null ? null : ref.read(settingsProvider.notifier).setPdfDpi(v),
                  ),
                ),
              ]),
            ),
            const SectionLabel('Almacenamiento'),
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: usage.when(
                  data: (u) => Text('${u.$1} proyectos · ${formatBytes(u.$2)}', style: const TextStyle(fontFeatures: tabular)),
                  loading: () => const Text('Calculando…'),
                  error: (e, _) => Text('No disponible: $e'),
                ),
                subtitle: Text(dirs.projects.path, style: t.textTheme.bodySmall),
              ),
            ),
            const SectionLabel('Modelos instalados'),
            models.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => NoticeBanner('Error al leer modelos: $e', color: StructuraColors.danger),
              data: (list) => Column(children: [
                for (final m in list)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.lg),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${m.descriptor.id} · v${m.descriptor.version}', style: t.textTheme.titleSmall),
                        const SizedBox(height: Gap.sm),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          StatusPill(m.descriptor.isTestModel ? 'PRUEBA' : 'PRODUCCIÓN',
                              color: m.descriptor.isTestModel ? StructuraColors.warning : StructuraColors.success),
                          StatusPill('DATOS: ${m.descriptor.trainingData.toUpperCase()}', color: StructuraColors.textMuted),
                          StatusPill(m.hashVerified ? 'SHA-256 OK' : 'SHA-256 FALLÓ',
                              color: m.hashVerified ? StructuraColors.success : StructuraColors.danger),
                          StatusPill(formatBytes(m.bytes), color: StructuraColors.textMuted),
                        ]),
                        const SizedBox(height: Gap.sm),
                        Text('Clases: ${m.descriptor.classes.join(', ')}', style: t.textTheme.bodySmall),
                        if (m.descriptor.valMiou != null)
                          Text('mIoU de validación declarado: ${m.descriptor.valMiou!.toStringAsFixed(3)} (sobre su propio dataset)',
                              style: t.textTheme.bodySmall),
                      ]),
                    ),
                  ),
              ]),
            ),
            const SectionLabel('Capacidades de esta plataforma'),
            Card(
              child: Column(children: [
                _cap('Runtime de IA (ONNX Runtime)', NativeCapabilities.onnx),
                const Divider(),
                _cap('Lectura de PDF (PdfRenderer)', NativeCapabilities.pdf),
              ]),
            ),
            const SectionLabel('Acerca de'),
            Card(
              child: Column(children: [
                const ListTile(
                  title: Text('STRUCTURA AI 0.1.0'),
                  subtitle: Text('El procesamiento se ejecuta en el dispositivo. Los planos no se envían a servidores. '
                      'La reconstrucción 3D es geométrica: no es un análisis ni un cálculo estructural.'),
                ),
                const Divider(),
                ListTile(
                  title: const Text('Licencias de código abierto'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showLicensePage(context: context, applicationName: 'STRUCTURA AI', applicationVersion: '0.1.0'),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _cap(String label, bool ok) => ListTile(
        title: Text(label),
        trailing: StatusPill(ok ? 'DISPONIBLE' : 'NO DISPONIBLE', color: ok ? StructuraColors.success : StructuraColors.textMuted),
      );
}
