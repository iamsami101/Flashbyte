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
  ThemeMode get themeMode => _useDarkMode ? ThemeMode.dark : ThemeMode.light;
  MaterialColor get seedColor =>
      AppSettings.getPrimaryColorByName(_primaryColorName);

  Future<void> load() async {
    _useDynamicColors = await AppSettings.getDynamicColorsEnabled();
    _primaryColorName = await AppSettings.getPrimaryColorName();
    _useDarkMode = await AppSettings.getUseDarkMode();
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
    await AppSettings.setPrimaryColorName(colorName);
    notifyListeners();
  }

  Future<void> setUseDarkMode(bool value) async {
    _useDarkMode = value;
    await AppSettings.setUseDarkMode(value);
    notifyListeners();
  }

  ThemeData buildTheme({
    required Brightness brightness,
    required ColorScheme? dynamicScheme,
  }) {
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
}
