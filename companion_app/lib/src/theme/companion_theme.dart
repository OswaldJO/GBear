import 'package:flutter/material.dart';

import '../services/companion_appearance_settings.dart';

/// Dark-first Material 3 theme for GBear Companion.
abstract final class CompanionTheme {
  static const Color _background = Color(0xFF0E1014);
  static const Color _surface = Color(0xFF161920);
  static const Color _surfaceHigh = Color(0xFF1E232D);
  static const Color _card = Color(0xFF1C2028);
  static const Color _seed = Color(0xFF6EB5FF);

  static ThemeData dark({Color primaryText = CompanionAppearanceSettings.defaultPrimaryText}) {
    final onSurfaceVariant = Color.alphaBlend(
      primaryText.withValues(alpha: 0.72),
      _surface,
    );
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
      surface: _surface,
      surfaceContainerHighest: _surfaceHigh,
    ).copyWith(
      onSurface: primaryText,
      onSurfaceVariant: onSurfaceVariant,
      primary: _seed,
      onPrimary: _background,
    );

    final textTheme = Typography.material2021(platform: TargetPlatform.android)
        .white
        .apply(
          bodyColor: primaryText,
          displayColor: primaryText,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      scaffoldBackgroundColor: _background,
      appBarTheme: AppBarTheme(
        backgroundColor: _surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 2,
      ),
      cardTheme: CardThemeData(
        color: _card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _surface,
        indicatorColor: _seed.withValues(alpha: 0.22),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(color: _seed, fontSize: 12);
          }
          return TextStyle(color: onSurfaceVariant, fontSize: 12);
        }),
      ),
      listTileTheme: ListTileThemeData(
        titleTextStyle: textTheme.titleMedium,
        subtitleTextStyle: textTheme.bodySmall?.copyWith(color: onSurfaceVariant),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((_) => _seed),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        disabledColor: Colors.transparent,
        selectedColor: Colors.transparent,
        side: BorderSide(color: primaryText),
        labelStyle: TextStyle(color: primaryText),
        secondaryLabelStyle: TextStyle(color: primaryText),
        deleteIconColor: primaryText,
        iconTheme: IconThemeData(color: primaryText, size: 18),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryText,
          disabledForegroundColor: primaryText.withValues(alpha: 0.38),
          side: BorderSide(color: primaryText, width: 1.5),
          disabledBackgroundColor: Colors.transparent,
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(foregroundColor: _background),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: _surfaceHigh,
        modalBackgroundColor: _surfaceHigh,
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: _surfaceHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _card,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.35)),
    );
  }
}
