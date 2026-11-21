import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

abstract final class AppTheme {
  static ThemeMode mode(String preference) => switch (preference) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static SystemUiOverlayStyle systemBars(Brightness brightness) {
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static ThemeData build(
    Color seed,
    Brightness brightness, {
    required bool television,
    bool pureBlack = false,
    bool slidePages = true,
  }) {
    final white = seed == Colors.white;
    var seeded = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: white || seed == Colors.black
          ? DynamicSchemeVariant.monochrome
          : DynamicSchemeVariant.tonalSpot,
    );
    if (seed == const Color(0xFF3EE0FF)) {
      seeded = _starScheme(seeded, brightness);
    }
    if (white && brightness == Brightness.light) {
      seeded = seeded.copyWith(surface: Colors.white);
    }
    final scheme = pureBlack && brightness == Brightness.dark
        ? seeded.copyWith(
            surface: Colors.black,
            surfaceDim: Colors.black,
            surfaceContainerLowest: Colors.black,
            surfaceContainerLow: const Color(0xFF0B0B0B),
            surfaceContainer: const Color(0xFF121212),
            surfaceContainerHigh: const Color(0xFF1A1A1A),
            surfaceContainerHighest: const Color(0xFF242424),
          )
        : seeded;
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      pageTransitionsTheme: pageTransitions(
        television: television,
        slide: slidePages,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: systemBars(brightness),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
    );
    final titled = theme.copyWith(
      appBarTheme: theme.appBarTheme.copyWith(
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return theme.textTheme.labelMedium?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
      ),
    );
    return television ? _television(titled) : titled;
  }

  /// 「星星」主题：深蓝夜空背景 + 青蓝发光主色，弱化 Material 默认暖色，
  /// 形成冷色科技感。深色模式下最为明显，浅色模式同样保持冷蓝基调。
  static ColorScheme _starScheme(ColorScheme base, Brightness brightness) {
    if (brightness == Brightness.dark) {
      return base.copyWith(
        primary: const Color(0xFF3EE0FF),
        onPrimary: const Color(0xFF00141F),
        primaryContainer: const Color(0xFF0B3A52),
        onPrimaryContainer: const Color(0xFFC3ECFF),
        secondary: const Color(0xFF7BD4FF),
        onSecondary: const Color(0xFF001A29),
        secondaryContainer: const Color(0xFF103A4E),
        onSecondaryContainer: const Color(0xFFCDEBFF),
        tertiary: const Color(0xFF8FB6FF),
        onTertiary: const Color(0xFF001A41),
        surface: const Color(0xFF060D1F),
        onSurface: const Color(0xFFE7EEFF),
        surfaceDim: const Color(0xFF040A17),
        surfaceContainerLowest: const Color(0xFF02050D),
        surfaceContainerLow: const Color(0xFF081126),
        surfaceContainer: const Color(0xFF0C1530),
        surfaceContainerHigh: const Color(0xFF101B3A),
        surfaceContainerHighest: const Color(0xFF182548),
        onSurfaceVariant: const Color(0xFF9FAECB),
        outline: const Color(0xFF5D6E8F),
        outlineVariant: const Color(0xFF24304A),
        error: const Color(0xFFFFB4AB),
        onError: const Color(0xFF690005),
      );
    }
    return base.copyWith(
      primary: const Color(0xFF007FB8),
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFC0E9FF),
      onPrimaryContainer: const Color(0xFF002537),
      secondary: const Color(0xFF2E6F97),
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFD0E8F7),
      onSecondaryContainer: const Color(0xFF002A3D),
      surface: const Color(0xFFF3F9FF),
      onSurface: const Color(0xFF0D1B2B),
      onSurfaceVariant: const Color(0xFF3D4A5C),
      outline: const Color(0xFF6C7A8E),
      outlineVariant: const Color(0xFFC7D3E4),
    );
  }

  static ThemeData _television(ThemeData theme) {
    final colors = theme.colorScheme;
    final button = ButtonStyle(
      overlayColor: WidgetStateProperty.resolveWith<Color?>(
        (states) => states.contains(WidgetState.focused)
            ? colors.onSurface.withValues(alpha: 0.12)
            : null,
      ),
      minimumSize: const WidgetStatePropertyAll(Size(52, 48)),
    );
    return theme.copyWith(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      focusColor: colors.primary.withValues(alpha: 0.16),
      iconButtonTheme: IconButtonThemeData(style: button),
      filledButtonTheme: FilledButtonThemeData(style: button),
      outlinedButtonTheme: OutlinedButtonThemeData(style: button),
      textButtonTheme: TextButtonThemeData(style: button),
    );
  }
}
