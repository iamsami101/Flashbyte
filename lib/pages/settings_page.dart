import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _useTLS = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _useTLS = prefs.getBool('useTLS') ?? true;
    });
  }

  Future<void> _toggleTLS(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('useTLS', value);
    setState(() {
      _useTLS = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Settings"),
      ),
      body: ListView(
        children: [
          ListTile(
            title: const Text("TLS Encryption"),
            subtitle: const Text(
              "Encrypt file transfers using TLS for secure communication between devices",
            ),
            trailing: Switch(
              value: _useTLS,
              onChanged: _toggleTLS,
            ),
          ),
        ],
      ),
    );
  }
}
