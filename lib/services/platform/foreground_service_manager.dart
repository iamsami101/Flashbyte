import 'dart:io';

import 'package:flutter/services.dart';

class ForegroundServiceManager {
  static const _channel = MethodChannel('flashbyte/foreground_service');

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startForegroundService');
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopForegroundService');
    } catch (_) {}
  }
}
