import 'dart:async';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/classes/device_discovery_service.dart';
import 'package:flashbyte/classes/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:heroine/heroine.dart';

String outgoingReceiverHeroineTag(String deviceId) {
  return 'outgoing-receiver-$deviceId';
}

class OutgoingTransferOfferPage extends StatefulWidget {
  const OutgoingTransferOfferPage({
    super.key,
    required this.files,
    required this.onStartSending,
    required this.onCancel,
    required this.senderName,
    required this.senderType,
    required this.senderUsesTls,
    this.receiverPreview,
  });

  final List<FastFilePickerPath> files;
  final VoidCallback onStartSending;
  final Future<void> Function() onCancel;
  final String senderName;
  final DiscoveredDeviceType senderType;
  final bool senderUsesTls;
  final DiscoveredDevice? receiverPreview;

  @override
  State<OutgoingTransferOfferPage> createState() =>
      _OutgoingTransferOfferPageState();
}

class _OutgoingTransferOfferPageState extends State<OutgoingTransferOfferPage> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Map<String, dynamic>? _receiver;
  bool _isClosing = false;
  _OutgoingOfferOutcome? _outcome;

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
        case 'transfer_declined':
          _showOutcome(_OutgoingOfferOutcome.declined);
          break;
        case 'error':
        case 'disconnect':
          _showOutcome(_OutgoingOfferOutcome.connectionEnded);
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

  void _showOutcome(_OutgoingOfferOutcome outcome) {
    if (_isClosing || _outcome != null) return;
    setState(() => _outcome = outcome);
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
    final receiverName =
        _receiver?['name'] as String? ??
        widget.receiverPreview?.name ??
        'Receiver';
    final receiverAddress =
        _receiver?['address'] as String? ?? widget.receiverPreview?.address;
    final receiverType = _receiver?['deviceType'] == 'laptop'
        ? DiscoveredDeviceType.laptop
        : widget.receiverPreview?.type ?? DiscoveredDeviceType.phone;
    final receiverUsesTls =
        (_receiver?['tls'] as bool?) ??
        widget.receiverPreview?.usesTls ??
        false;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _cancel();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Cancel transfer',
            onPressed: _cancel,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: const Text('Sending files'),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: _outcome == null
                    ? _buildWaitingContent(
                        context,
                        colorScheme,
                        receiverName,
                        receiverAddress,
                        receiverType,
                        receiverUsesTls,
                      )
                    : _buildOutcomeContent(context, colorScheme),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWaitingContent(
    BuildContext context,
    ColorScheme colorScheme,
    String receiverName,
    String? receiverAddress,
    DiscoveredDeviceType receiverType,
    bool receiverUsesTls,
  ) {
    final receiverTag = widget.receiverPreview == null
        ? null
        : outgoingReceiverHeroineTag(widget.receiverPreview!.id);

    return Column(
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
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 720;
              final deviceCard = _OfferSurface(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 10,
                    children: [
                      _ApprovalDeviceRow(
                            label: 'This device',
                            name: widget.senderName,
                            detail: _deviceDetail(
                              widget.senderType,
                              widget.senderUsesTls,
                              null,
                            ),
                            type: widget.senderType,
                            color: colorScheme.secondaryContainer,
                            foregroundColor: colorScheme.onSecondaryContainer,
                          )
                          .animate()
                          .fadeIn(delay: 120.ms, duration: 180.ms)
                          .slideY(
                            begin: 0.05,
                            end: 0,
                            curve: Curves.easeOutCubic,
                          ),
                      if (receiverTag == null)
                        _ApprovalDeviceRow(
                          label: 'Receiver',
                          name: receiverName,
                          detail: _deviceDetail(
                            receiverType,
                            receiverUsesTls,
                            receiverAddress,
                          ),
                          type: receiverType,
                          color: colorScheme.primaryContainer,
                          foregroundColor: colorScheme.onPrimaryContainer,
                        )
                      else
                        Heroine(
                          tag: receiverTag,
                          motion: CupertinoMotion.bouncy(),
                          child: _ApprovalDeviceRow(
                            label: 'Receiver',
                            name: receiverName,
                            detail: _deviceDetail(
                              receiverType,
                              receiverUsesTls,
                              receiverAddress,
                            ),
                            type: receiverType,
                            color: colorScheme.primaryContainer,
                            foregroundColor: colorScheme.onPrimaryContainer,
                          ),
                        ),
                    ],
                  ),
                ),
              );
              final filesCard = _OfferSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                      child: Text(
                        '${widget.files.length} ${widget.files.length == 1 ? 'file' : 'files'} selected',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    Expanded(
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
                          return ListTile(
                            leading: const Icon(
                              Icons.insert_drive_file_outlined,
                            ),
                            title: Text(
                              file.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
              if (isWide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: deviceCard),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: filesCard),
                  ],
                );
              }
              return Column(
                children: [
                  deviceCard,
                  const SizedBox(height: 12),
                  Expanded(child: filesCard),
                ],
              );
            },
          ).animate().fadeIn(delay: 160.ms, duration: 200.ms),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _cancel,
          icon: const Icon(Icons.close_rounded),
          label: const Text('Cancel transfer'),
        ).animate().fadeIn(delay: 300.ms, duration: 180.ms),
      ],
    );
  }

  Widget _buildOutcomeContent(BuildContext context, ColorScheme colorScheme) {
    final declined = _outcome == _OutgoingOfferOutcome.declined;
    final icon = declined
        ? Icons.block_rounded
        : Icons.portable_wifi_off_rounded;
    final title = declined ? 'Receiver declined the files' : 'Connection ended';
    final message = declined
        ? 'The receiver chose not to accept these files. Nothing was sent.'
        : 'The connection ended before the receiver responded. No files were sent.';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
              icon,
              size: 52,
              color: declined ? colorScheme.error : colorScheme.primary,
            )
            .animate()
            .fadeIn(duration: 180.ms)
            .scale(begin: const Offset(0.8, 0.8), end: const Offset(1, 1)),
        const SizedBox(height: 18),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Back to file selection'),
        ),
      ],
    );
  }

  String _deviceDetail(
    DiscoveredDeviceType type,
    bool usesTls,
    String? address,
  ) {
    final parts = <String>[
      type == DiscoveredDeviceType.laptop ? 'Laptop' : 'Phone',
      if (usesTls) 'Secure',
      ?address,
    ];
    return parts.join(' • ');
  }
}

enum _OutgoingOfferOutcome { declined, connectionEnded }

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

class _ApprovalDeviceRow extends StatelessWidget {
  const _ApprovalDeviceRow({
    required this.label,
    required this.name,
    required this.detail,
    required this.type,
    required this.color,
    required this.foregroundColor,
  });

  final String label;
  final String name;
  final String detail;
  final DiscoveredDeviceType type;
  final Color color;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
          child: Row(
            spacing: 12,
            children: [
              CircleAvatar(
                backgroundColor: color,
                foregroundColor: foregroundColor,
                child: Icon(
                  type == DiscoveredDeviceType.laptop
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
                      label,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
