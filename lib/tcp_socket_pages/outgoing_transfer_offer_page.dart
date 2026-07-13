import 'dart:async';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/classes/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class OutgoingTransferOfferPage extends StatefulWidget {
  const OutgoingTransferOfferPage({
    super.key,
    required this.files,
    required this.onStartSending,
    required this.onCancel,
  });

  final List<FastFilePickerPath> files;
  final VoidCallback onStartSending;
  final Future<void> Function() onCancel;

  @override
  State<OutgoingTransferOfferPage> createState() =>
      _OutgoingTransferOfferPageState();
}

class _OutgoingTransferOfferPageState extends State<OutgoingTransferOfferPage> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Map<String, dynamic>? _receiver;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _receiver = SocketService.instance.connectedPeerInfo;
    _subscription = SocketService.instance.messageStream.listen((message) {
      if (!mounted) return;

      switch (message['status']) {
        case 'peer_info':
          setState(() => _receiver = Map<String, dynamic>.from(message));
          break;
        case 'transfer_accepted':
          _completeApproval();
          break;
        case 'transfer_cancelled':
        case 'error':
        case 'disconnect':
          if (!_isClosing) {
            _isClosing = true;
            Navigator.of(context).pop(false);
          }
          break;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.onStartSending(),
    );
  }

  void _completeApproval() {
    if (_isClosing) return;
    _isClosing = true;
    Navigator.of(context).pop(true);
  }

  Future<void> _cancel() async {
    if (_isClosing) return;
    _isClosing = true;
    await widget.onCancel();
    if (mounted) {
      Navigator.of(context).pop(false);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final receiverName = _receiver?['name'] as String? ?? 'Receiver';
    final receiverAddress = _receiver?['address'] as String?;
    final receiverIcon = _receiver?['deviceType'] == 'laptop'
        ? Icons.laptop_mac_rounded
        : Icons.phone_android_rounded;

    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('Sending files'),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                          Icons.hourglass_top_rounded,
                          size: 48,
                          color: colorScheme.primary,
                        )
                        .animate(onPlay: (controller) => controller.repeat())
                        .rotate(duration: 1600.ms, curve: Curves.easeInOut),
                    const SizedBox(height: 16),
                    Text(
                      'Waiting for approval',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ).animate().fadeIn(delay: 60.ms, duration: 180.ms),
                    const SizedBox(height: 8),
                    Text(
                      'The receiver needs to accept these files before sending begins.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ).animate().fadeIn(delay: 110.ms, duration: 180.ms),
                    const SizedBox(height: 28),
                    _OfferSurface(
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            leading: CircleAvatar(
                              backgroundColor: colorScheme.secondaryContainer,
                              foregroundColor: colorScheme.onSecondaryContainer,
                              child: Icon(receiverIcon),
                            ),
                            title: Text(receiverName),
                            subtitle: Text(
                              receiverAddress ?? 'Connected nearby device',
                            ),
                          ),
                        )
                        .animate()
                        .fadeIn(delay: 160.ms, duration: 200.ms)
                        .slideY(
                          begin: 0.04,
                          end: 0,
                          curve: Curves.easeOutCubic,
                        ),
                    const SizedBox(height: 12),
                    Text(
                      '${widget.files.length} ${widget.files.length == 1 ? 'file' : 'files'} selected',
                      style: Theme.of(context).textTheme.labelLarge,
                    ).animate().fadeIn(delay: 210.ms, duration: 180.ms),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _OfferSurface(
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: widget.files.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            indent: 56,
                            color: colorScheme.outlineVariant.withValues(
                              alpha: 0.55,
                            ),
                          ),
                          itemBuilder: (context, index) {
                            final file = widget.files[index];
                            final path =
                                file.path ?? file.uri ?? 'Unknown file';
                            final name = path.split('/').last;
                            return ListTile(
                              leading: const Icon(
                                Icons.insert_drive_file_outlined,
                              ),
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          },
                        ),
                      ),
                    ).animate().fadeIn(delay: 250.ms, duration: 200.ms),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _cancel,
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('Cancel transfer'),
                    ).animate().fadeIn(delay: 300.ms, duration: 180.ms),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OfferSurface extends StatelessWidget {
  const _OfferSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      child: child,
    );
  }
}
