import 'package:dynamic_color/dynamic_color.dart';
import 'package:flashbyte/classes/app_settings.dart';
import 'package:flutter/material.dart';

class AppAppearanceController extends ChangeNotifier {
  AppAppearanceController._();

  static final AppAppearanceController instance = AppAppearanceController._();

  bool _useDynamicColors = false;
  String _primaryColorName = AppSettings.defaultPrimaryColorName;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;
  bool get useDynamicColors => _useDynamicColors;
  String get primaryColorName => _primaryColorName;
  MaterialColor get seedColor =>
      AppSettings.getPrimaryColorByName(_primaryColorName);

  Future<void> load() async {
    _useDynamicColors = await AppSettings.getDynamicColorsEnabled();
    _primaryColorName = await AppSettings.getPrimaryColorName();
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

  ThemeData buildTheme({
    required ColorScheme? darkDynamic,
  }) {
    final seedColor = AppSettings.getPrimaryColorByName(_primaryColorName);

    final darkScheme = _useDynamicColors
        ? (darkDynamic ??
              ColorScheme.fromSeed(
                seedColor: seedColor,
                brightness: Brightness.dark,
              ))
        : ColorScheme.fromSeed(
            seedColor: seedColor,
            brightness: Brightness.dark,
          );

    // The app already uses a dark appearance throughout the UI.
    final scheme = darkScheme.harmonized();

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
    );
  }
}
