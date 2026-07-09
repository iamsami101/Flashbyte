import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/classes/app_settings.dart';
import 'package:flashbyte/classes/device_discovery_service.dart';
import 'package:flashbyte/classes/socket_service.dart';
import 'package:flashbyte/pages/settings_page.dart';
import 'package:flashbyte/tcp_socket_pages/qr_code_scan.dart';
import 'package:flashbyte/tcp_socket_pages/tcp_chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:loading_indicator_m3e/loading_indicator_m3e.dart';
import 'package:qr_flutter/qr_flutter.dart';

class FileSelectionPage extends StatefulWidget {
  final int initialTabIndex;

  const FileSelectionPage({super.key, this.initialTabIndex = 0});

  @override
  State<FileSelectionPage> createState() => _FileSelectionPageState();
}

class _FileSelectionPageState extends State<FileSelectionPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController receiverIpController = TextEditingController();
  final TextEditingController _deviceNameController = TextEditingController();
  List<FastFilePickerPath> selectedFiles = [];
  late final TabController _tabController;

  bool isPickingFile = false;
  bool isConnectingToSender = false;
  bool isReceiveStarting = false;
  bool receiveStarted = false;
  bool chatOpened = false;
  bool isDiscovering = true;
  int selectedTabIndex = 0;

  String? receiveIpAddress;
  String? deviceName;
  String? _deviceId;
  List<DiscoveredDevice> discoveredDevices = const [];
  StreamSubscription? _socketSubscription;
  StreamSubscription<List<DiscoveredDevice>>? _discoverySubscription;
  Timer? _nameSaveDebounce;
  int _serverRestartGeneration = 0;

  @override
  void initState() {
    super.initState();
    selectedTabIndex = widget.initialTabIndex;
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTabIndex,
    );
    _tabController.addListener(_handleTabChanged);

    _socketSubscription = SocketService.instance.messageStream.listen(
      _handleSocketMessage,
    );
    _discoverySubscription = DeviceDiscoveryService.instance.devicesStream
        .listen((devices) {
          if (!mounted) return;
          setState(() {
            discoveredDevices = devices;
            isDiscovering = false;
          });
        });
    _initializeDiscovery();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _ensureReceiveReady();
      }
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    _socketSubscription?.cancel();
    _discoverySubscription?.cancel();
    _nameSaveDebounce?.cancel();
    receiverIpController.dispose();
    _deviceNameController.dispose();
    SocketService.instance.stopConnection();
    unawaited(DeviceDiscoveryService.instance.stop());
    super.dispose();
  }

  Future<void> _initializeDiscovery() async {
    try {
      final name = await AppSettings.getDeviceName();
      final id = await AppSettings.getDeviceId();
      if (!mounted) return;
      setState(() {
        deviceName = name;
        _deviceId = id;
        _deviceNameController.text = name;
      });
      await DeviceDiscoveryService.instance.startDiscovery(localDeviceId: id);
      if (!mounted) return;
      setState(() {
        discoveredDevices = DeviceDiscoveryService.instance.devices;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        isDiscovering = false;
      });
    }
  }

  Future<void> _pickFiles() async {
    setState(() {
      isPickingFile = true;
    });

    try {
      final pickedFiles = await FastFilePicker.pickMultipleFiles();
      if (!mounted) return;

      setState(() {
        selectedFiles = pickedFiles ?? [];
      });
    } finally {
      if (mounted) {
        setState(() {
          isPickingFile = false;
        });
      }
    }
  }

  void _handleTabChanged() {
    if (_tabController.indexIsChanging) {
      return;
    }

    if (selectedTabIndex == _tabController.index) {
      return;
    }

    setState(() {
      selectedTabIndex = _tabController.index;
    });

    _ensureReceiveReady();
  }

  Future<void> _ensureReceiveReady() async {
    if (!SocketService.instance.isHosting && receiveStarted) {
      receiveStarted = false;
    }

    if (SocketService.instance.isHosting) {
      receiveStarted = true;
    }

    if (receiveStarted || isReceiveStarting) {
      if (receiveIpAddress == null) {
        await _loadReceiveIpAddress();
      }
      return;
    }

    setState(() {
      isReceiveStarting = true;
    });

    try {
      final useTLS = await AppSettings.getUseTls();
      final port = await AppSettings.getPort();
      if (!SocketService.instance.isHosting) {
        await SocketService.instance.startHost(
          '0.0.0.0',
          port: port,
          useTLS: useTLS,
        );
      }
      final name = deviceName ?? await AppSettings.getDeviceName();
      final id = _deviceId ?? await AppSettings.getDeviceId();
      await DeviceDiscoveryService.instance.startAdvertising(
        deviceId: id,
        name: name,
        port: port,
        usesTls: useTLS,
      );
      receiveStarted = true;
      await _loadReceiveIpAddress();
    } catch (e) {
      if (!mounted) return;
      await _showErrorDialog(
        title: 'Receive Error',
        message: 'Failed to start receiver:\n${e.toString()}',
      );
    } finally {
      if (mounted) {
        setState(() {
          isReceiveStarting = false;
        });
      }
    }
  }

  Future<void> _restartServer() async {
    final generation = ++_serverRestartGeneration;
    await DeviceDiscoveryService.instance.stopAdvertising();
    SocketService.instance.stopConnection();
    receiveStarted = false;

    if (!mounted || generation != _serverRestartGeneration) {
      return;
    }
    await _ensureReceiveReady();
  }

  Future<void> _refreshAdvertisement() async {
    if (!SocketService.instance.isHosting) {
      return;
    }

    final name = deviceName ?? await AppSettings.getDeviceName();
    final id = _deviceId ?? await AppSettings.getDeviceId();
    final port = await AppSettings.getPort();
    final useTLS = await AppSettings.getUseTls();
    await DeviceDiscoveryService.instance.startAdvertising(
      deviceId: id,
      name: name,
      port: port,
      usesTls: useTLS,
    );
  }

  void _scheduleDeviceNameSave(String value) {
    setState(() {
      deviceName = value;
    });
    _nameSaveDebounce?.cancel();
    _nameSaveDebounce = Timer(
      const Duration(milliseconds: 400),
      _saveDeviceName,
    );
  }

  Future<void> _saveDeviceName() async {
    _nameSaveDebounce?.cancel();
    final name = _deviceNameController.text.trim();
    if (name.isEmpty) {
      final savedName = await AppSettings.getDeviceName();
      if (!mounted) return;
      setState(() {
        deviceName = savedName;
        _deviceNameController.text = savedName;
      });
      return;
    }

    await AppSettings.setDeviceName(name);
    if (!mounted) return;
    setState(() {
      deviceName = name;
      if (_deviceNameController.text != name) {
        _deviceNameController.text = name;
      }
    });
    await _refreshAdvertisement();
  }

  Future<void> _generateDeviceName() async {
    _nameSaveDebounce?.cancel();
    final name = await AppSettings.generateDeviceName();
    if (!mounted) return;
    setState(() {
      deviceName = name;
      _deviceNameController.text = name;
    });
    await _refreshAdvertisement();
  }

  Future<void> _loadReceiveIpAddress() async {
    String? foundIp;

    for (final interface in await NetworkInterface.list()) {
      for (final address in interface.addresses) {
        if (address.type == InternetAddressType.IPv4) {
          foundIp = address.address;
          if (foundIp.startsWith('192.168.')) {
            break;
          }
        }
      }
      if (foundIp != null && foundIp.startsWith('192.168.')) {
        break;
      }
    }

    if (!mounted) return;
    setState(() {
      receiveIpAddress = foundIp;
    });
  }

  void _submitReceiverAddress(String value) {
    final ip = value.trim();
    if (ip.isEmpty) {
      showScaffoldSnackbar("Receiver IP can't be empty");
      return;
    }

    _connectToReceiver(ip);
  }

  Future<void> _scanReceiverQr() async {
    final ip = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => QrCodeScanPage(
          onScanned: (value) => Navigator.pop(context, value),
        ),
      ),
    );

    if (!mounted || ip == null || ip.isEmpty) {
      return;
    }

    receiverIpController.text = ip;
    _connectToReceiver(ip);
  }

  Future<void> _connectToReceiver(
    String ip, {
    int? advertisedPort,
    bool? advertisedTls,
  }) async {
    if (selectedFiles.isEmpty) {
      showScaffoldSnackbar("Select at least one file first");
      return;
    }
    if (isConnectingToSender) {
      return;
    }

    setState(() {
      isConnectingToSender = true;
      chatOpened = false;
    });

    try {
      await DeviceDiscoveryService.instance.stopAdvertising();
      receiveStarted = false;
      final useTLS = advertisedTls ?? await AppSettings.getUseTls();
      final port = advertisedPort ?? await AppSettings.getPort();
      await SocketService.instance.connectToHost(
        ip,
        port: port,
        useTLS: useTLS,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isConnectingToSender = false;
      });
      await _showErrorDialog(
        title: 'Connection Error',
        message: 'Could not connect to receiver:\n${e.toString()}',
      );
    }
  }

  void _connectToDiscoveredDevice(DiscoveredDevice device) {
    receiverIpController.text = device.address;
    _connectToReceiver(
      device.address,
      advertisedPort: device.port,
      advertisedTls: device.usesTls,
    );
  }

  void _handleSocketMessage(Map<String, dynamic> message) {
    if (!mounted) return;

    final status = message['status'];

    switch (status) {
      case 'client_connected':
        unawaited(DeviceDiscoveryService.instance.stopAdvertising());
        _openChatIfNeeded(initialFiles: const []);
        break;
      case 'connected_to_host':
        if (selectedTabIndex == 0) {
          _openChatIfNeeded(initialFiles: selectedFiles);
        }
        break;
      case 'error':
        setState(() {
          isConnectingToSender = false;
        });
        if (chatOpened) {
          return;
        }
        if (selectedTabIndex == 0) {
          SocketService.instance.stopConnection();
          unawaited(_restartServer());
        }
        _showErrorDialog(
          title: 'Connection Error',
          message: message['message'] ?? 'Unknown error',
        );
        break;
    }
  }

  void _openChatIfNeeded({
    required List<FastFilePickerPath> initialFiles,
  }) {
    if (chatOpened) {
      return;
    }

    chatOpened = true;
    isConnectingToSender = false;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TcpChatPage(initialFiles: initialFiles),
      ),
    ).then((_) async {
      if (!mounted) return;
      setState(() {
        chatOpened = false;
        isConnectingToSender = false;
        if (selectedTabIndex == 1) {
          receiveStarted = false;
        }
      });
      await _ensureReceiveReady();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Flashbyte"),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: _settingsLocked ? null : _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildTabPage(_buildSendTab()),
            _buildTabPage(_buildReceiveTab()),
          ],
        ),
      ),
      bottomNavigationBar: Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          child: TabBar(
            indicatorSize: TabBarIndicatorSize.label,
            dividerHeight: 0,
            indicatorAnimation: TabIndicatorAnimation.elastic,
            labelColor: Theme.of(context).colorScheme.onPrimaryContainer,
            // indicator: BoxDecoration(),
            controller: _tabController,
            onTap: (index) {
              if (selectedTabIndex != index) {
                setState(() {
                  selectedTabIndex = index;
                });
              }
              if (index == 1) {
                _ensureReceiveReady();
              } else {
                _ensureReceiveReady();
              }
            },
            tabs: const [
              Tab(
                iconMargin: EdgeInsets.symmetric(horizontal: 20, vertical: 3),
                icon: Icon(Icons.upload_rounded),
                text: "Send",
              ),
              Tab(
                iconMargin: EdgeInsets.symmetric(horizontal: 20, vertical: 3),
                icon: Icon(Icons.download_rounded),
                text: "Receive",
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabPage(Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Center(
        child: ConstrainedBox(
          constraints: (Platform.isAndroid || Platform.isIOS)
              ? const BoxConstraints()
              : const BoxConstraints(maxWidth: 500),
          child: child,
        ),
      ),
    );
  }

  Widget _buildSendTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 20,
        children: [
          _buildBrandHeader(
            icon: Icons.upload_file_rounded,
            title: "Send files",
            subtitle:
                "Pick files, then choose a nearby receiver or use its IP address.",
          ),
          _buildSelectedFilesCard(),
          _buildAvailableDevicesCard(),
          SizedBox(
            height: 52,
            child: Row(
              spacing: 12,
              children: [
                Expanded(
                  child: TextField(
                    controller: receiverIpController,
                    enabled: !isPickingFile && !isConnectingToSender,
                    textInputAction: TextInputAction.done,
                    onSubmitted: _submitReceiverAddress,
                    decoration: InputDecoration(
                      label: const Text("Receiver IP"),
                      hintText: "192.168.xx.xx",
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: double.infinity,
                  child: Card(
                    margin: EdgeInsets.zero,
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: isConnectingToSender
                          ? null
                          : (!Platform.isAndroid && !Platform.isIOS)
                          ? () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  behavior: SnackBarBehavior.floating,
                                  content: Text(
                                    "QR Scanning is not supported on this OS.",
                                  ),
                                ),
                              );
                            }
                          : _scanReceiverQr,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Icon(
                          Icons.qr_code_scanner_rounded,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (isConnectingToSender) const Center(child: LoadingIndicatorM3E()),
        ],
      ),
    );
  }

  Widget _buildReceiveTab() {
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 20,
        children: [
          _buildBrandHeader(
            icon: Icons.wifi_tethering_rounded,
            title: "Receive files",
            subtitle: "Scan this QR code with another device to start sharing.",
          ),
          _buildReceiverIdentityCard(),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 20,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 360,
                      maxHeight: 360,
                      minWidth: 160,
                      minHeight: 160,
                    ),
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox.square(
                        dimension: 360,
                        child: AnimatedSize(
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeOutCubic,
                          child: (isReceiveStarting || receiveIpAddress == null)
                              ? const Center(
                                  child: LoadingIndicatorM3E(),
                                )
                              : QrImageView(
                                  data: receiveIpAddress!,
                                  padding: const EdgeInsets.all(20),
                                  backgroundColor: Colors.white,
                                ),
                        ),
                      ),
                    ),
                  ),
                  SelectableText(
                    receiveIpAddress ?? "Fetching...",
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvailableDevicesCard() {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    "Available nearby",
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                AnimatedSwitcher(
                  duration: 180.ms,
                  child: isDiscovering
                      ? SizedBox.square(
                          key: const ValueKey('discovering'),
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.primary,
                          ),
                        )
                      : Icon(
                          Icons.radar_rounded,
                          key: const ValueKey('ready'),
                          size: 20,
                          color: colorScheme.primary,
                        ),
                ),
              ],
            ),
            AnimatedSwitcher(
              duration: 220.ms,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: discoveredDevices.isEmpty
                  ? Padding(
                      key: const ValueKey('no-devices'),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        isDiscovering
                            ? "Looking for receivers on this network..."
                            : "No receivers found yet. You can still use an IP or QR code.",
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Column(
                      key: ValueKey(
                        discoveredDevices.map((device) => device.id).join(),
                      ),
                      spacing: 8,
                      children: [
                        for (final (index, device) in discoveredDevices.indexed)
                          _buildDeviceTile(device)
                              .animate()
                              .fadeIn(
                                duration: 180.ms,
                                delay: (index * 70).ms,
                              )
                              .slideY(
                                begin: 0.08,
                                end: 0,
                                curve: Curves.easeOutCubic,
                              ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceTile(DiscoveredDevice device) {
    final colorScheme = Theme.of(context).colorScheme;
    final canConnect =
        selectedFiles.isNotEmpty && !isPickingFile && !isConnectingToSender;

    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: canConnect ? () => _connectToDiscoveredDevice(device) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            child: Row(
              spacing: 12,
              children: [
                CircleAvatar(
                  backgroundColor: colorScheme.primaryContainer,
                  foregroundColor: colorScheme.onPrimaryContainer,
                  child: const Icon(Icons.devices_rounded, size: 20),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        "${device.address}:${device.port}${device.usesTls ? ' • Secure' : ''}",
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_rounded,
                  color: canConnect
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReceiverIdentityCard() {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      color: colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          spacing: 12,
          children: [
            Icon(
              Icons.broadcast_on_personal_rounded,
              color: colorScheme.onPrimaryContainer,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    "Visible as",
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colorScheme.onPrimaryContainer.withValues(
                        alpha: 0.72,
                      ),
                    ),
                  ),
                  TextField(
                    controller: _deviceNameController,
                    enabled: deviceName != null && !_settingsLocked,
                    onChanged: _scheduleDeviceNameSave,
                    onSubmitted: (_) => _saveDeviceName(),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: "Creating your name...",
                      hintStyle: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(
                            color: colorScheme.onPrimaryContainer.withValues(
                              alpha: 0.6,
                            ),
                          ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: "Generate a new name",
              onPressed: _settingsLocked ? null : _generateDeviceName,
              icon: const Icon(Icons.refresh_rounded),
              color: colorScheme.onPrimaryContainer,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrandHeader({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Column(
      spacing: 12,
      children: [
        Icon(
          icon,
          size: 48,
          color: Theme.of(context).colorScheme.primaryFixed,
        ),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.secondary,
          ),
        ),
      ],
    );
  }

  Future<void> _openSettings() async {
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsPage(
          locked: _settingsLocked,
          onServerSettingsChanged: _restartServer,
        ),
      ),
    );
    if (!mounted) return;
    await _ensureReceiveReady();
  }

  Widget _buildSelectedFilesCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          spacing: 14,
          children: [
            Text(
              _selectionSummary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: isPickingFile || isConnectingToSender
                    ? null
                    : _pickFiles,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 10,
                      children: [
                        Icon(
                          selectedFiles.isEmpty
                              ? Icons.attach_file_rounded
                              : Icons.swap_horiz_rounded,
                        ),
                        Text(
                          isPickingFile
                              ? "Opening picker..."
                              : selectedFiles.isEmpty
                              ? "Pick files"
                              : "Change files",
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _selectionSummary {
    final count = selectedFiles.length;
    if (count == 0) {
      return "No files selected";
    }
    if (count == 1) {
      return selectedFiles.first.name;
    }
    return "$count files selected";
  }

  void showScaffoldSnackbar(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }

  Future<void> _showErrorDialog({
    required String title,
    required String message,
  }) async {
    if (!mounted) return;
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Close Dialog",
      pageBuilder: (context, animation, secondaryAnimation) => AlertDialog(
        title: Row(
          spacing: 10,
          children: [
            Icon(
              Icons.error_rounded,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            Text(title),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            Text(message),
            SizedBox(
              width: double.infinity,
              child: Card(
                margin: EdgeInsets.zero,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(context),
                  child: const Padding(
                    padding: EdgeInsets.all(13),
                    child: Center(child: Text("Dismiss")),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _settingsLocked =>
      isConnectingToSender || isReceiveStarting || chatOpened;
}
