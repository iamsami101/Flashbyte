import 'dart:async';

import 'package:flashbyte/models/discovered_device.dart';
import 'package:flashbyte/services/transfer/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class IncomingTransferOfferPage extends StatefulWidget {
  const IncomingTransferOfferPage({
    super.key,
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.sender,
    required this.receiverName,
    required this.receiverType,
    required this.receiverUsesTls,
    required this.onAccept,
    required this.onDecline,
  });

  final String fileId;
  final String fileName;
  final int fileSize;
  final Map<String, dynamic>? sender;
  final String receiverName;
  final DiscoveredDeviceType receiverType;
  final bool receiverUsesTls;
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
    final senderPort = widget.sender?['port'] as int?;
    final senderUsesTls = widget.sender?['tls'] == true;
    final senderFingerprint = widget.sender?['certFingerprint'] as String?;
    final senderType = widget.sender?['deviceType'] == 'laptop'
        ? DiscoveredDeviceType.laptop
        : DiscoveredDeviceType.phone;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _decline();
      },
      child: Scaffold(
        backgroundColor: colorScheme.surfaceContainerLowest,
        appBar: AppBar(
          backgroundColor: colorScheme.surfaceContainerLowest,
          centerTitle: true,
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
                        senderPort,
                        senderType,
                        senderUsesTls,
                        senderFingerprint,
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
    int? senderPort,
    DiscoveredDeviceType senderType,
    bool senderUsesTls,
    String? senderFingerprint,
  ) {
    final senderCard = _OfferSurface(
      title: 'Devices',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: Column(
          spacing: 12,
          children: [
            _maybeAnimate(
              context,
              _ApprovalDeviceRow(
                label: 'Sender',
                name: senderName,
                detail: _deviceTypeLabel(senderType),
                type: senderType,
                address: senderAddress ?? 'Address pending',
                port: senderPort,
                usesTls: senderUsesTls,
                fingerprint: senderFingerprint,
                color: colorScheme.secondaryContainer,
                foregroundColor: colorScheme.onSecondaryContainer,
              ),
              (child) => child
                  .animate()
                  .fadeIn(delay: 120.ms, duration: 180.ms)
                  .slideY(begin: 0.05, end: 0, curve: Curves.easeOutCubic),
            ),
            _TransferDirectionDivider(
              secure: senderUsesTls && widget.receiverUsesTls,
            ),
            _maybeAnimate(
              context,
              _ApprovalDeviceRow(
                label: 'This device',
                name: widget.receiverName,
                detail: _deviceTypeLabel(widget.receiverType),
                type: widget.receiverType,
                address: 'Local receiver',
                port: null,
                usesTls: widget.receiverUsesTls,
                color: colorScheme.primaryContainer,
                foregroundColor: colorScheme.onPrimaryContainer,
              ),
              (child) => child
                  .animate()
                  .fadeIn(delay: 220.ms, duration: 180.ms)
                  .slideY(begin: 0.05, end: 0, curve: Curves.easeOutCubic),
            ),
          ],
        ),
      ),
    );
    final fileCard = _OfferSurface(
      title: 'Requested file',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: _ApprovalFileRow(
          fileName: widget.fileName,
          fileSize: _formatFileSize(widget.fileSize),
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasComfortableHeight = constraints.maxHeight >= 560;
        final verticalGap = hasComfortableHeight ? 28.0 : 18.0;

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.only(bottom: verticalGap),
              child: Column(
                mainAxisAlignment: hasComfortableHeight
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _maybeAnimate(
                    context,
                    _ApprovalHeader(
                      icon: Icons.file_download_rounded,
                      title: 'Approve incoming file',
                      message:
                          'Review the sender and file before saving it here.',
                    ),
                    (child) => child
                        .animate()
                        .fadeIn(duration: 180.ms)
                        .slideY(
                          begin: 0.05,
                          end: 0,
                          curve: Curves.easeOutCubic,
                        ),
                  ),
                  const SizedBox(height: 20),
                  _maybeAnimate(
                    context,
                    _ResponsiveOfferCards(
                      senderCard: senderCard,
                      fileCard: fileCard,
                    ),
                    (child) => child
                        .animate()
                        .fadeIn(delay: 160.ms, duration: 200.ms)
                        .slideY(
                          begin: 0.04,
                          end: 0,
                          curve: Curves.easeOutCubic,
                        ),
                  ),
                  SizedBox(height: verticalGap),
                  _OfferActions(onAccept: _accept, onDecline: _decline),
                ],
              ),
            ),
          ),
        );
      },
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
        _maybeAnimate(
          context,
          Icon(
            icon,
            size: 52,
            color: declined ? colorScheme.error : colorScheme.primary,
          ),
          (child) => child
              .animate()
              .fadeIn(duration: 180.ms)
              .scale(begin: const Offset(0.8, 0.8), end: const Offset(1, 1)),
        ),
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

  String _deviceTypeLabel(DiscoveredDeviceType type) {
    return type == DiscoveredDeviceType.laptop ? 'Desktop or laptop' : 'Phone';
  }
}

