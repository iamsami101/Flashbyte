import 'dart:async';
import 'dart:io';

import 'package:flashbyte/classes/socket_service.dart';
import 'package:flashbyte/pages/settings_page.dart';
import 'package:flashbyte/tcp_socket_pages/qr_code_scan.dart';
import 'package:flashbyte/tcp_socket_pages/tcp_chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:loading_indicator_m3e/loading_indicator_m3e.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TcpSockets extends StatefulWidget {
  const TcpSockets({super.key});

  @override
  State<TcpSockets> createState() => _TcpSocketsState();
}

class _TcpSocketsState extends State<TcpSockets> {
  String? ipAddress;
  final TextEditingController controller = TextEditingController();

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

  Future<bool> _getTLSPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('useTLS') ?? true;
  }

  @override
  void initState() {
    super.initState();
    _getTLSPreference().then((useTLS) {
      SocketService.instance.startHost('0.0.0.0', useTLS: useTLS);
    });
    getIp();

    messageSubscription?.cancel();

    messageSubscription = SocketService.instance.messageStream.listen(
      (message) {
        if (!mounted) return;

        final status = message['status'];

        switch (status) {
          case 'client_connected':
          case 'connected_to_host':
            Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    TcpChatPage(),
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
            title: const Text("Connect"),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const SettingsPage(),
                    ),
                  );
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
                child: SingleChildScrollView(
                  child: Column(
                    spacing: 20,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Card(
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
                                    if (constraints.maxWidth <= 400) {
                                      return AnimatedSize(
                                        duration: 500.ms,
                                        curve: Easing.emphasizedDecelerate,
                                        child: ipAddress == null
                                            ? SizedBox(
                                                width: double.infinity,
                                                child: Center(
                                                  child: LoadingIndicatorM3E(),
                                                ),
                                              )
                                            : QrImageView(
                                                data: ipAddress!,
                                                padding: EdgeInsets.all(
                                                  20,
                                                ),
                                                backgroundColor: Colors.white,
                                              ),
                                      );
                                    } else {
                                      return SizedBox(
                                        width: 400,
                                        child: AnimatedSize(
                                          duration: 500.ms,
                                          curve: Easing.emphasizedDecelerate,
                                          child: ipAddress == null
                                              ? Divider()
                                              : QrImageView(
                                                  data: ipAddress!,
                                                  padding: EdgeInsets.all(
                                                    20,
                                                  ),
                                                  backgroundColor: Colors.white,
                                                ),
                                        ),
                                      );
                                    }
                                  },
                                ),
                                SelectableText(
                                  ipAddress ?? "Fetching...",
                                  style: TextStyle(
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Row(
                        spacing: 20,
                        children: [
                          Expanded(child: Divider()),
                          Text("or"),
                          Expanded(child: Divider()),
                        ],
                      ),
                      Row(
                        spacing: 20,
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: controller,
                              decoration: InputDecoration(
                                label: const Text("192.168.xx.xx"),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                          Card(
                            margin: EdgeInsets.zero,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                                      onTap: () async {
                                        if (Platform.isAndroid || Platform.isIOS) {
                                          final useTLS = await _getTLSPreference();
                                          if (!context.mounted) return;
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) => QrCodeScanPage(
                                                onScanned: (value) async {
                                                  try {
                                                    Navigator.pop(context);
                                                    SocketService.instance
                                                        .connectToHost(
                                                          value,
                                                          useTLS: useTLS,
                                                        );
                                                  } on Exception catch (_) {
                                                    showScaffoldSnackbar(
                                                      "Error connecting to user",
                                                    );
                                                  }
                                                },
                                              ),
                                            ),
                                          );
                                } else {
                                  showScaffoldSnackbar(
                                    "QR code scanning not supported on ${Platform.operatingSystem}",
                                  );
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(13),
                                child: Icon(Icons.camera_alt),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: Card(
                          margin: EdgeInsets.zero,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () async {
                              final ip = controller.text;
                              if (ip.isEmpty) {
                                showScaffoldSnackbar("IP can't be empty");
                                return;
                              }
                              final useTLS = await _getTLSPreference();
                              try {
                                SocketService.instance.connectToHost(
                                  ip,
                                  useTLS: useTLS,
                                );
                              } on Exception catch (_) {
                                showScaffoldSnackbar(
                                  "Error connecting to user",
                                );
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(13),
                              child: Center(child: Text("Connect")),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
