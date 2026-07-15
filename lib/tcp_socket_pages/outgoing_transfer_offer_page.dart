import 'dart:async';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/classes/device_discovery_service.dart';
import 'package:flashbyte/classes/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

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
        backgroundColor: colorScheme.surfaceContainerLowest,
        appBar: AppBar(
          backgroundColor: colorScheme.surfaceContainerLowest,
          centerTitle: true,
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
    final receiverPort =
        (_receiver?['port'] as int?) ?? widget.receiverPreview?.port;
    final totalFiles = widget.files.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ApprovalHeader(
              icon: Icons.schedule_send_rounded,
              title: 'Waiting for approval',
              message:
                  'The receiver needs to accept this request before sending begins.',
            )
            .animate()
            .fadeIn(duration: 180.ms)
            .slideY(begin: 0.05, end: 0, curve: Curves.easeOutCubic),
        const SizedBox(height: 20),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 720;
              final deviceCard = _OfferSurface(
                title: 'Devices',
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 12,
                    children: [
                      _ApprovalDeviceRow(
                            label: 'This device',
                            name: widget.senderName,
                            detail: _deviceTypeLabel(widget.senderType),
                            type: widget.senderType,
                            address: 'Local sender',
                            port: null,
                            usesTls: widget.senderUsesTls,
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
                      _TransferDirectionDivider(
                        secure: receiverUsesTls && widget.senderUsesTls,
                      ),
                      _ApprovalDeviceRow(
                            label: 'Receiver',
                            name: receiverName,
                            detail: _deviceTypeLabel(receiverType),
                            type: receiverType,
                            address: receiverAddress ?? 'Address pending',
                            port: receiverPort,
                            usesTls: receiverUsesTls,
                            color: colorScheme.primaryContainer,
                            foregroundColor: colorScheme.onPrimaryContainer,
                          )
                          .animate()
                          .fadeIn(delay: 220.ms, duration: 180.ms)
                          .slideY(
                            begin: 0.05,
                            end: 0,
                            curve: Curves.easeOutCubic,
                          ),
                    ],
                  ),
                ),
              );
              final filesCard = _OfferSurface(
                title:
                    '$totalFiles ${totalFiles == 1 ? 'file' : 'files'} selected',
                fillChild: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                        itemCount: widget.files.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final file = widget.files[index];
                          return _ApprovalFileRow(fileName: file.name)
                              .animate()
                              .fadeIn(
                                delay: (180 + index * 45).ms,
                                duration: 160.ms,
                              )
                              .slideY(
                                begin: 0.05,
                                end: 0,
                                curve: Curves.easeOutCubic,
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
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  deviceCard,
                  const SizedBox(height: 12),
                  Expanded(child: filesCard),
                ],
              );
            },
          ).animate().fadeIn(delay: 140.ms, duration: 180.ms),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
              onPressed: _cancel,
              icon: const Icon(Icons.close_rounded),
              label: const Text('Cancel transfer'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            )
            .animate()
            .fadeIn(delay: 300.ms, duration: 180.ms)
            .slideY(
              begin: 0.05,
              end: 0,
              curve: Curves.easeOutCubic,
            ),
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

  String _deviceTypeLabel(DiscoveredDeviceType type) {
    return type == DiscoveredDeviceType.laptop ? 'Desktop or laptop' : 'Phone';
  }
}

enum _OutgoingOfferOutcome { declined, connectionEnded }

class _OfferSurface extends StatelessWidget {
  const _OfferSurface({
    required this.title,
    required this.child,
    this.fillChild = false,
  });

  final String title;
  final Widget child;
  final bool fillChild;

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
          if (fillChild) Expanded(child: child) else child,
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
  final Color color;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.68),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 124),
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
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
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
                  _DetailPill(
                    icon: Icons.devices_rounded,
                    label: detail,
                  ),
                  _DetailPill(
                    icon: Icons.lan_rounded,
                    label: address,
                  ),
                  if (port != null)
                    _DetailPill(
                      icon: Icons.numbers_rounded,
                      label: 'Port $port',
                    ),
                  _DetailPill(
                    icon: usesTls
                        ? Icons.lock_rounded
                        : Icons.lock_open_rounded,
                    label: usesTls ? 'TLS enabled' : 'Unencrypted',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ApprovalFileRow extends StatelessWidget {
  const _ApprovalFileRow({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final extension = _extensionLabel(fileName);

    return Container(
      constraints: const BoxConstraints(minHeight: 58),
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
              _fileIcon(extension),
              size: 20,
              color: colorScheme.primary,
            ),
          ),
          Expanded(
            child: Text(
              fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
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
