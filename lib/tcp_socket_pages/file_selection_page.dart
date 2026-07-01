import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/classes/app_settings.dart';
import 'package:flashbyte/classes/socket_service.dart';
import 'package:flashbyte/pages/settings_page.dart';
import 'package:flashbyte/tcp_socket_pages/qr_code_scan.dart';
import 'package:flashbyte/tcp_socket_pages/tcp_chat_page.dart';
import 'package:flutter/material.dart';
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
  List<FastFilePickerPath> selectedFiles = [];
  late final TabController _tabController;

  bool isPickingFile = false;
  bool isConnectingToSender = false;
  bool isReceiveStarting = false;
  bool receiveStarted = false;
  bool chatOpened = false;
  int selectedTabIndex = 0;

  String? receiveIpAddress;
  StreamSubscription? _socketSubscription;

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

    if (selectedTabIndex == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _ensureReceiveReady();
        }
      });
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    _socketSubscription?.cancel();
    receiverIpController.dispose();
    SocketService.instance.stopConnection();
    super.dispose();
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

    if (selectedTabIndex == 1) {
      _ensureReceiveReady();
    }
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

  Future<void> _connectToReceiver(String ip) async {
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
      final useTLS = await AppSettings.getUseTls();
      final port = await AppSettings.getPort();
      SocketService.instance.connectToHost(ip, port: port, useTLS: useTLS);
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

  void _handleSocketMessage(Map<String, dynamic> message) {
    if (!mounted) return;

    final status = message['status'];

    switch (status) {
      case 'client_connected':
        if (selectedTabIndex == 1) {
          _openChatIfNeeded(initialFiles: const []);
        }
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
    ).then((_) {
      if (!mounted) return;
      setState(() {
        chatOpened = false;
        isConnectingToSender = false;
        if (selectedTabIndex == 1) {
          receiveStarted = false;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Flash Byte"),
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
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorPadding: EdgeInsetsGeometry.symmetric(
              horizontal: 0,
            ),
            padding: EdgeInsets.all(0),
            dividerHeight: 0,
            indicatorAnimation: TabIndicatorAnimation.elastic,
            labelColor: Theme.of(context).colorScheme.onPrimaryContainer,
            indicator: BoxDecoration(),
            controller: _tabController,
            onTap: (index) {
              if (selectedTabIndex != index) {
                setState(() {
                  selectedTabIndex = index;
                });
              }
              if (index == 1) {
                _ensureReceiveReady();
              }
            },
            tabs: const [
              Tab(
                icon: Icon(Icons.upload_rounded),
                text: "Send",
              ),
              Tab(
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
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 20,
      children: [
        _buildBrandHeader(
          icon: Icons.upload_file_rounded,
          title: "Send files",
          subtitle:
              "Pick files, then enter the receiver IP or scan its QR code.",
        ),
        _buildSelectedFilesCard(),
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
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
    final shouldRestartReceive = selectedTabIndex == 1;
    if (shouldRestartReceive) {
      SocketService.instance.stopConnection();
      receiveStarted = false;
      receiveIpAddress = null;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsPage(locked: _settingsLocked),
      ),
    );
    if (!mounted) return;
    if (shouldRestartReceive) {
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
            Text(
              _selectionSummary,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (selectedFiles.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: selectedFiles.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.insert_drive_file),
                    title: Text(
                      selectedFiles[index].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            Card.outlined(
              margin: EdgeInsets.zero,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: isPickingFile ? null : _pickFiles,
                child: Padding(
                  padding: const EdgeInsets.all(17),
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
                            ? "Opening Picker..."
                            : selectedFiles.isEmpty
                            ? "Pick Files"
                            : "Change Files",
                      ),
                    ],
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
