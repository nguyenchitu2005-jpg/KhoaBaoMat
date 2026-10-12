import 'package:flutter/material.dart';

/// Material 3, tông xanh dương giống app faceid; tự theo chế độ sáng/tối của máy.
abstract final class AppTheme {
  static const _seed = Color(0xFF1D4ED8);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      cardTheme: const CardThemeData(margin: EdgeInsets.zero),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}
