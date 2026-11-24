import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../widgets/common.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pc = PageController();
  int _page = 0;

  static const _pages = [
    (
      Icons.upload_file_rounded,
      'Importá tus planos',
      'PDF, PNG, JPG o TIFF. Cada plano se convierte a una imagen canónica y se guarda junto al original, '
          'sin modificarlo.'
    ),
    (
      Icons.auto_awesome_mosaic_rounded,
      'Análisis local con IA',
      'Vision AI segmenta muros, puertas, ventanas, columnas y escaleras en tu dispositivo, sin enviar el plano '
          'a servidores. Cada detección conserva su nivel de confianza.'
    ),
    (
      Icons.view_in_ar_rounded,
      'Reconstrucción 3D determinista',
      'El motor geométrico convierte las detecciones en un modelo 3D reproducible. Las medidas reales solo se '
          'usan si la escala fue verificada; nada se inventa.'
    ),
  ];

  Future<void> _finish() async {
    await ref.read(settingsProvider.notifier).completeOnboarding();
    if (mounted) context.go(Routes.home);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: BlueprintGrid(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: _finish, child: const Text('Omitir')),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _pc,
                    itemCount: _pages.length,
                    onPageChanged: (i) => setState(() => _page = i),
                    itemBuilder: (context, i) {
                      final (icon, title, body) = _pages[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: StructuraColors.accentSoft,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: StructuraColors.accent.withValues(alpha: 0.5)),
                            ),
                            child: Icon(icon, color: StructuraColors.accent, size: 30),
                          ),
                          const SizedBox(height: Gap.xl),
                          Text('0${i + 1} / 0${_pages.length}', style: t.textTheme.labelSmall?.copyWith(color: StructuraColors.accent)),
                          const SizedBox(height: Gap.sm),
                          Text(title, style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w500)),
                          const SizedBox(height: Gap.md),
                          Text(body, style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.5)),
                        ]),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(Gap.xl),
                  child: Row(children: [
                    for (var i = 0; i < _pages.length; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin: const EdgeInsets.only(right: 6),
                        width: i == _page ? 22 : 8,
                        height: 4,
                        decoration: BoxDecoration(
                          color: i == _page ? StructuraColors.accent : t.colorScheme.outline,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _page == _pages.length - 1
                          ? _finish
                          : () => _pc.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic),
                      child: Text(_page == _pages.length - 1 ? 'Comenzar' : 'Siguiente'),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
