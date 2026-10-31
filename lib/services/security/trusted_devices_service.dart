import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TrustedDevice {
  const TrustedDevice({
    required this.fingerprint,
    required this.name,
    required this.addedAt,
  });

  final String fingerprint;
  final String name;
  final DateTime addedAt;

  TrustedDevice copyWith({String? name}) => TrustedDevice(
    fingerprint: fingerprint,
    name: name ?? this.name,
    addedAt: addedAt,
  );

  Map<String, dynamic> toJson() => {
    'fingerprint': fingerprint,
    'name': name,
    'addedAt': addedAt.toIso8601String(),
  };

  factory TrustedDevice.fromJson(Map<String, dynamic> json) => TrustedDevice(
    fingerprint: json['fingerprint'] as String,
    name: json['name'] as String? ?? 'Unknown device',
    addedAt:
        DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
  );
}

/// Persistent list of trusted sending devices, keyed by the device's
/// unique TLS certificate fingerprint (SHA-256 hex).
class TrustedDevicesService {
  TrustedDevicesService._();
  static final TrustedDevicesService instance = TrustedDevicesService._();

  static const String _prefsKey = 'trustedDevices';

  final ValueNotifier<List<TrustedDevice>> devicesNotifier =
      ValueNotifier<List<TrustedDevice>>(const []);

  List<TrustedDevice> get devices => devicesNotifier.value;

  Future<void> load() async {
    devicesNotifier.value = await _read();
  }

  Future<List<TrustedDevice>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => TrustedDevice.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _write(List<TrustedDevice> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(list.map((d) => d.toJson()).toList()),
    );
    devicesNotifier.value = List.unmodifiable(list);
  }

  bool isTrusted(String? fingerprint) {
    if (fingerprint == null || fingerprint.isEmpty) return false;
    return devices.any((d) => d.fingerprint == fingerprint);
  }

  Future<void> addTrusted({
    required String fingerprint,
    required String name,
  }) async {
    if (fingerprint.isEmpty) return;
    final list = await _read();
    if (list.any((d) => d.fingerprint == fingerprint)) return;
    list.add(
      TrustedDevice(
        fingerprint: fingerprint,
        name: name,
        addedAt: DateTime.now(),
      ),
    );
    await _write(list);
  }

  Future<void> removeTrusted(String fingerprint) async {
    final list = await _read();
    list.removeWhere((d) => d.fingerprint == fingerprint);
    await _write(list);
  }

  /// Keeps the stored display name in sync when the peer reports a new one.
  /// Returns true if the name changed.
  Future<bool> updateNameIfTrusted(String? fingerprint, String? name) async {
    if (fingerprint == null ||
        fingerprint.isEmpty ||
        name == null ||
        name.isEmpty) {
      return false;
    }
    final list = await _read();
    final index = list.indexWhere((d) => d.fingerprint == fingerprint);
    if (index == -1) return false;
    if (list[index].name == name) return false;
    list[index] = list[index].copyWith(name: name);
    await _write(list);
    return true;
  }

  /// Syncs names from freshly discovered devices (uses cert fingerprint).
  Future<void> syncFromDiscovery(
    List<({String fingerprint, String name})> discovered,
  ) async {
    if (discovered.isEmpty) return;
    final list = await _read();
    var changed = false;
    for (final entry in discovered) {
      if (entry.fingerprint.isEmpty || entry.name.isEmpty) continue;
      final index = list.indexWhere(
        (d) => d.fingerprint == entry.fingerprint,
      );
      if (index != -1 && list[index].name != entry.name) {
        list[index] = list[index].copyWith(name: entry.name);
        changed = true;
      }
    }
    if (changed) {
      await _write(list);
    }
  }
}
