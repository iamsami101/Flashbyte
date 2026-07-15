import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/classes/app_settings.dart';
import 'package:flashbyte/classes/device_discovery_service.dart';
import 'package:flashbyte/classes/socket_service.dart';
import 'package:flashbyte/classes/user_facing_error.dart';
import 'package:flashbyte/pages/settings_page.dart';
import 'package:flashbyte/tcp_socket_pages/incoming_transfer_offer_page.dart';
import 'package:flashbyte/tcp_socket_pages/outgoing_transfer_offer_page.dart';
import 'package:flashbyte/tcp_socket_pages/tcp_chat_page.dart';
import 'package:flashbyte/widgets/slow_m3e_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:heroine/heroine.dart';
import 'package:loading_indicator_m3e/loading_indicator_m3e.dart';

class FileSelectionPage extends StatefulWidget {
  final int initialTabIndex;

  const FileSelectionPage({super.key, this.initialTabIndex = 0});

  @override
  State<FileSelectionPage> createState() => _FileSelectionPageState();
}

enum _ServerNetworkMode { hotspot, wifi, mobile, ethernet, vpn, offline, other }

class _FileSelectionPageState extends State<FileSelectionPage>
    with TickerProviderStateMixin {
  static const double _wideLayoutBreakpoint = 1000;
  static const double _wideLayoutMaxWidth = 1320;
  static const double _receiverVisualMinHeight = 280;

  final TextEditingController _deviceNameController = TextEditingController();
  final Map<String, AnimationController> _deviceShakeControllers = {};
  List<FastFilePickerPath> selectedFiles = [];
  late final TabController _tabController;

  bool isPickingFile = false;
  bool isConnectingToSender = false;
  bool isReceiveStarting = false;
  bool receiveStarted = false;
  bool chatOpened = false;
  bool _incomingOfferOpen = false;
  bool _outgoingOfferOpen = false;
  bool isDiscovering = true;
  int selectedTabIndex = 0;

  String? deviceName;
  String? _deviceId;
  DiscoveredDevice? _selectedReceiverPreview;
  bool _selectedSenderUsesTls = false;
  List<DiscoveredDevice> discoveredDevices = const [];
  StreamSubscription? _socketSubscription;
  StreamSubscription<List<DiscoveredDevice>>? _discoverySubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _nameSaveDebounce;
  Timer? _networkRefreshTimer;
  int _serverRestartGeneration = 0;
  bool _receiveServerIntentionallyStopped = false;
  _ServerNetworkMode? _serverNetworkMode;
  String _networkLabel = "Checking network";
  IconData _networkIcon = Icons.network_check_rounded;

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
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      _updateNetworkStatus,
    );
    _networkRefreshTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refreshNetworkStatus()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _initializeNetworking();
        unawaited(_refreshNetworkStatus());
      }
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    for (final controller in _deviceShakeControllers.values) {
      controller.dispose();
    }
    _socketSubscription?.cancel();
    _discoverySubscription?.cancel();
    _connectivitySubscription?.cancel();
    _nameSaveDebounce?.cancel();
    _networkRefreshTimer?.cancel();
    _deviceNameController.dispose();
    unawaited(SocketService.instance.stopConnectionGracefully());
    unawaited(DeviceDiscoveryService.instance.stop());
    super.dispose();
  }

  Future<void> _refreshNetworkStatus() async {
    final results = await Connectivity().checkConnectivity();
    await _updateNetworkStatus(results);
  }

  Future<void> _updateNetworkStatus(
    List<ConnectivityResult> results,
  ) async {
    var isHotspot = false;
    if (Platform.isAndroid) {
      try {
        isHotspot =
            await const MethodChannel(
              'flashbyte/network_status',
            ).invokeMethod<bool>('isHotspotEnabled') ??
            false;
      } on PlatformException {
        isHotspot = false;
      }
    }

    final nextNetworkMode = _networkModeFor(results, isHotspot: isHotspot);
    final previousNetworkMode = _serverNetworkMode;

    if (!mounted) return;
    setState(() {
      _serverNetworkMode = nextNetworkMode;
      if (isHotspot) {
        _networkLabel = "Hotspot active";
        _networkIcon = Icons.wifi_tethering_rounded;
      } else if (results.contains(ConnectivityResult.wifi)) {
        _networkLabel = "Connected to Wi-Fi";
        _networkIcon = Icons.wifi_rounded;
      } else if (results.contains(ConnectivityResult.mobile)) {
        _networkLabel = "Using mobile data";
        _networkIcon = Icons.signal_cellular_alt_rounded;
      } else if (results.contains(ConnectivityResult.ethernet)) {
        _networkLabel = "Connected by Ethernet";
        _networkIcon = Icons.lan_rounded;
      } else if (results.contains(ConnectivityResult.vpn)) {
        _networkLabel = "Connected through VPN";
        _networkIcon = Icons.vpn_lock_rounded;
      } else {
        _networkLabel = "No network connection";
        _networkIcon = Icons.signal_wifi_off_rounded;
      }
    });
    if (previousNetworkMode != null &&
        previousNetworkMode != nextNetworkMode &&
        _shouldReconnectServerFor(nextNetworkMode)) {
      unawaited(_restartServer());
    }
  }

  _ServerNetworkMode _networkModeFor(
    List<ConnectivityResult> results, {
    required bool isHotspot,
  }) {
    if (isHotspot) {
      return _ServerNetworkMode.hotspot;
    }
    if (results.contains(ConnectivityResult.wifi)) {
      return _ServerNetworkMode.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return _ServerNetworkMode.mobile;
    }
    if (results.contains(ConnectivityResult.ethernet)) {
      return _ServerNetworkMode.ethernet;
    }
    if (results.contains(ConnectivityResult.vpn)) {
      return _ServerNetworkMode.vpn;
    }
    if (results.contains(ConnectivityResult.none)) {
      return _ServerNetworkMode.offline;
    }
    return _ServerNetworkMode.other;
  }

  bool _shouldReconnectServerFor(_ServerNetworkMode mode) {
    return mode == _ServerNetworkMode.hotspot ||
        mode == _ServerNetworkMode.mobile;
  }

  Future<void> _initializeNetworking() async {
    final name = await AppSettings.getDeviceName();
    final id = await AppSettings.getDeviceId();
    if (!mounted) return;
    setState(() {
      deviceName = name;
      _deviceId = id;
      _deviceNameController.text = name;
    });

    try {
      final port = await AppSettings.getPort();
      await DeviceDiscoveryService.instance.startDiscovery(
        localDeviceId: id,
        port: port,
      );
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

    if (mounted) {
      await _ensureReceiveReady();
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
  }

  Future<void> _ensureReceiveReady() async {
    _receiveServerIntentionallyStopped = false;
    if (!SocketService.instance.isHosting && receiveStarted) {
      receiveStarted = false;
    }

    if (SocketService.instance.isHosting) {
      receiveStarted = true;
    }

    if (receiveStarted || isReceiveStarting) {
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
    _receiveServerIntentionallyStopped = false;
    await DeviceDiscoveryService.instance.stopAdvertising();
    await SocketService.instance.stopConnectionGracefully();
    if (mounted) {
      setState(() {
        receiveStarted = false;
      });
    }

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

  Future<void> _connectToReceiver(
    String ip, {
    int? advertisedPort,
    bool? advertisedTls,
    DiscoveredDevice? receiverPreview,
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
      _selectedReceiverPreview = receiverPreview;
    });

    try {
      await DeviceDiscoveryService.instance.stopAdvertising();
      receiveStarted = false;
      final useTLS = await AppSettings.getUseTls();
      _selectedSenderUsesTls = useTLS;
      if (advertisedTls != null && advertisedTls != useTLS) {
        setState(() {
          isConnectingToSender = false;
          _selectedReceiverPreview = null;
        });
        await _showTlsMismatchDialog(localUsesTls: useTLS);
        await _restartServer();
        return;
      }
      final port = advertisedPort ?? await AppSettings.getPort();
      await _connectToHostWithStartupRetry(ip, port: port, useTLS: useTLS);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isConnectingToSender = false;
        _selectedReceiverPreview = null;
      });
      await _showErrorDialog(
        title: 'Connection Error',
        message: 'Could not connect to receiver:\n${e.toString()}',
      );
    }
  }

  Future<void> _connectToHostWithStartupRetry(
    String ip, {
    required int port,
    required bool useTLS,
  }) async {
    try {
      await SocketService.instance.connectToHost(
        ip,
        port: port,
        useTLS: useTLS,
      );
    } on SocketStartupCancelled {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await SocketService.instance.connectToHost(
        ip,
        port: port,
        useTLS: useTLS,
      );
    }
  }

  void _connectToDiscoveredDevice(DiscoveredDevice device) {
    _connectToReceiver(
      device.address,
      advertisedPort: device.port,
      advertisedTls: device.usesTls,
      receiverPreview: device,
    );
  }

  Future<void> _showTlsMismatchDialog({required bool localUsesTls}) {
    return _showErrorDialog(
      title: 'TLS Settings Do Not Match',
      message: localUsesTls
          ? 'This device has TLS enabled, but the selected device has TLS disabled.\n\nDisable TLS on this device, or enable TLS on the other device, then try again.'
          : 'This device has TLS disabled, but the selected device has TLS enabled.\n\nEnable TLS on this device, or disable TLS on the other device, then try again.',
    );
  }

  void _handleDiscoveredDeviceTap(DiscoveredDevice device) {
    if (selectedFiles.isEmpty) {
      final controller = _deviceShakeControllers.putIfAbsent(
        device.id,
        () => AnimationController(vsync: this, duration: 420.ms),
      );
      _showFileRequiredFeedback(controller);
      return;
    }
    _connectToDiscoveredDevice(device);
  }

  void _showFileRequiredFeedback(AnimationController controller) {
    controller.forward(from: 0);
    showScaffoldSnackbar("Select at least one file first");
  }

  void _handleSocketMessage(Map<String, dynamic> message) {
    if (!mounted) return;

    final status = message['status'];

    switch (status) {
      case 'client_connected':
        unawaited(DeviceDiscoveryService.instance.stopAdvertising());
        break;
      case 'start':
        if (message['pendingAcceptance'] == true && !chatOpened) {
          _openIncomingOffer(message);
        }
        break;
      case 'connected_to_host':
        _openOutgoingOffer();
        break;
      case 'hosting':
        setState(() {});
        break;
      case 'error':
        final wasConnecting = isConnectingToSender;
        setState(() {
          isConnectingToSender = false;
        });
        if (chatOpened || _incomingOfferOpen || _outgoingOfferOpen) {
          return;
        }
        if (wasConnecting || selectedTabIndex == 0) {
          unawaited(_restartServer());
        }
        _showErrorDialog(
          title: 'Connection Error',
          message: message['message'] ?? 'Unknown error',
        );
        break;
    }
  }

  void _openIncomingOffer(Map<String, dynamic> message) {
    if (_incomingOfferOpen || chatOpened) {
      return;
    }

    final fileId = message['fileId'] as String?;
    final fileName = message['fileName'] as String?;
    final fileSize = message['fileSize'] as int?;
    if (fileId == null || fileName == null || fileSize == null) {
      return;
    }

    _incomingOfferOpen = true;
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => IncomingTransferOfferPage(
              fileId: fileId,
              fileName: fileName,
              fileSize: fileSize,
              sender: SocketService.instance.connectedPeerInfo,
              onAccept: () {
                SocketService.instance.acceptTransfer(fileId);
                Navigator.of(context).pop(true);
              },
              onDecline: () {
                SocketService.instance.declineTransfer(fileId);
                Navigator.of(context).pop(false);
              },
            ),
          ),
        )
        .then((accepted) {
          if (!mounted) return;
          _incomingOfferOpen = false;
          if (accepted == true) {
            _openChatIfNeeded(initialFiles: const []);
          } else {
            unawaited(_restartServer());
          }
        });
  }

  void _openOutgoingOffer() {
    if (_outgoingOfferOpen || chatOpened || selectedFiles.isEmpty) {
      return;
    }

    _outgoingOfferOpen = true;
    final receiverPreview = _selectedReceiverPreview;
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => OutgoingTransferOfferPage(
              files: List<FastFilePickerPath>.from(selectedFiles),
              onStartSending: _sendSelectedFiles,
              onCancel: _cancelOutgoingOffer,
              senderName: deviceName ?? _deviceNameController.text,
              senderType: _localDeviceType,
              senderUsesTls: _selectedSenderUsesTls,
              receiverPreview: receiverPreview,
            ),
          ),
        )
        .then((accepted) async {
          if (!mounted) return;
          setState(() {
            _outgoingOfferOpen = false;
            isConnectingToSender = false;
            _selectedReceiverPreview = null;
          });
          if (accepted == true) {
            _openChatIfNeeded(initialFiles: const []);
          } else {
            await _restartServer();
          }
        });
  }

  DiscoveredDeviceType get _localDeviceType =>
      Platform.isAndroid || Platform.isIOS
      ? DiscoveredDeviceType.phone
      : DiscoveredDeviceType.laptop;

  void _sendSelectedFiles() {
    for (final pickedFile in selectedFiles) {
      final fileLocation = Platform.isAndroid && pickedFile.uri != null
          ? pickedFile.uri
          : pickedFile.path;
      if (fileLocation != null) {
        SocketService.instance.sendFile(fileLocation);
      }
    }
  }

  Future<void> _cancelOutgoingOffer() async {
    await SocketService.instance.cancelOutgoingOffer();
    await SocketService.instance.disconnect();
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
      });
      await _restartServer();
    });
  }

  @override
  Widget build(BuildContext context) {
    final useWideLayout =
        MediaQuery.sizeOf(context).width >= _wideLayoutBreakpoint;

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
        child: useWideLayout
            ? _buildWideLayout()
            : TabBarView(
                controller: _tabController,
                children: [
                  _buildTabPage(_buildSendTab()),
                  _buildTabPage(_buildReceiveTab()),
                ],
              ),
      ),
      bottomNavigationBar: useWideLayout
          ? null
          : Material(
              color: Theme.of(context).colorScheme.surface,
              child: SafeArea(
                top: false,
                child: TabBar(
                  indicatorSize: TabBarIndicatorSize.label,
                  dividerHeight: 0,
                  indicatorAnimation: TabIndicatorAnimation.elastic,
                  labelColor: Theme.of(
                    context,
                  ).colorScheme.onPrimaryContainer,
                  controller: _tabController,
                  onTap: (index) {
                    if (selectedTabIndex != index) {
                      setState(() {
                        selectedTabIndex = index;
                      });
                    }
                  },
                  tabs: const [
                    Tab(
                      iconMargin: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 3,
                      ),
                      icon: Icon(Icons.upload_rounded),
                      text: "Send",
                    ),
                    Tab(
                      iconMargin: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 3,
                      ),
                      icon: Icon(Icons.download_rounded),
                      text: "Receive",
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildWideLayout() {
    final colorScheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _wideLayoutMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildDesktopHeader(),
                const SizedBox(height: 24),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 24,
                    children: [
                      Expanded(
                        flex: 11,
                        child: _buildDesktopPanel(
                          icon: Icons.north_east_rounded,
                          title: "Send",
                          subtitle: "Choose files and connect to a receiver",
                          fillHeight: true,
                          child: _buildSendTab(showHeader: false),
                        ),
                      ),
                      Expanded(
                        flex: 9,
                        child: _buildDesktopPanel(
                          icon: Icons.south_west_rounded,
                          title: "Receive",
                          subtitle: "Keep this page open to stay discoverable",
                          fillHeight: true,
                          child: _buildReceiveTab(
                            showHeader: false,
                            fillHeight: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopHeader() {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(
                "File transfer",
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              Text(
                "Send and receive on your local network from one workspace.",
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        _buildDesktopStatusChip(
          icon: _networkIcon,
          label: _networkLabel,
        ),
        const SizedBox(width: 10),
        _buildDesktopStatusChip(
          icon: SocketService.instance.isHosting
              ? Icons.dns_rounded
              : Icons.portable_wifi_off_rounded,
          label: SocketService.instance.isSecureHosting
              ? "Secure server running"
              : SocketService.instance.isHosting
              ? "Server running"
              : "Server stopped",
          emphasized: SocketService.instance.isHosting,
        ),
      ],
    );
  }

  Widget _buildDesktopStatusChip({
    required IconData icon,
    required String label,
    bool emphasized = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = emphasized
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHigh;
    final foreground = emphasized
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          Icon(icon, size: 18, color: foreground),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopPanel({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
    bool fillHeight = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 24,
          children: [
            Row(
              spacing: 12,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: colorScheme.onPrimaryContainer),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (fillHeight) Expanded(child: child) else child,
          ],
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

  Widget _buildSendTab({bool showHeader = true}) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 20,
        children: [
          if (showHeader)
            _buildBrandHeader(
              icon: Icons.upload_file_rounded,
              title: "Send files",
              subtitle: "Pick files, then choose a nearby receiver.",
            ),
          _buildSelectedFilesCard(),
          _buildAvailableDevicesCard(),
          if (isConnectingToSender) const Center(child: LoadingIndicatorM3E()),
        ],
      ),
    );
  }

  Widget _buildReceiveTab({bool showHeader = true, bool fillHeight = false}) {
    if (fillHeight) {
      return CustomScrollView(
        primary: false,
        slivers: [
          if (showHeader) ...[
            SliverToBoxAdapter(
              child: _buildBrandHeader(
                icon: Icons.broadcast_on_personal_rounded,
                title: "Receive files",
                subtitle: "Stay visible to nearby devices while you wait.",
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 20)),
          ],
          SliverToBoxAdapter(child: _buildReceiverIdentityCard()),
          const SliverToBoxAdapter(child: SizedBox(height: 20)),
          SliverLayoutBuilder(
            builder: (context, constraints) {
              final remainingHeight =
                  constraints.viewportMainAxisExtent -
                  constraints.precedingScrollExtent;
              final visualHeight = math.max(
                _receiverVisualMinHeight,
                remainingHeight,
              );

              return SliverToBoxAdapter(
                child: SizedBox(
                  height: visualHeight,
                  child: _buildReceiverVisualCard(fillHeight: true),
                ),
              );
            },
          ),
        ],
      );
    }

    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 20,
      children: [
        if (showHeader)
          _buildBrandHeader(
            icon: Icons.broadcast_on_personal_rounded,
            title: "Receive files",
            subtitle: "Stay visible to nearby devices while you wait.",
          ),
        _buildReceiverIdentityCard(),
        _buildReceiverVisualCard(fillHeight: false),
      ],
    );
    return SingleChildScrollView(child: content);
  }

  Widget _buildReceiverVisualCard({required bool fillHeight}) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final indicatorSize = fillHeight
                ? math
                      .min(
                        300,
                        math.min(
                          constraints.maxWidth - 40,
                          constraints.maxHeight - 76,
                        ),
                      )
                      .clamp(120.0, 300.0)
                : 220.0;
            return Column(
              mainAxisSize: fillHeight ? MainAxisSize.max : MainAxisSize.min,
              children: [
                if (fillHeight) const Spacer(),
                SlowM3ELoadingIndicator(
                  size: indicatorSize.toDouble(),
                  isActive:
                      !_receiveServerIntentionallyStopped && !isReceiveStarting,
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: 8,
                  children: [
                    Icon(
                      _receiveServerIntentionallyStopped
                          ? Icons.portable_wifi_off_rounded
                          : isReceiveStarting
                          ? Icons.hourglass_top_rounded
                          : Icons.broadcast_on_personal_rounded,
                      size: 18,
                      color: _receiveServerIntentionallyStopped
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                    Text(
                      _receiveServerIntentionallyStopped
                          ? 'Receiver stopped'
                          : isReceiveStarting
                          ? 'Starting receiver'
                          : 'Visible to nearby devices',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                ),
                if (fillHeight) const Spacer(),
              ],
            );
          },
        ),
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
                            : "No ones around to send to.",
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
    final canTap = !isPickingFile && !isConnectingToSender;
    final shakeController = _deviceShakeControllers.putIfAbsent(
      device.id,
      () => AnimationController(vsync: this, duration: 420.ms),
    );

    final deviceCard = Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: canTap ? () => _handleDiscoveredDeviceTap(device) : null,
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
                  child: Icon(
                    device.type == DiscoveredDeviceType.laptop
                        ? Icons.laptop_rounded
                        : Icons.smartphone_rounded,
                    size: 20,
                  ),
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
                        device.usesTls
                            ? 'Nearby receiver • Secure'
                            : 'Nearby receiver',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontFeatures: const [
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_rounded,
                  color: canTap
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Heroine(
          tag: outgoingReceiverHeroineTag(device.id),
          motion: CupertinoMotion.bouncy(),
          child: deviceCard,
        )
        .animate(
          controller: shakeController,
          autoPlay: false,
        )
        .shake(
          duration: 420.ms,
          hz: 4,
          offset: const Offset(8, 0),
          rotation: 0,
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
                    onTapOutside: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
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
    if (!_receiveServerIntentionallyStopped) {
      await _ensureReceiveReady();
    }
  }

  Widget _buildSelectedFilesCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          spacing: 14,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _selectionSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (selectedFiles.isNotEmpty)
                  IconButton(
                    tooltip: "Clear selected files",
                    onPressed: isConnectingToSender
                        ? null
                        : () {
                            setState(() {
                              selectedFiles = [];
                            });
                          },
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            if (selectedFiles.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: selectedFiles.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      selectedFiles[index].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
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
      return "1 file selected";
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
    final colorScheme = Theme.of(context).colorScheme;
    final error = UserFacingError.from(message);

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
              color: colorScheme.onErrorContainer,
            ),
            Text(title),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            Text(error.message),
            if (error.hasDetails)
              Card(
                margin: EdgeInsets.zero,
                color: colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        error.details!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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
