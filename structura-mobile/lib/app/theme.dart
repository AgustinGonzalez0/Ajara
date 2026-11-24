import 'package:flutter/material.dart';

/// Tokens de diseño de STRUCTURA: estética técnica (CAD / plano), alto contraste,
/// cifras tabulares para datos y colores de clase idénticos a structura-core.
abstract final class StructuraColors {
  static const ink = Color(0xFF0B0E13);
  static const surface = Color(0xFF11151C);
  static const surfaceHigh = Color(0xFF171C25);
  static const surfaceHighest = Color(0xFF1E2430);
  static const outline = Color(0xFF283041);
  static const grid = Color(0xFF1A2130);
  static const text = Color(0xFFE6E9EF);
  static const textMuted = Color(0xFF8B94A5);
  static const accent = Color(0xFF4C8DFF); // azul plano
  static const accentSoft = Color(0x334C8DFF);
  static const teal = Color(0xFF2FD3C6);
  static const warning = Color(0xFFF2B84B);
  static const danger = Color(0xFFF2545B);
  static const success = Color(0xFF3FBF7F);

  // Clases (misma paleta que structura-core/core/predict.py)
  static const wall = Color(0xFFDC3C3C);
  static const door = Color(0xFF3CB44B);
  static const window = Color(0xFF4169E1);
  static const column = Color(0xFFF5BE32);
  static const stairs = Color(0xFFAA50BE);

  static const byClass = <String, Color>{
    'wall': wall,
    'door': door,
    'window': window,
    'column': column,
    'stairs': stairs,
  };

  static const classLabels = <String, String>{
    'wall': 'Muros',
    'door': 'Puertas',
    'window': 'Ventanas',
    'column': 'Columnas',
    'stairs': 'Escaleras',
    'room': 'Ambientes',
  };
}

abstract final class Gap {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0;
}

const tabular = [FontFeature.tabularFigures()];

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: StructuraColors.accent,
    onPrimary: Colors.white,
    secondary: StructuraColors.teal,
    onSecondary: StructuraColors.ink,
    error: StructuraColors.danger,
    onError: Colors.white,
    surface: dark ? StructuraColors.surface : const Color(0xFFF6F7F9),
    onSurface: dark ? StructuraColors.text : const Color(0xFF151A22),
    surfaceContainerLowest: dark ? StructuraColors.ink : Colors.white,
    surfaceContainerLow: dark ? StructuraColors.surface : const Color(0xFFF0F2F5),
    surfaceContainer: dark ? StructuraColors.surfaceHigh : const Color(0xFFE9ECF1),
    surfaceContainerHigh: dark ? StructuraColors.surfaceHighest : const Color(0xFFE1E5EB),
    surfaceContainerHighest: dark ? const Color(0xFF252C3A) : const Color(0xFFD8DDE5),
    onSurfaceVariant: dark ? StructuraColors.textMuted : const Color(0xFF5B6475),
    outline: dark ? StructuraColors.outline : const Color(0xFFCBD1DB),
    outlineVariant: dark ? const Color(0xFF1F2633) : const Color(0xFFDDE2E9),
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
  final text = base.textTheme.apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);
  return base.copyWith(
    scaffoldBackgroundColor: dark ? StructuraColors.ink : const Color(0xFFF6F7F9),
    textTheme: text.copyWith(
      displaySmall: text.displaySmall?.copyWith(fontWeight: FontWeight.w300, letterSpacing: -0.5),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -0.2),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      labelSmall: text.labelSmall?.copyWith(letterSpacing: 1.2, fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainer,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.2),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        side: BorderSide(color: scheme.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainer,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: scheme.outline)),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: scheme.outline)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: StructuraColors.accent, width: 1.5)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: StructuraColors.accentSoft,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: StructuraColors.accentSoft,
      height: 68,
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide(color: scheme.outline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}
