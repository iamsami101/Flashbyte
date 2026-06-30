import 'dart:io';

import 'package:flashbyte/classes/android_saf_service.dart';
import 'package:flutter/material.dart';
import 'package:external_path/external_path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const String useTlsKey = 'useTLS';
  static const String portKey = 'connectionPort';
  static const String downloadDirectoryKey = 'downloadDirectory';
  static const String dynamicColorsEnabledKey = 'dynamicColorsEnabled';
  static const String primaryColorKey = 'primaryColor';
  static const String useDarkModeKey = 'useDarkMode';
  static const int defaultPort = 8050;
  static const String defaultPrimaryColorName = 'green';

  static const Map<String, MaterialColor> primaryColorOptions = {
    'red': Colors.red,
    'green': Colors.green,
    'blue': Colors.blue,
    'amber': Colors.amber,
    'pink': Colors.pink,
    'yellow': Colors.yellow,
    'teal': Colors.teal,
  };

  static Future<bool> getUseTls() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(useTlsKey) ?? true;
  }

  static Future<int> getPort() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPort = prefs.getInt(portKey);
    if (savedPort == null || savedPort < 1 || savedPort > 65535) {
      return defaultPort;
    }
    return savedPort;
  }

  static Future<void> setPort(int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(portKey, port);
  }

  static Future<String> getDownloadDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final savedDirectory = prefs.getString(downloadDirectoryKey);
    if (savedDirectory != null && savedDirectory.isNotEmpty) {
      return savedDirectory;
    }
    return getDefaultDownloadDirectory();
  }

  static Future<void> setDownloadDirectory(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(downloadDirectoryKey, path);
  }

  static String formatDownloadDirectoryForDisplay(String path) {
    return AndroidSafService.trimPathForDisplay(path);
  }

  static Future<String> getDefaultDownloadDirectory() async {
    if (Platform.isAndroid) {
      return ExternalPath.getExternalStoragePublicDirectory(
        ExternalPath.DIRECTORY_DOWNLOAD,
      );
    }

    final downloadsDirectory = await getDownloadsDirectory();
    if (downloadsDirectory != null) {
      return downloadsDirectory.path;
    }

    final documentsDirectory = await getApplicationDocumentsDirectory();
    return documentsDirectory.path;
  }

  static Future<bool> getDynamicColorsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(dynamicColorsEnabledKey) ?? false;
  }

  static Future<void> setDynamicColorsEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(dynamicColorsEnabledKey, value);
  }

  static Future<String> getPrimaryColorName() async {
    final prefs = await SharedPreferences.getInstance();
    final colorName = prefs.getString(primaryColorKey);
    if (colorName == null || !primaryColorOptions.containsKey(colorName)) {
      return defaultPrimaryColorName;
    }
    return colorName;
  }

  static Future<void> setPrimaryColorName(String colorName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(primaryColorKey, colorName);
  }

  static Future<bool> getUseDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(useDarkModeKey) ?? true;
  }

  static Future<void> setUseDarkMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(useDarkModeKey, value);
  }

  static MaterialColor getPrimaryColorByName(String colorName) {
    return primaryColorOptions[colorName] ??
        primaryColorOptions[defaultPrimaryColorName]!;
  }
}
