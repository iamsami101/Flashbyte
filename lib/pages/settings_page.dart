import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/classes/app_appearance_controller.dart';
import 'package:flashbyte/classes/android_saf_service.dart';
import 'package:flashbyte/classes/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:saf_util/saf_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  final bool locked;

  const SettingsPage({super.key, this.locked = false});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final AppAppearanceController _appearanceController =
      AppAppearanceController.instance;

  bool _useTLS = true;
  bool _isLoading = true;
  late final TextEditingController _portController;
  late final TextEditingController _downloadDirectoryController;
  late final FocusNode _portFocusNode;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController();
    _downloadDirectoryController = TextEditingController();
    _portFocusNode = FocusNode();
    _portFocusNode.addListener(_handlePortFocusChange);
    _loadSettings();
  }

  @override
  void dispose() {
    _portFocusNode
      ..removeListener(_handlePortFocusChange)
      ..dispose();
    _portController.dispose();
    _downloadDirectoryController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final port = await AppSettings.getPort();
    final downloadDirectory = await AppSettings.getDownloadDirectory();
    if (!mounted) return;
    setState(() {
      _useTLS = prefs.getBool(AppSettings.useTlsKey) ?? true;
      _portController.text = port.toString();
      _downloadDirectoryController.text =
          AppSettings.formatDownloadDirectoryForDisplay(downloadDirectory);
      _isLoading = false;
    });
  }

  Future<void> _toggleTLS(bool value) async {
    if (widget.locked) {
      return;
    }

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
                  Icon(
                    Icons.info_rounded,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
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
                    onChanged: (v) =>
                        setDialogState(() => dontShowChecked = v!),
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

    await prefs.setBool(AppSettings.useTlsKey, value);
    setState(() {
      _useTLS = value;
    });
  }

  void _handlePortFocusChange() {
    if (!_portFocusNode.hasFocus) {
      _savePort();
    }
  }

  Future<void> _savePort() async {
    if (widget.locked) {
      return;
    }

    final portText = _portController.text.trim();
    if (portText.isEmpty) {
      _portController.text = (await AppSettings.getPort()).toString();
      return;
    }

    final port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) {
      _portController.text = (await AppSettings.getPort()).toString();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Port must be between 1 and 65535.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    await AppSettings.setPort(port);
    _portController.text = port.toString();
  }

  Future<void> _pickDownloadDirectory() async {
    if (widget.locked) {
      return;
    }

    if (Theme.of(context).platform == TargetPlatform.android) {
      final currentDirectory = await AppSettings.getDownloadDirectory();
      final pickedDirectory = await SafUtil().pickDirectory(
        initialUri: AndroidSafService.isTreeUri(currentDirectory)
            ? currentDirectory
            : null,
        writePermission: true,
        persistablePermission: true,
      );
      if (!mounted || pickedDirectory == null) {
        return;
      }

      await AppSettings.setDownloadDirectory(pickedDirectory.uri);
      _downloadDirectoryController.text =
          AppSettings.formatDownloadDirectoryForDisplay(pickedDirectory.uri);
      return;
    }

    final pickedFolder = await FastFilePicker.pickFolder(
      writePermission: true,
    );
    if (!mounted || pickedFolder == null) {
      return;
    }

    final folderPath = pickedFolder.path;
    if (folderPath == null || folderPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That folder cannot be used on this device.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    await AppSettings.setDownloadDirectory(folderPath);
    _downloadDirectoryController.text =
        AppSettings.formatDownloadDirectoryForDisplay(folderPath);
  }

  Future<void> _resetDownloadDirectory() async {
    if (widget.locked) {
      return;
    }

    final defaultDirectory = await AppSettings.getDefaultDownloadDirectory();
    await AppSettings.setDownloadDirectory(defaultDirectory);
    if (!mounted) return;
    setState(() {
      _downloadDirectoryController.text =
          AppSettings.formatDownloadDirectoryForDisplay(defaultDirectory);
    });
  }

  Future<void> _toggleDynamicColors(bool value) async {
    await _appearanceController.setUseDynamicColors(value);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _selectPrimaryColor(String colorName) async {
    if (_appearanceController.useDynamicColors) {
      return;
    }
    await _appearanceController.setPrimaryColorName(colorName);
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Settings"),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    "Appearance",
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ListTile(
                  title: const Text("Dark Mode"),
                  subtitle: const Text(
                    "Use the app's dark theme instead of the light theme.",
                  ),
                  trailing: Switch(
                    value: _appearanceController.useDarkMode,
                    onChanged: (value) async {
                      await _appearanceController.setUseDarkMode(value);
                      if (!mounted) return;
                      setState(() {});
                    },
                  ),
                ),
                ListTile(
                  title: const Text("Material You Dynamic Colors"),
                  subtitle: const Text(
                    "Use the device wallpaper color scheme when supported.",
                  ),
                  trailing: Switch(
                    value: _appearanceController.useDynamicColors,
                    onChanged: _toggleDynamicColors,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: AppSettings.primaryColorOptions.entries.map((
                      entry,
                    ) {
                      final isSelected =
                          _appearanceController.primaryColorName == entry.key;
                      return ChoiceChip(
                        label: Text(_capitalize(entry.key)),
                        selected: isSelected,
                        onSelected: _appearanceController.useDynamicColors
                            ? null
                            : (_) => _selectPrimaryColor(entry.key),
                        avatar: CircleAvatar(
                          backgroundColor: entry.value,
                          radius: 8,
                        ),
                      );
                    }).toList(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    "Connection",
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ListTile(
                  title: const Text("TLS Encryption"),
                  subtitle: Text(
                    widget.locked
                        ? "Disconnect before changing TLS settings."
                        : "Encrypt file transfers using TLS for secure communication between devices",
                  ),
                  trailing: Switch(
                    value: _useTLS,
                    onChanged: widget.locked ? null : _toggleTLS,
                  ),
                ),
                ListTile(
                  title: const Text("Port"),
                  subtitle: Text(
                    widget.locked
                        ? "Disconnect before changing the connection port."
                        : "Used for both hosting and connecting.",
                  ),
                  trailing: SizedBox(
                    width: 96,
                    child: TextField(
                      controller: _portController,
                      focusNode: _portFocusNode,
                      enabled: !widget.locked,
                      textAlign: TextAlign.end,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      onSubmitted: (_) => _savePort(),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
                ListTile(
                  title: const Text("Download Folder"),
                  subtitle: Text(
                    widget.locked
                        ? "Disconnect before changing the destination folder."
                        : "Files received on this device will be saved here.",
                  ),
                  trailing: SizedBox(
                    width: 260,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _downloadDirectoryController,
                            readOnly: true,
                            enabled: !widget.locked,
                            onTap: _pickDownloadDirectory,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              suffixIcon: Icon(Icons.folder_open_rounded),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Reset folder',
                          onPressed: widget.locked
                              ? null
                              : _resetDownloadDirectory,
                          icon: const Icon(Icons.restart_alt_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  String _capitalize(String value) {
    if (value.isEmpty) {
      return value;
    }
    return "${value[0].toUpperCase()}${value.substring(1)}";
  }
}
