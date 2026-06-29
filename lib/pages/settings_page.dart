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

    // Show info dialog only when disabling TLS
    if (_useTLS && !value) {
      final dontShowAgain = prefs.getBool('dontShowTLSDialog') ?? false;
      if (!dontShowAgain) {
        bool dontShowChecked = false;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
              title: Row(
                spacing: 10,
                children: [
                  Icon(Icons.info_rounded, color: Theme.of(ctx).colorScheme.primary),
                  const Text('TLS Encryption'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 10,
                children: [
                  const Text(
                    'When TLS is disabled, both the sending and receiving device must have the same setting.\n\n'
                    'Make sure the other device also has TLS turned OFF, otherwise the connection will fail.',
                  ),
                  CheckboxListTile(
                    value: dontShowChecked,
                    onChanged: (v) => setDialogState(() => dontShowChecked = v!),
                    title: const Text("Don't show this again"),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        );

        if (proceed != true) return;
        if (dontShowChecked) await prefs.setBool('dontShowTLSDialog', true);
      }
    }

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
