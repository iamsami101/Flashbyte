import 'package:flashbyte/app/app_settings.dart';
import 'package:flutter/foundation.dart';

class AppMotionController extends ChangeNotifier {
  AppMotionController._();

  static final AppMotionController instance = AppMotionController._();

  bool _disableAnimations = false;
  bool _disableReceiveShapeAnimation = false;

  bool get disableAnimations => _disableAnimations;
  bool get disableReceiveShapeAnimation => _disableReceiveShapeAnimation;

  Future<void> load() async {
    _disableAnimations = await AppSettings.getDisableAnimations();
    _disableReceiveShapeAnimation =
        await AppSettings.getDisableReceiveShapeAnimation();
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

  Future<void> setDisableReceiveShapeAnimation(bool value) async {
    if (_disableReceiveShapeAnimation == value) {
      return;
    }

    _disableReceiveShapeAnimation = value;
    notifyListeners();
    await AppSettings.setDisableReceiveShapeAnimation(value);
  }
}
