import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/classes/app_settings.dart';
import 'package:flashbyte/classes/socket_service.dart';
import 'package:flashbyte/pages/settings_page.dart';
import 'package:flashbyte/tcp_socket_pages/tcp_chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:loading_indicator_m3e/loading_indicator_m3e.dart';
import 'package:qr_flutter/qr_flutter.dart';

enum TcpConnectionMode { send, receive }

class TcpSockets extends StatefulWidget {
  final TcpConnectionMode mode;
  final List<FastFilePickerPath> selectedFiles;

  const TcpSockets({
    super.key,
    required this.mode,
    required this.selectedFiles,
  });

  @override
  State<TcpSockets> createState() => _TcpSocketsState();
}

class _TcpSocketsState extends State<TcpSockets> {
  String? ipAddress;
  final TextEditingController controller = TextEditingController();
  bool _isConnecting = false;

  StreamSubscription? messageSubscription;

  Future getIp() async {
    for (var interface in await NetworkInterface.list()) {
      final addressList = interface.addresses;

      for (var address in addressList) {
        print("${address.address} ${address.type}");
        if (address.address.startsWith("192.168.") &&
            address.type == InternetAddressType.IPv4) {
          Future.delayed(500.ms).then(
            (value) {
              setState(() {
                ipAddress = address.address;
              });
            },
          );
          return;
        }
        if (address.type == InternetAddressType.IPv4) {
          Future.delayed(500.ms).then(
            (value) {
              setState(() {
                ipAddress = address.address;
              });
            },
          );
        }
      }
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.mode == TcpConnectionMode.receive) {
      _startReceiver();
      getIp();
    }

    messageSubscription?.cancel();

    messageSubscription = SocketService.instance.messageStream.listen(
      (message) {
        if (!mounted) return;

        final status = message['status'];

        switch (status) {
          case 'client_connecting':
            setState(() {
              _isConnecting = true;
            });
            break;
          case 'client_connected':
          case 'connected_to_host':
            setState(() {
              _isConnecting = false;
            });
            Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    TcpChatPage(initialFiles: widget.selectedFiles),
              ),
            );
            break;
          case 'error':
            setState(() {
              _isConnecting = false;
            });
            showGeneralDialog(
              context: context,
              barrierDismissible: true,
              barrierLabel: "Close Dialog",
              pageBuilder: (context, animation, secondaryAnimation) =>
                  AlertDialog(
                    title: Row(
                      spacing: 10,
                      children: [
                        Icon(
                          Icons.error_rounded,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        Text('Connection Error'),
                      ],
                    ),
                    content: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      spacing: 10,
                      children: [
                        Text(
                          "Failed to establish connection.\n\nError log:",
                        ),
                        Card(
                          margin: EdgeInsets.all(0),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxHeight: 200),
                              child: SingleChildScrollView(
                                child: Text(
                                  message['message'] ?? 'Unknown error',
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        SizedBox(
                          width: double.infinity,
                          child: Card(
                            margin: EdgeInsets.zero,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => Navigator.pop(context),
                              child: Padding(
                                padding: const EdgeInsets.all(13),
                                child: Center(child: Text("Dismiss")),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
            );
            break;
        }
      },
    );
  }

  @override
  void dispose() {
    messageSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {}
      },
      child: GestureDetector(
        onTap: () {
          FocusManager.instance.primaryFocus!.unfocus();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              widget.mode == TcpConnectionMode.receive ? "Receive" : "Send",
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () async {
                  SocketService.instance.stopConnection();
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const SettingsPage(),
                    ),
                  );
                  if (widget.mode == TcpConnectionMode.receive) {
                    await _startReceiver();
                  }
                },
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Center(
              child: ConstrainedBox(
                constraints: (Platform.isAndroid || Platform.isIOS)
                    ? BoxConstraints()
                    : BoxConstraints(maxWidth: 500),
                child: AnimatedSwitcher(
                  duration: 280.ms,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    final offsetAnimation = Tween<Offset>(
                      begin: const Offset(0, 0.03),
                      end: Offset.zero,
                    ).animate(animation);
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: offsetAnimation,
                        child: child,
                      ),
                    );
                  },
                  child: SingleChildScrollView(
                    key: ValueKey(widget.mode),
                    child: widget.mode == TcpConnectionMode.receive
                        ? _buildReceiveConnection()
                        : _buildSendConnection(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startReceiver() async {
    final useTLS = await AppSettings.getUseTls();
    final port = await AppSettings.getPort();
    await SocketService.instance.startHost(
      '0.0.0.0',
      port: port,
      useTLS: useTLS,
    );
  }

  Widget _buildReceiveConnection() {
    return Column(
      spacing: 20,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          "Ready to Receive",
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        _buildQrCard(),
      ],
    ).animate().fadeIn(duration: 220.ms, curve: Curves.easeOutCubic);
  }

  Widget _buildSendConnection() {
    return Column(
      spacing: 20,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          "${widget.selectedFiles.length} file${widget.selectedFiles.length == 1 ? "" : "s"} ready",
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        TextField(
          controller: controller,
          enabled: !_isConnecting,
          decoration: InputDecoration(
            label: const Text("Receiver IP"),
            hintText: "192.168.xx.xx",
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        SizedBox(
          width: double.infinity,
          child: Card(
            margin: EdgeInsets.zero,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _isConnecting ? null : _connectToReceiver,
              child: Padding(
                padding: const EdgeInsets.all(13),
                child: Center(
                  child: Text(_isConnecting ? "Connecting..." : "Connect"),
                ),
              ),
            ),
          ),
        ),
      ],
    ).animate().fadeIn(duration: 220.ms, curve: Curves.easeOutCubic);
  }

  Widget _buildQrCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsetsGeometry.all(20),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            spacing: 20,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final qr = ipAddress == null || _isConnecting
                      ? SizedBox(
                          width: double.infinity,
                          child: Center(child: LoadingIndicatorM3E()),
                        )
                      : QrImageView(
                          data: ipAddress!,
                          padding: EdgeInsets.all(20),
                          backgroundColor: Colors.white,
                        );

                  final sizedQr = constraints.maxWidth <= 400
                      ? AnimatedSize(
                          duration: 500.ms,
                          curve: Easing.emphasizedDecelerate,
                          child: qr,
                        )
                      : SizedBox(
                          width: 400,
                          child: AnimatedSize(
                            duration: 500.ms,
                            curve: Easing.emphasizedDecelerate,
                            child: qr,
                          ),
                        );

                  return FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: constraints.maxWidth <= 400
                          ? constraints.maxWidth
                          : 400,
                      child: sizedQr,
                    ),
                  );
                },
              ),
              SelectableText(
                ipAddress ?? "Fetching...",
                style: TextStyle(fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    ).animate().fadeIn(
      delay: 80.ms,
      duration: 220.ms,
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _connectToReceiver() async {
    final ip = controller.text.trim();
    if (ip.isEmpty) {
      showScaffoldSnackbar("Receiver IP can't be empty");
      return;
    }

    final useTLS = await AppSettings.getUseTls();
    final port = await AppSettings.getPort();
    setState(() {
      _isConnecting = true;
    });
    try {
      SocketService.instance.connectToHost(ip, port: port, useTLS: useTLS);
    } on Exception catch (_) {
      setState(() {
        _isConnecting = false;
      });
      showScaffoldSnackbar("Error connecting to receiver");
    }
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
}
