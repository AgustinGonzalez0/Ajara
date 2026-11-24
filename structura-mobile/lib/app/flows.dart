/// Flujos de varios pasos encadenados para que el usuario toque lo mínimo:
/// foto → modelo 3D en dos toques, evaluación que pide la escala solo si falta,
/// informe que se genera y comparte en un toque.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/share_service.dart';
import 'providers.dart';
import 'router.dart';

enum QuickSource { camera, gallery, file }

/// Crea un proyecto con nombre automático y abre directamente la cámara, la galería
/// o el selector de archivos. Si el usuario cancela, el proyecto vacío se descarta.
Future<void> quickStart(BuildContext context, WidgetRef ref, QuickSource source) async {
  final m = await ref.read(projectsProvider.notifier).createQuick();
  if (!context.mounted) return;
  context.push(switch (source) {
    QuickSource.camera => Routes.photo(m.id, quick: true),
    QuickSource.gallery => Routes.photo(m.id, camera: false, quick: true),
    QuickSource.file => Routes.import(m.id, auto: true, quick: true),
  });
}

/// Abre la evaluación. Sin escala verificada va primero a calibrar y de ahí sigue sola.
Future<void> openEvaluation(BuildContext context, WidgetRef ref, String projectId) async {
  final model = await ref.read(simModelProvider(projectId).future);
  if (!context.mounted) return;
  context.push(model.hasVerifiedScale ? Routes.simulate(projectId) : Routes.calibrate(projectId, thenSimulate: true));
}

/// Genera el informe PDF de la última evaluación y abre la hoja de compartir.
Future<String> exportAndShareReport(WidgetRef ref, String projectId) async {
  final p = await ref.read(projectStoreProvider).load(projectId);
  final path = await ref.read(reportServiceProvider).exportScreeningReport(p);
  await ref
      .read(fileSharerProvider)
      .shareFile(
        path,
        mimeType: mimePdf,
        subject: 'Evaluación preliminar — ${p.name}',
        text: 'Informe generado con STRUCTURA AI. Evaluación preliminar: no es un cálculo estructural.',
      );
  return path;
}

/// Lanza el análisis con el motor clásico (sin IA): el que funciona en cualquier celular.
void startDefaultAnalysis(WidgetRef ref, String projectId) => ref.read(analysisControllerProvider(projectId).notifier).start();
