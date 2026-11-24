import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:structura_vision/structura_vision.dart';

import '../../app/flows.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../services/photo_importer.dart';
import '../../widgets/common.dart';

/// Toma o elige una foto (sobrescribible en tests).
final photoPickProvider = Provider<Future<File?> Function(bool camera)>(
  (ref) => (camera) async {
    final x = await ImagePicker().pickImage(source: camera ? ImageSource.camera : ImageSource.gallery, imageQuality: 95);
    return x == null ? null : File(x.path);
  },
);

/// Foto de un plano → hoja detectada automáticamente → ajuste de esquinas → importación.
class PhotoScreen extends ConsumerStatefulWidget {
  final String projectId;
  final bool camera;

  /// Proyecto creado por el flujo rápido: si se cancela sin importar, se descarta.
  final bool quick;
  const PhotoScreen({super.key, required this.projectId, this.camera = true, this.quick = false});
  @override
  ConsumerState<PhotoScreen> createState() => _PhotoScreenState();
}

class _PhotoScreenState extends ConsumerState<PhotoScreen> {
  File? _file;
  PreparedPhoto? _photo;
  ui.Image? _preview;
  List<Pt>? _corners;
  String? _error;
  bool _busy = false;
  bool _imported = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick(widget.camera));
  }

  Future<void> _pick(bool camera) async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final f = await ref.read(photoPickProvider)(camera);
      if (f == null) return;
      final photo = await preparePhoto(f);
      final preview = await _toImage(photo);
      setState(() {
        _file = f;
        _photo = photo;
        _preview = preview;
        _corners = photo.suggested.points;
      });
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<ui.Image> _toImage(PreparedPhoto p) async {
    final rgba = Uint8List(p.width * p.height * 4);
    for (var i = 0, j = 0; i < p.width * p.height; i++, j += 3) {
      rgba[i * 4] = p.rgb[j];
      rgba[i * 4 + 1] = p.rgb[j + 1];
      rgba[i * 4 + 2] = p.rgb[j + 2];
      rgba[i * 4 + 3] = 255;
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final desc = ui.ImageDescriptor.raw(buffer, width: p.width, height: p.height, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await desc.instantiateCodec();
    return (await codec.getNextFrame()).image;
  }

  Future<void> _import() async {
    final photo = _photo, file = _file, c = _corners;
    if (photo == null || file == null || c == null) return;
    setState(() => _busy = true);
    try {
      final quad = Quad(c[0], c[1], c[2], c[3]);
      if (quad.area < 0.05 * photo.width * photo.height) {
        throw StateError('El recorte es demasiado chico. Ajustá las esquinas a los bordes de la hoja.');
      }
      final project = await ref.read(projectStoreProvider).load(widget.projectId);
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name = 'Foto del plano ${two(now.day)}-${two(now.month)}-${now.year} ${two(now.hour)}.${two(now.minute)}.jpg';
      await ref.read(photoImporterProvider).import(project, file, photo, quad, originalName: name);
      _imported = true;
      refreshProject(ref, widget.projectId);
      // Sin pasos intermedios: el modelo 3D se genera mientras se abre el proyecto.
      startDefaultAnalysis(ref, widget.projectId);
      if (mounted) context.pushReplacement(Routes.project(widget.projectId));
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final photo = _photo;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && widget.quick && !_imported) ref.read(projectsProvider.notifier).discardIfEmpty(widget.projectId);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(photo == null ? 'Plano desde una foto' : 'Ajustá el recorte')),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: photo == null || _preview == null
                    ? Center(
                        child: _busy
                            ? const CircularProgressIndicator()
                            : EmptyState(
                                icon: Icons.photo_camera_outlined,
                                title: 'Fotografiá el plano',
                                message:
                                    'Hoja completa, de frente, con buena luz y sin sombras fuertes. '
                                    'Se corrige la perspectiva automáticamente.',
                                action: Wrap(
                                  spacing: Gap.sm,
                                  children: [
                                    FilledButton.icon(
                                      key: const Key('take_photo'),
                                      onPressed: () => _pick(true),
                                      icon: const Icon(Icons.photo_camera_rounded),
                                      label: const Text('Tomar foto'),
                                    ),
                                    OutlinedButton.icon(
                                      key: const Key('gallery_photo'),
                                      onPressed: () => _pick(false),
                                      icon: const Icon(Icons.photo_library_outlined),
                                      label: const Text('Galería'),
                                    ),
                                  ],
                                ),
                              ),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(Gap.md),
                        child: _CornerEditor(
                          image: _preview!,
                          corners: _corners!,
                          onChanged: (c) => setState(() => _corners = c),
                        ),
                      ),
              ),
              if (photo != null)
                Container(
                  decoration: BoxDecoration(
                    color: t.colorScheme.surfaceContainerLow,
                    border: Border(top: BorderSide(color: t.colorScheme.outlineVariant)),
                  ),
                  padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            photo.paperDetected ? Icons.check_circle_rounded : Icons.touch_app_rounded,
                            size: 18,
                            color: photo.paperDetected ? StructuraColors.success : StructuraColors.warning,
                          ),
                          const SizedBox(width: Gap.sm),
                          Expanded(
                            child: Text(
                              photo.paperDetected
                                  ? 'Hoja detectada. Si hace falta, arrastrá una esquina.'
                                  : 'Llevá las 4 esquinas a los bordes del plano.',
                              style: t.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: Gap.sm),
                        NoticeBanner(_error!, color: StructuraColors.danger, icon: Icons.error_outline),
                      ],
                      const SizedBox(height: Gap.md),
                      Row(
                        children: [
                          IconButton.outlined(
                            tooltip: 'Otra foto',
                            onPressed: _busy ? null : () => _pick(widget.camera),
                            icon: const Icon(Icons.refresh),
                          ),
                          const SizedBox(width: Gap.sm),
                          IconButton.outlined(
                            tooltip: 'Usar foto completa',
                            onPressed: () => setState(() => _corners = Quad.full(photo.width, photo.height).points),
                            icon: const Icon(Icons.crop_free),
                          ),
                          const SizedBox(width: Gap.md),
                          Expanded(
                            child: FilledButton.icon(
                              key: const Key('rectify_import'),
                              onPressed: _busy ? null : _import,
                              icon: _busy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.view_in_ar_rounded),
                              label: Text(_busy ? 'Corrigiendo…' : 'Generar modelo 3D'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CornerEditor extends StatefulWidget {
  final ui.Image image;
  final List<Pt> corners;
  final ValueChanged<List<Pt>> onChanged;
  const _CornerEditor({required this.image, required this.corners, required this.onChanged});
  @override
  State<_CornerEditor> createState() => _CornerEditorState();
}

class _CornerEditorState extends State<_CornerEditor> {
  int? _drag;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final iw = widget.image.width.toDouble(), ih = widget.image.height.toDouble();
        final s = (c.maxWidth / iw).clamp(0.0, c.maxHeight / ih);
        final dw = iw * s, dh = ih * s;
        final ox = (c.maxWidth - dw) / 2, oy = (c.maxHeight - dh) / 2;
        Offset toScreen(Pt p) => Offset(ox + p.x * s, oy + p.y * s);
        Pt toImage(Offset o) => Pt(((o.dx - ox) / s).clamp(0, iw - 1), ((o.dy - oy) / s).clamp(0, ih - 1));
        return GestureDetector(
          onPanStart: (d) {
            var best = -1;
            var bestD = 48.0;
            for (var i = 0; i < 4; i++) {
              final dist = (toScreen(widget.corners[i]) - d.localPosition).distance;
              if (dist < bestD) {
                bestD = dist;
                best = i;
              }
            }
            _drag = best >= 0 ? best : null;
          },
          onPanUpdate: (d) {
            final i = _drag;
            if (i == null) return;
            final next = [...widget.corners];
            next[i] = toImage(d.localPosition);
            widget.onChanged(next);
          },
          onPanEnd: (_) => _drag = null,
          child: CustomPaint(
            size: Size(c.maxWidth, c.maxHeight),
            painter: _CornerPainter(widget.image, Rect.fromLTWH(ox, oy, dw, dh), widget.corners.map(toScreen).toList(), _drag),
          ),
        );
      },
    );
  }
}

class _CornerPainter extends CustomPainter {
  final ui.Image image;
  final Rect dst;
  final List<Offset> pts;
  final int? active;
  _CornerPainter(this.image, this.dst, this.pts, this.active);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final path = Path()..addPolygon(pts, true);
    // Oscurece lo que queda fuera del recorte.
    canvas.drawPath(Path.combine(PathOperation.difference, Path()..addRect(dst), path), Paint()..color = const Color(0x99000000));
    canvas.drawPath(
      path,
      Paint()
        ..color = StructuraColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (var i = 0; i < pts.length; i++) {
      canvas.drawCircle(pts[i], i == active ? 16 : 12, Paint()..color = StructuraColors.accent.withValues(alpha: 0.35));
      canvas.drawCircle(pts[i], 6, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_CornerPainter o) => o.pts != pts || o.active != active || o.image != image;
}
