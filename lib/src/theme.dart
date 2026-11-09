import 'package:flutter/material.dart';

abstract final class CapturaColors {
  static const background = Color(0xFF0C0D0B);
  static const bar = Color(0xF012130F);
  static const card = Color(0xF01A1B16);
  static const ink = Color(0xFFF4F1EA);
  static const muted = Color(0xFFA39E93);
  static const line = Color(0xFF34352E);
  static const brass = Color(0xFFE2B15A);
  static const brassInk = Color(0xFF1A1408);
  static const moss = Color(0xFF8FBF7A);
  static const danger = Color(0xFFE06A5C);
}

ThemeData capturaTheme() {
  const scheme = ColorScheme.dark(
    surface: CapturaColors.background,
    primary: CapturaColors.brass,
    onPrimary: CapturaColors.brassInk,
    secondary: CapturaColors.moss,
    onSecondary: CapturaColors.brassInk,
    error: CapturaColors.danger,
    onSurface: CapturaColors.ink,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: CapturaColors.background,
    splashFactory: NoSplash.splashFactory,
    sliderTheme: const SliderThemeData(
      activeTrackColor: CapturaColors.brass,
      inactiveTrackColor: CapturaColors.line,
      thumbColor: CapturaColors.brass,
      overlayColor: Color(0x33E2B15A),
      trackHeight: 3,
    ),
  );
}
