import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../widgets/logo.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});
  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    // Carga inicial real: proyectos e instalación/verificación de modelos.
    final models = ref.read(installedModelsProvider.future).catchError((_) => <Never>[]);
    final projects = ref.read(projectsProvider.future).catchError((_) => <Never>[]);
    await Future.wait<Object?>([_c.forward(), models, projects]);
    if (!mounted) return;
    final done = ref.read(settingsProvider).onboardingDone;
    context.go(done ? Routes.home : Routes.onboarding);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StructuraColors.ink,
      body: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final draw = Curves.easeInOutCubic.transform((_c.value / 0.7).clamp(0, 1));
            final text = Curves.easeOut.transform(((_c.value - 0.55) / 0.45).clamp(0, 1));
            return Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 120, height: 120, child: StructuraLogo(progress: draw)),
              const SizedBox(height: Gap.xl),
              Opacity(
                opacity: text,
                child: Transform.translate(
                  offset: Offset(0, 8 * (1 - text)),
                  child: Column(children: [
                    const Text('STRUCTURA',
                        style: TextStyle(color: StructuraColors.text, fontSize: 26, letterSpacing: 8, fontWeight: FontWeight.w300)),
                    const SizedBox(height: 4),
                    Text('AI · PLANOS → MODELOS 3D',
                        style: TextStyle(color: StructuraColors.textMuted.withValues(alpha: 0.9), fontSize: 11, letterSpacing: 3)),
                  ]),
                ),
              ),
              const SizedBox(height: Gap.xxl),
              SizedBox(
                width: 120,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: StructuraColors.accent,
                  backgroundColor: StructuraColors.outline,
                  value: _c.isAnimating ? null : 1,
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
