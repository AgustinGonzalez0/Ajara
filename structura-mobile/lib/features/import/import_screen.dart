import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../services/plan_importer.dart';
import '../../widgets/common.dart';

/// Archivo elegido por el usuario, ya copiado a una ruta local legible.
class PickedFile {
  final File file;
  final String name;
  const PickedFile(this.file, this.name);
}

/// Selector de archivos (sobrescribible en tests).
final filePickProvider = Provider<Future<PickedFile?> Function()>((ref) => () async {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: supportedExtensions);
      if (files.isEmpty) return null;
      final f = files.first;
      // En Android el archivo puede ser un content:// sin ruta: se copia al caché.
      final tmp = await getTemporaryDirectory();
      final local = File(p.join(tmp.path, 'import_${DateTime.now().millisecondsSinceEpoch}_${f.name}'));
      final sink = local.openWrite();
      await sink.addStream(f.readAsByteStream());
      await sink.close();
      return PickedFile(local, f.name);
    });

class ImportScreen extends ConsumerStatefulWidget {
  final String projectId;
  const ImportScreen({super.key, required this.projectId});
  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  PickedFile? _picked;
  String? _type;
  String? _error;
  int _pages = 0;
  int _page = 1;
  late double _dpi = ref.read(settingsProvider).pdfDpi;
  final Map<int, File> _thumbs = {};
  bool _busy = false;

  Future<void> _pick() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final picked = await ref.read(filePickProvider)();
      if (picked == null) return;
      final type = await validatePlanFile(picked.file);
      var pages = 0;
      _thumbs.clear();
      if (type == 'pdf') {
        final pdf = ref.read(pdfRasterizerProvider);
        if (!pdf.isAvailable) throw const ImportException('La lectura de PDF no está disponible en esta plataforma.');
        pages = await pdf.pageCount(picked.file.path);
      }
      setState(() {
        _picked = picked;
        _type = type;
        _pages = pages;
        _page = 1;
      });
      if (type == 'pdf') _loadThumbs();
    } on ImportException catch (e) {
      setState(() => _error = e.message);
    } on Object catch (e) {
      setState(() => _error = 'No se pudo leer el archivo: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadThumbs() async {
    final pdf = ref.read(pdfRasterizerProvider);
    final tmp = await getTemporaryDirectory();
    for (var i = 1; i <= _pages && i <= 60; i++) {
      final out = File(p.join(tmp.path, 'thumb_${_picked!.file.path.hashCode}_$i.png'));
      try {
        if (!await out.exists()) await pdf.renderPage(_picked!.file.path, i, 36, out.path, maxPixels: 2000000);
        if (!mounted) return;
        setState(() => _thumbs[i] = out);
      } on Object {
        // La miniatura es opcional; la página sigue siendo seleccionable.
      }
    }
  }

  Future<void> _import() async {
    final picked = _picked;
    if (picked == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final store = ref.read(projectStoreProvider);
      final project = await store.load(widget.projectId);
      await ref.read(planImporterProvider).import(project, picked.file,
          originalName: picked.name, page: _type == 'pdf' ? _page : null, dpi: _dpi);
      refreshProject(ref, widget.projectId);
      if (mounted) context.pushReplacement(Routes.project(widget.projectId));
    } on ImportException catch (e) {
      setState(() => _error = e.message);
    } on Object catch (e) {
      setState(() => _error = 'Error al importar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final picked = _picked;
    return Scaffold(
      appBar: AppBar(title: const Text('Importar plano')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(padding: const EdgeInsets.all(Gap.xl), children: [
              _DropZone(onTap: _busy ? null : _pick, picked: picked, type: _type),
              if (_error != null) ...[
                const SizedBox(height: Gap.md),
                NoticeBanner(_error!, color: StructuraColors.danger, icon: Icons.error_outline_rounded),
              ],
              if (picked != null && _type == 'pdf') ...[
                SectionLabel('Página ($_pages en total)'),
                SizedBox(
                  height: 132,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _pages.clamp(0, 60),
                    separatorBuilder: (_, _) => const SizedBox(width: Gap.sm),
                    itemBuilder: (_, i) {
                      final pg = i + 1;
                      final sel = pg == _page;
                      return GestureDetector(
                        onTap: () => setState(() => _page = pg),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 92,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: sel ? StructuraColors.accent : t.colorScheme.outline, width: sel ? 2 : 1),
                          ),
                          child: Stack(children: [
                            Positioned.fill(
                              child: _thumbs[pg] == null
                                  ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                                  : ClipRRect(borderRadius: BorderRadius.circular(7), child: Image.file(_thumbs[pg]!, fit: BoxFit.contain)),
                            ),
                            Positioned(
                              left: 4,
                              bottom: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                color: Colors.black87,
                                child: Text('$pg', style: const TextStyle(color: Colors.white, fontSize: 11, fontFeatures: tabular)),
                              ),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
                const SectionLabel('Resolución de rasterizado'),
                SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: 150, label: Text('150 DPI')),
                    ButtonSegment(value: 200, label: Text('200 DPI')),
                    ButtonSegment(value: 300, label: Text('300 DPI')),
                  ],
                  selected: {_dpi},
                  onSelectionChanged: (s) => setState(() => _dpi = s.first),
                ),
                const SizedBox(height: Gap.sm),
                Text('200 DPI coincide con el dataset de entrenamiento: los muros quedan con un espesor en píxeles similar al aprendido.',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ],
              if (picked != null && _type != 'pdf') ...[
                const SectionLabel('Vista previa'),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    color: Colors.white,
                    constraints: const BoxConstraints(maxHeight: 360),
                    child: _type == 'tiff'
                        ? const Padding(padding: EdgeInsets.all(Gap.xl), child: Text('Vista previa de TIFF disponible después de importar.', style: TextStyle(color: Colors.black54)))
                        : Image.file(picked.file, fit: BoxFit.contain, cacheWidth: 1400),
                  ),
                ),
              ],
              const SizedBox(height: Gap.xl),
              FilledButton.icon(
                key: const Key('do_import'),
                onPressed: picked == null || _busy ? null : _import,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check_rounded),
                label: Text(_busy ? 'Procesando…' : 'Importar al proyecto'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _DropZone extends StatelessWidget {
  final VoidCallback? onTap;
  final PickedFile? picked;
  final String? type;
  const _DropZone({required this.onTap, required this.picked, required this.type});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: const Key('pick_file'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(Gap.xl),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: picked == null ? t.colorScheme.outline : StructuraColors.accent),
          ),
          child: Row(children: [
            Icon(picked == null ? Icons.upload_file_rounded : Icons.description_rounded, size: 36, color: StructuraColors.accent),
            const SizedBox(width: Gap.lg),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(picked == null ? 'Elegir archivo' : picked!.name, style: t.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(picked == null ? 'PDF, PNG, JPG o TIFF · hasta 200 MB' : 'Tipo detectado: ${type!.toUpperCase()} · tocá para cambiar',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
