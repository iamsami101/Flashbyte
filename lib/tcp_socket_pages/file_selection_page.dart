import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/classes/app_settings.dart';
import 'package:flashbyte/classes/device_discovery_service.dart';
import 'package:flashbyte/classes/socket_service.dart';
import 'package:flashbyte/classes/tls_identity_service.dart';
import 'package:flashbyte/classes/user_facing_error.dart';
import 'package:flashbyte/pages/settings_page.dart';
import 'package:flashbyte/tcp_socket_pages/incoming_transfer_offer_page.dart';
import 'package:flashbyte/tcp_socket_pages/outgoing_transfer_offer_page.dart';
import 'package:flashbyte/tcp_socket_pages/tcp_chat_page.dart';
import 'package:flashbyte/widgets/slow_m3e_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
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
  static const double _mobileLayoutMaxWidth = 560;
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
      DeviceDiscoveryService.instance.requestRefresh();
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
    if (selectedTabIndex == 0) {
      DeviceDiscoveryService.instance.requestRefresh();
    }
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
      final tlsIdentity = useTLS
          ? await TlsIdentityService.getOrCreateIdentity()
          : null;
      await DeviceDiscoveryService.instance.startAdvertising(
        deviceId: id,
        name: name,
        port: port,
        usesTls: useTLS,
        certificateFingerprint: tlsIdentity?.fingerprint,
        certificatePem: tlsIdentity?.certificatePem,
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
    DeviceDiscoveryService.instance.requestRefresh();
  }

  Future<void> _refreshAdvertisement() async {
    if (!SocketService.instance.isHosting) {
      return;
    }

    final name = deviceName ?? await AppSettings.getDeviceName();
    final id = _deviceId ?? await AppSettings.getDeviceId();
    final port = await AppSettings.getPort();
    final useTLS = await AppSettings.getUseTls();
    final tlsIdentity = useTLS
        ? await TlsIdentityService.getOrCreateIdentity()
        : null;
    await DeviceDiscoveryService.instance.startAdvertising(
      deviceId: id,
      name: name,
      port: port,
      usesTls: useTLS,
      certificateFingerprint: tlsIdentity?.fingerprint,
      certificatePem: tlsIdentity?.certificatePem,
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
    String? advertisedCertificateFingerprint,
    String? advertisedCertificatePem,
    String? advertisedDeviceId,
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
      await _connectToHostWithStartupRetry(
        ip,
        port: port,
        useTLS: useTLS,
        trustedCertificatePem: advertisedCertificatePem,
        expectedCertificateFingerprint: advertisedCertificateFingerprint,
        trustedPeerId: advertisedDeviceId,
      );
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
    String? trustedCertificatePem,
    String? expectedCertificateFingerprint,
    String? trustedPeerId,
  }) async {
    try {
      await SocketService.instance.connectToHost(
        ip,
        port: port,
        useTLS: useTLS,
        trustedCertificatePem: trustedCertificatePem,
        expectedCertificateFingerprint: expectedCertificateFingerprint,
        trustedPeerId: trustedPeerId,
      );
    } on SocketStartupCancelled {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await SocketService.instance.connectToHost(
        ip,
        port: port,
        useTLS: useTLS,
        trustedCertificatePem: trustedCertificatePem,
        expectedCertificateFingerprint: expectedCertificateFingerprint,
        trustedPeerId: trustedPeerId,
      );
    }
  }

  void _connectToDiscoveredDevice(DiscoveredDevice device) {
    _connectToReceiver(
      device.address,
      advertisedPort: device.port,
      advertisedTls: device.usesTls,
      advertisedCertificateFingerprint: device.certificateFingerprint,
      advertisedCertificatePem: device.certificatePem,
      advertisedDeviceId: device.id,
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
          _buildApprovalRoute(
            IncomingTransferOfferPage(
              fileId: fileId,
              fileName: fileName,
              fileSize: fileSize,
              sender: SocketService.instance.connectedPeerInfo,
              receiverName: deviceName ?? _deviceNameController.text,
              receiverType: _localDeviceType,
              receiverUsesTls: SocketService.instance.isSecureHosting,
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
          _buildApprovalRoute(
            OutgoingTransferOfferPage(
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

  PageRouteBuilder<T> _buildApprovalRoute<T>(Widget page) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return PageRouteBuilder<T>(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration: reducedMotion ? Duration.zero : 260.ms,
      reverseTransitionDuration: reducedMotion ? Duration.zero : 200.ms,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        if (reducedMotion) {
          return child;
        }
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.08, 0),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
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
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: useWideLayout
          ? colorScheme.surface
          : colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text("Flashbyte"),
        centerTitle: !useWideLayout,
        backgroundColor: useWideLayout
            ? colorScheme.surface
            : colorScheme.surfaceContainerLowest,
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
            : ColoredBox(
                color: colorScheme.surfaceContainerLowest,
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildTabPage(_buildSendTab()),
                    _buildTabPage(_buildReceiveTab()),
                  ],
                ),
              ),
      ),
      bottomNavigationBar: useWideLayout
          ? null
          : SafeArea(
              top: false,
              child: Material(
                color: Colors.transparent,
                child: TabBar(
                  controller: _tabController,
                  indicatorSize: TabBarIndicatorSize.label,
                  tabs: const [
                    Tab(
                      icon: Icon(Icons.near_me_rounded),
                      text: "Send",
                    ),
                    Tab(
                      icon: Icon(Icons.move_to_inbox_rounded),
                      text: "Receive",
                    ),
                  ],
                  onTap: (index) {
                    setState(() {
                      selectedTabIndex = index;
                    });
                    if (index == 0) {
                      DeviceDiscoveryService.instance.requestRefresh();
                    }
                  },
                  labelColor: colorScheme.primary,
                  unselectedLabelColor: colorScheme.onSurfaceVariant,
                  indicatorColor: colorScheme.primary,
                  dividerColor: colorScheme.outlineVariant.withValues(
                    alpha: 0.55,
                  ),
                  overlayColor: WidgetStatePropertyAll(
                    colorScheme.primary.withValues(alpha: 0.08),
                  ),
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
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _mobileLayoutMaxWidth),
          child: child,
        ),
      ),
    );
  }

  Widget _buildSendTab({bool showHeader = true}) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(0, showHeader ? 12 : 0, 0, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 14,
        children: [
          if (showHeader)
            _buildBrandHeader(
              icon: Icons.upload_file_rounded,
              title: "Send files",
              subtitle: "Pick files, then choose a nearby receiver.",
            ),
          if (showHeader) _buildMobileStatusStrip(),
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
      spacing: 14,
      children: [
        if (showHeader)
          _buildBrandHeader(
            icon: Icons.broadcast_on_personal_rounded,
            title: "Receive files",
            subtitle: "Stay visible to nearby devices while you wait.",
          ),
        if (showHeader) _buildMobileStatusStrip(),
        _buildReceiverIdentityCard(),
        _buildReceiverVisualCard(fillHeight: false),
      ],
    );
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(0, showHeader ? 12 : 0, 0, 24),
      child: content,
    );
  }

  Widget _buildReceiverVisualCard({required bool fillHeight}) {
    final colorScheme = Theme.of(context).colorScheme;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showHelperText = !fillHeight || constraints.maxHeight >= 390;
            final indicatorStatusGap = showHelperText ? 18.0 : 12.0;
            final helperGap = showHelperText ? 10.0 : 0.0;
            final reservedHeight =
                44.0 +
                indicatorStatusGap +
                helperGap +
                (showHelperText ? 16.0 : 0.0);
            final availableIndicatorHeight = math.max(
              0.0,
              constraints.maxHeight - reservedHeight,
            );
            final indicatorSize = fillHeight
                ? math.min(
                    300.0,
                    math.min(
                      math.max(0.0, constraints.maxWidth - 40),
                      availableIndicatorHeight,
                    ),
                  )
                : 220.0;
            return Column(
              mainAxisSize: fillHeight ? MainAxisSize.max : MainAxisSize.min,
              children: [
                if (fillHeight) const Spacer(),
                if (indicatorSize >= 48)
                  SlowM3ELoadingIndicator(
                    size: indicatorSize.toDouble(),
                    isActive:
                        !_receiveServerIntentionallyStopped &&
                        !isReceiveStarting,
                    staticShape: reducedMotion,
                  ),
                if (indicatorSize >= 48) SizedBox(height: indicatorStatusGap),
                Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: _receiveServerIntentionallyStopped
                        ? colorScheme.errorContainer
                        : colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
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
                            ? colorScheme.onErrorContainer
                            : colorScheme.onPrimaryContainer,
                      ),
                      Text(
                        _receiveServerIntentionallyStopped
                            ? 'Receiver stopped'
                            : isReceiveStarting
                            ? 'Starting receiver'
                            : 'Visible to nearby devices',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: _receiveServerIntentionallyStopped
                              ? colorScheme.onErrorContainer
                              : colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
                if (showHelperText) ...[
                  SizedBox(height: helperGap),
                  Text(
                    "Keep Flashbyte open so senders can find this device.",
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (fillHeight) const Spacer(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildMobileStatusStrip() {
    final colorScheme = Theme.of(context).colorScheme;
    final serverRunning = SocketService.instance.isHosting;

    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.06),
            offset: const Offset(0, 8),
            blurRadius: 22,
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(_networkIcon, color: colorScheme.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _networkLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            constraints: const BoxConstraints(minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: serverRunning
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                Icon(
                  serverRunning
                      ? Icons.dns_rounded
                      : Icons.portable_wifi_off_rounded,
                  size: 16,
                  color: serverRunning
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
                Text(
                  serverRunning ? "Ready" : "Offline",
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: serverRunning
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvailableDevicesCard() {
    final colorScheme = Theme.of(context).colorScheme;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 14,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        "Nearby receivers",
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        "Tap a device to offer the selected files.",
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedSwitcher(
                  duration: reducedMotion ? Duration.zero : 180.ms,
                  child: isDiscovering
                      ? SizedBox.square(
                          key: const ValueKey('discovering'),
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.primary,
                          ),
                        )
                      : Icon(
                          Icons.radar_rounded,
                          key: const ValueKey('ready'),
                          size: 22,
                          color: colorScheme.primary,
                        ),
                ),
              ],
            ),
            AnimatedSwitcher(
              duration: reducedMotion ? Duration.zero : 220.ms,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: discoveredDevices.isEmpty
                  ? _buildEmptyDevicesState(colorScheme)
                  : Column(
                      key: ValueKey(
                        discoveredDevices.map((device) => device.id).join(),
                      ),
                      spacing: 10,
                      children: [
                        for (final (index, device) in discoveredDevices.indexed)
                          reducedMotion
                              ? _buildDeviceTile(device)
                              : _buildDeviceTile(device)
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

  Widget _buildEmptyDevicesState(ColorScheme colorScheme) {
    return Container(
      key: const ValueKey('no-devices'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        spacing: 10,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              isDiscovering ? Icons.radar_rounded : Icons.devices_rounded,
              color: colorScheme.onPrimaryContainer,
            ),
          ),
          Text(
            isDiscovering ? "Scanning this network" : "No receivers found",
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            isDiscovering
                ? "Receivers will appear here as soon as they are discoverable."
                : "Make sure the other device is open on Receive and connected to this network.",
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceTile(DiscoveredDevice device) {
    final colorScheme = Theme.of(context).colorScheme;
    final canTap = !isPickingFile && !isConnectingToSender;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final shakeController = _deviceShakeControllers.putIfAbsent(
      device.id,
      () => AnimationController(vsync: this, duration: 420.ms),
    );

    final deviceCard = Material(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: canTap ? () => _handleDiscoveredDeviceTap(device) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(
              spacing: 12,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    device.type == DiscoveredDeviceType.laptop
                        ? Icons.laptop_rounded
                        : Icons.smartphone_rounded,
                    size: 20,
                    color: colorScheme.onPrimaryContainer,
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
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        device.usesTls
                            ? 'Local receiver - secure'
                            : 'Local receiver',
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
                Container(
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  decoration: BoxDecoration(
                    color: canTap
                        ? colorScheme.primary
                        : colorScheme.surfaceContainerHigh,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    size: 20,
                    color: canTap
                        ? colorScheme.onPrimary
                        : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (reducedMotion) {
      return deviceCard;
    }

    return deviceCard
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
      elevation: 0,
      color: colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          spacing: 12,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colorScheme.onPrimaryContainer.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.broadcast_on_personal_rounded,
                color: colorScheme.onPrimaryContainer,
              ),
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
              style: IconButton.styleFrom(
                minimumSize: const Size.square(44),
              ),
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
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      spacing: 8,
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(
            icon,
            size: 30,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
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
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        _selectionSummary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        selectedFiles.isEmpty
                            ? "Choose what you want to send."
                            : "Ready to send after you pick a receiver.",
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
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
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(44),
                    ),
                  ),
              ],
            ),
            if (selectedFiles.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 176),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: selectedFiles.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _buildSelectedFileTile(selectedFiles[index]),
                ),
              ),
            Material(
              color: selectedFiles.isEmpty
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: isPickingFile || isConnectingToSender
                    ? null
                    : _pickFiles,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 58),
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
                          color: selectedFiles.isEmpty
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurfaceVariant,
                        ),
                        Text(
                          isPickingFile
                              ? "Opening picker..."
                              : selectedFiles.isEmpty
                              ? "Pick files"
                              : "Change files",
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: selectedFiles.isEmpty
                                    ? colorScheme.onPrimaryContainer
                                    : colorScheme.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
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

  Widget _buildSelectedFileTile(FastFilePickerPath file) {
    final colorScheme = Theme.of(context).colorScheme;
    final extension = _fileExtensionLabel(file.name);

    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        spacing: 12,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _fileTypeIcon(file.name),
              size: 20,
              color: colorScheme.primary,
            ),
          ),
          Expanded(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            constraints: const BoxConstraints(minHeight: 30),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(15),
            ),
            alignment: Alignment.center,
            child: Text(
              extension,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _fileTypeIcon(String fileName) {
    final extension = _fileExtensionLabel(fileName).toLowerCase();
    if (const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'}.contains(
      extension,
    )) {
      return Icons.image_rounded;
    }
    if (const {'mp4', 'mov', 'mkv', 'webm', 'avi'}.contains(extension)) {
      return Icons.movie_rounded;
    }
    if (const {'mp3', 'wav', 'flac', 'm4a', 'aac'}.contains(extension)) {
      return Icons.music_note_rounded;
    }
    if (const {'pdf', 'doc', 'docx', 'txt', 'ppt', 'pptx'}.contains(
      extension,
    )) {
      return Icons.description_rounded;
    }
    if (const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(extension)) {
      return Icons.archive_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  String _fileExtensionLabel(String fileName) {
    final extensionIndex = fileName.lastIndexOf('.');
    if (extensionIndex <= 0 || extensionIndex == fileName.length - 1) {
      return "FILE";
    }
    final extension = fileName.substring(extensionIndex + 1).toUpperCase();
    return extension.length > 5 ? extension.substring(0, 5) : extension;
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
