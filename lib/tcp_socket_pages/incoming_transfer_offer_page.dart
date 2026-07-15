import 'dart:async';

import 'package:flashbyte/classes/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class IncomingTransferOfferPage extends StatefulWidget {
  const IncomingTransferOfferPage({
    super.key,
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.sender,
    required this.onAccept,
    required this.onDecline,
  });

  final String fileId;
  final String fileName;
  final int fileSize;
  final Map<String, dynamic>? sender;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  State<IncomingTransferOfferPage> createState() =>
      _IncomingTransferOfferPageState();
}

class _IncomingTransferOfferPageState extends State<IncomingTransferOfferPage> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  _IncomingOfferOutcome? _outcome;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _subscription = SocketService.instance.messageStream.listen((message) {
      if (!mounted || _isClosing || _outcome != null) return;
      switch (message['status']) {
        case 'offer_cancelled_by_sender':
          setState(() => _outcome = _IncomingOfferOutcome.senderCancelled);
          break;
        case 'error':
        case 'disconnect':
          setState(() => _outcome = _IncomingOfferOutcome.connectionEnded);
          break;
      }
    });
  }

  void _accept() {
    if (_isClosing) return;
    _isClosing = true;
    widget.onAccept();
  }

  void _decline() {
    if (_isClosing || _outcome != null) return;
    widget.onDecline();
    setState(() => _outcome = _IncomingOfferOutcome.declined);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final senderName = widget.sender?['name'] as String? ?? 'Unknown device';
    final senderAddress = widget.sender?['address'] as String?;
    final senderType = widget.sender?['deviceType'] == 'laptop'
        ? Icons.laptop_mac_rounded
        : Icons.phone_android_rounded;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _decline();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Decline files',
            onPressed: _decline,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: const Text('Incoming files'),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: _outcome == null
                    ? _buildOffer(
                        context,
                        colorScheme,
                        senderName,
                        senderAddress,
                        senderType,
                      )
                    : _buildOutcome(context, colorScheme),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOffer(
    BuildContext context,
    ColorScheme colorScheme,
    String senderName,
    String? senderAddress,
    IconData senderType,
  ) {
    final senderCard = _OfferSurface(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: colorScheme.secondaryContainer,
          foregroundColor: colorScheme.onSecondaryContainer,
          child: Icon(senderType),
        ),
        title: Text(senderName),
        subtitle: Text(senderAddress ?? 'Sending from a nearby device'),
      ),
    );
    final fileCard = _OfferSurface(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              color: colorScheme.primary,
              size: 30,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _formatFileSize(widget.fileSize),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.file_download_rounded, size: 48, color: colorScheme.primary)
            .animate()
            .fadeIn(duration: 180.ms)
            .scale(begin: const Offset(0.8, 0.8), end: const Offset(1, 1)),
        const SizedBox(height: 16),
        Text(
          'Files ready to receive',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ).animate().fadeIn(delay: 70.ms, duration: 180.ms),
        const SizedBox(height: 8),
        Text(
          'Review the incoming file before it is saved to this device.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ).animate().fadeIn(delay: 110.ms, duration: 180.ms),
        const SizedBox(height: 28),
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 720
              ? Row(
                  children: [
                    Expanded(child: senderCard),
                    const SizedBox(width: 12),
                    Expanded(child: fileCard),
                  ],
                )
              : Column(
                  children: [
                    senderCard,
                    const SizedBox(height: 12),
                    fileCard,
                  ],
                ),
        ).animate().fadeIn(delay: 160.ms, duration: 200.ms),
        const Spacer(),
        FilledButton.icon(
          onPressed: _accept,
          icon: const Icon(Icons.download_rounded),
          label: const Text('Accept and receive'),
        ).animate().fadeIn(delay: 240.ms, duration: 180.ms),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _decline,
          icon: const Icon(Icons.close_rounded),
          label: const Text('Decline'),
        ).animate().fadeIn(delay: 290.ms, duration: 180.ms),
      ],
    );
  }

  Widget _buildOutcome(BuildContext context, ColorScheme colorScheme) {
    final senderCancelled = _outcome == _IncomingOfferOutcome.senderCancelled;
    final declined = _outcome == _IncomingOfferOutcome.declined;
    final icon = senderCancelled
        ? Icons.cancel_schedule_send_rounded
        : declined
        ? Icons.block_rounded
        : Icons.portable_wifi_off_rounded;
    final title = senderCancelled
        ? 'Sender cancelled the transfer'
        : declined
        ? 'Files declined'
        : 'Connection ended';
    final message = senderCancelled
        ? 'The sender no longer wants to send these files. Nothing was downloaded.'
        : declined
        ? 'These files were not accepted and nothing was downloaded.'
        : 'The connection ended before a decision was made.';
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

  static String _formatFileSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final precision = unit == 0
        ? 0
        : value < 10
        ? 2
        : 1;
    return '${value.toStringAsFixed(precision)} ${units[unit]}';
  }
}

enum _IncomingOfferOutcome { senderCancelled, declined, connectionEnded }

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
