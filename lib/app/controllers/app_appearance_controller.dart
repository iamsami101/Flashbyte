import 'package:dynamic_color/dynamic_color.dart';
import 'package:flashbyte/app/app_settings.dart';
import 'package:flutter/material.dart';

class AppAppearanceController extends ChangeNotifier {
  AppAppearanceController._();

  static final AppAppearanceController instance = AppAppearanceController._();

  bool _useDynamicColors = false;
  String _primaryColorName = AppSettings.defaultPrimaryColorName;
  bool _useDarkMode = true;
  bool _useAmoled = false;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;
  bool get useDynamicColors => _useDynamicColors;
  String get primaryColorName => _primaryColorName;
  bool get useDarkMode => _useDarkMode;
  bool get useAmoled => _useAmoled;
  ThemeMode get themeMode => _useDarkMode ? ThemeMode.dark : ThemeMode.light;
  MaterialColor get seedColor =>
      AppSettings.getPrimaryColorByName(_primaryColorName);

  Future<void> load() async {
    _useDynamicColors = await AppSettings.getDynamicColorsEnabled();
    _primaryColorName = await AppSettings.getPrimaryColorName();
    _useDarkMode = await AppSettings.getUseDarkMode();
    _useAmoled = await AppSettings.getUseAmoled();
    if (_useAmoled) {
      _useDarkMode = true;
      _useDynamicColors = false;
    }
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> setUseDynamicColors(bool value) async {
    _useDynamicColors = value;
    if (value && _useAmoled) {
      _useAmoled = false;
      await AppSettings.setUseAmoled(false);
    }
    await AppSettings.setDynamicColorsEnabled(value);
    notifyListeners();
  }

  Future<void> setPrimaryColorName(String colorName) async {
    if (!AppSettings.primaryColorOptions.containsKey(colorName)) {
      return;
    }
    _primaryColorName = colorName;
    await AppSettings.setPrimaryColorName(colorName);
    notifyListeners();
  }

  Future<void> setUseDarkMode(bool value) async {
    _useDarkMode = value;
    if (!value && _useAmoled) {
      _useAmoled = false;
      await AppSettings.setUseAmoled(false);
    }
    await AppSettings.setUseDarkMode(value);
    notifyListeners();
  }

  Future<void> setUseAmoled(bool value) async {
    _useAmoled = value;
    if (value) {
      _useDarkMode = true;
      _useDynamicColors = false;
      await AppSettings.setUseDarkMode(true);
      await AppSettings.setDynamicColorsEnabled(false);
    }
    await AppSettings.setUseAmoled(value);
    notifyListeners();
  }

  ThemeData buildTheme({
    required Brightness brightness,
    required ColorScheme? dynamicScheme,
  }) {
    if (_useAmoled && brightness == Brightness.dark) {
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

  ThemeData _buildAmoledTheme() {
    final seedColor = AppSettings.getPrimaryColorByName(_primaryColorName);
    final base = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    ).harmonized();

    final amoledScheme = base.copyWith(
      surface: const Color(0xFF000000),
      surfaceContainerLowest: const Color(0xFF000000),
      surfaceContainerLow: const Color(0xFF0A0A0A),
      surfaceContainer: const Color(0xFF121212),
      surfaceContainerHigh: const Color(0xFF1A1A1A),
      surfaceContainerHighest: const Color(0xFF222222),
      surfaceBright: const Color(0xFF1E1E1E),
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
