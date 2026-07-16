import 'package:flashbyte/classes/app_settings.dart';
import 'package:flutter/foundation.dart';

class AppMotionController extends ChangeNotifier {
  AppMotionController._();

  static final AppMotionController instance = AppMotionController._();

  bool _disableAnimations = false;

  bool get disableAnimations => _disableAnimations;

  Future<void> load() async {
    _disableAnimations = await AppSettings.getDisableAnimations();
    notifyListeners();
  }

  Future<void> setDisableAnimations(bool value) async {
    if (_disableAnimations == value) {
      return;
    }

    _disableAnimations = value;
    notifyListeners();
    await AppSettings.setDisableAnimations(value);
  }
}