enum _IncomingOfferOutcome { senderCancelled, declined, connectionEnded }

class _ResponsiveOfferCards extends StatelessWidget {
  const _ResponsiveOfferCards({
    required this.senderCard,
    required this.fileCard,
  });

  final Widget senderCard;
  final Widget fileCard;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= 720
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: senderCard),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: fileCard),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                senderCard,
                const SizedBox(height: 12),
                fileCard,
              ],
            ),
    );
  }
}

class _OfferActions extends StatelessWidget {
  const _OfferActions({required this.onAccept, required this.onDecline});

  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: onAccept,
          icon: const Icon(Icons.download_rounded),
          label: const Text('Accept and receive'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onDecline,
          icon: const Icon(Icons.close_rounded),
          label: const Text('Decline'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
        ),
      ],
    );
  }
}

Widget _maybeAnimate(
  BuildContext context,
  Widget child,
  Widget Function(Widget child) animated,
) {
  return MediaQuery.disableAnimationsOf(context) ? child : animated(child);
}

class _OfferSurface extends StatelessWidget {
  const _OfferSurface({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _ApprovalHeader extends StatelessWidget {
  const _ApprovalHeader({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
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
          child: Icon(icon, size: 30, color: colorScheme.onPrimaryContainer),
        ),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _TransferDirectionDivider extends StatelessWidget {
  const _TransferDirectionDivider({required this.secure});

  final bool secure;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Expanded(
          child: Divider(
            color: colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: secure
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(17),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              Icon(
                secure ? Icons.lock_rounded : Icons.lock_open_rounded,
                size: 16,
                color: secure
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
              Text(
                secure ? 'Secure request' : 'Unencrypted request',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: secure
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Divider(
            color: colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

class _ApprovalDeviceRow extends StatelessWidget {
  const _ApprovalDeviceRow({
    required this.label,
    required this.name,
    required this.detail,
    required this.type,
    required this.address,
    required this.port,
    required this.usesTls,
    this.fingerprint,
    required this.color,
    required this.foregroundColor,
  });

  final String label;
  final String name;
  final String detail;
  final DiscoveredDeviceType type;
  final String address;
  final int? port;
  final bool usesTls;
  final String? fingerprint;
  final Color color;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.68),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Row(
              spacing: 12,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    type == DiscoveredDeviceType.laptop
                        ? Icons.laptop_rounded
                        : Icons.smartphone_rounded,
                    size: 22,
                    color: foregroundColor,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
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
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _DetailPill(icon: Icons.devices_rounded, label: detail),
                _DetailPill(icon: Icons.lan_rounded, label: address),
                if (port != null)
                  _DetailPill(
                    icon: Icons.numbers_rounded,
                    label: 'Port $port',
                  ),
                _DetailPill(
                  icon: usesTls ? Icons.lock_rounded : Icons.lock_open_rounded,
                  label: usesTls ? 'TLS enabled' : 'Unencrypted',
                ),
                if (usesTls && fingerprint != null)
                  _DetailPill(
                    icon: Icons.fingerprint_rounded,
                    label: 'TLS ${_shortFingerprint(fingerprint!)}',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _shortFingerprint(String value) {
    if (value.length <= 12) {
      return value;
    }
    return '${value.substring(0, 6)}...${value.substring(value.length - 6)}';
  }
}

class _ApprovalFileRow extends StatelessWidget {
  const _ApprovalFileRow({required this.fileName, required this.fileSize});

  final String fileName;
  final String fileSize;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final extension = _extensionLabel(fileName);

    return Container(
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        spacing: 12,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              _fileIcon(extension),
              size: 22,
              color: colorScheme.primary,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: [
                Text(
                  fileName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  fileSize,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          _DetailPill(icon: Icons.description_rounded, label: extension),
        ],
      ),
    );
  }

  static IconData _fileIcon(String extension) {
    final lower = extension.toLowerCase();
    if (const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'}.contains(lower)) {
      return Icons.image_rounded;
    }
    if (const {'mp4', 'mov', 'mkv', 'webm', 'avi'}.contains(lower)) {
      return Icons.movie_rounded;
    }
    if (const {'mp3', 'wav', 'flac', 'm4a', 'aac'}.contains(lower)) {
      return Icons.music_note_rounded;
    }
    if (const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(lower)) {
      return Icons.archive_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  static String _extensionLabel(String fileName) {
    final extensionIndex = fileName.lastIndexOf('.');
    if (extensionIndex <= 0 || extensionIndex == fileName.length - 1) {
      return 'FILE';
    }
    final extension = fileName.substring(extensionIndex + 1).toUpperCase();
    return extension.length > 5 ? extension.substring(0, 5) : extension;
  }
}

class _DetailPill extends StatelessWidget {
  const _DetailPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      constraints: const BoxConstraints(minHeight: 30),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
