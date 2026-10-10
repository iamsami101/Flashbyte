import 'package:dynamic_color/dynamic_color.dart';
import 'package:flashbyte/app/app_settings.dart';
import 'package:flutter/material.dart';

class AppAppearanceController extends ChangeNotifier {
  AppAppearanceController._();

  static final AppAppearanceController instance = AppAppearanceController._();

  bool _useDynamicColors = false;
  String _primaryColorName = AppSettings.defaultPrimaryColorName;
  bool _useDarkMode = true;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;
  bool get useDynamicColors => _useDynamicColors;
  String get primaryColorName => _primaryColorName;
  bool get useDarkMode => _useDarkMode;
  bool get isAmoled => _primaryColorName == 'amoled';
  ThemeMode get themeMode => _useDarkMode ? ThemeMode.dark : ThemeMode.light;
  MaterialColor get seedColor =>
      AppSettings.getPrimaryColorByName(_primaryColorName);

  Future<void> load() async {
    _useDynamicColors = await AppSettings.getDynamicColorsEnabled();
    _primaryColorName = await AppSettings.getPrimaryColorName();
    _useDarkMode = await AppSettings.getUseDarkMode();
    if (isAmoled) {
      _useDarkMode = true;
      _useDynamicColors = false;
    }
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> setUseDynamicColors(bool value) async {
    _useDynamicColors = value;
    await AppSettings.setDynamicColorsEnabled(value);
    notifyListeners();
  }

  Future<void> setPrimaryColorName(String colorName) async {
    if (!AppSettings.primaryColorOptions.containsKey(colorName)) {
      return;
    }
    _primaryColorName = colorName;
    if (colorName == 'amoled') {
      _useDarkMode = true;
      _useDynamicColors = false;
      await AppSettings.setUseDarkMode(true);
      await AppSettings.setDynamicColorsEnabled(false);
    }
    await AppSettings.setPrimaryColorName(colorName);
    notifyListeners();
  }

  Future<void> setUseDarkMode(bool value) async {
    if (isAmoled && !value) {
      return;
    }
    _useDarkMode = value;
    await AppSettings.setUseDarkMode(value);
    notifyListeners();
  }

  ThemeData buildTheme({
    required Brightness brightness,
    required ColorScheme? dynamicScheme,
  }) {
    if (isAmoled && brightness == Brightness.dark) {
      return _buildAmoledTheme();
    }

    final seedColor = AppSettings.getPrimaryColorByName(_primaryColorName);

    final scheme = _useDynamicColors && dynamicScheme != null
        ? dynamicScheme
        : ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);

    final harmonizedScheme = scheme.harmonized();

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: harmonizedScheme,
      scaffoldBackgroundColor: harmonizedScheme.surface,
      canvasColor: harmonizedScheme.surface,
    );
  }

  /// Pure monochrome AMOLED theme: black, white, and grey only.
  /// No hue — zero saturation. Primary accent is pure white.
  ThemeData _buildAmoledTheme() {
    final amoledScheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF8A8A8A),
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFFFFFFFF),
          onPrimary: const Color(0xFF000000),
          primaryContainer: const Color(0xFF1A1A1A),
          onPrimaryContainer: const Color(0xFFE0E0E0),
          secondary: const Color(0xFFB3B3B3),
          onSecondary: const Color(0xFF000000),
          secondaryContainer: const Color(0xFF2A2A2A),
          onSecondaryContainer: const Color(0xFFE8E8E8),
          tertiary: const Color(0xFF8A8A8A),
          onTertiary: const Color(0xFF000000),
          tertiaryContainer: const Color(0xFF1F1F1F),
          onTertiaryContainer: const Color(0xFFD6D6D6),
          error: const Color(0xFFFFB4AB),
          onError: const Color(0xFF690005),
          errorContainer: const Color(0xFF93000A),
          onErrorContainer: const Color(0xFFFFDAD6),
          surface: const Color(0xFF000000),
          onSurface: const Color(0xFFFFFFFF),
          onSurfaceVariant: const Color(0xFF9E9E9E),
          outline: const Color(0xFF8A8A8A),
          outlineVariant: const Color(0xFF4A4A4A),
          shadow: const Color(0xFF000000),
          scrim: const Color(0xFF000000),
          inverseSurface: const Color(0xFFE6E6E6),
          onInverseSurface: const Color(0xFF1A1A1A),
          surfaceContainerLowest: const Color(0xFF000000),
          surfaceContainerLow: const Color(0xFF111111),
          surfaceContainer: const Color(0xFF1A1A1A),
          surfaceContainerHigh: const Color(0xFF242424),
          surfaceContainerHighest: const Color(0xFF2E2E2E),
          surfaceBright: const Color(0xFF1A1A1A),
          surfaceDim: const Color(0xFF000000),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: amoledScheme,
      scaffoldBackgroundColor: const Color(0xFF000000),
      canvasColor: const Color(0xFF000000),
    );
  }
}
