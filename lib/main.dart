import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:disable_battery_optimization/disable_battery_optimization.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flashbyte/models/discovered_device.dart';
import 'package:flashbyte/services/discovery/device_discovery_service.dart';
import 'package:flashbyte/services/platform/android_connection_notification_service.dart';
import 'package:flashbyte/app/app_settings.dart';
import 'package:flashbyte/app/controllers/app_appearance_controller.dart';
import 'package:flashbyte/app/controllers/app_motion_controller.dart';
import 'package:flashbyte/services/security/tls_identity_service.dart';
import 'package:flashbyte/features/settings/settings_page.dart';
import 'package:flashbyte/features/transfers/pages/file_selection_page.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:heroine/heroine.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:motor/motor.dart';
import 'package:shared_preferences/shared_preferences.dart';

@pragma('vm:entry-point')
Future<void> onNotificationActionReceived(ReceivedAction receivedAction) async {
  await AndroidConnectionNotificationService.instance.handleNotificationAction(
    receivedAction,
  );
}

@pragma('vm:entry-point')
Future<void> onNotificationDismissed(ReceivedAction receivedAction) async {
  await AndroidConnectionNotificationService.instance
      .handleNotificationDismissed(
        receivedAction,
      );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AwesomeNotifications().initialize(
    'resource://drawable/ic_notification',
    [
      NotificationChannel(
        channelKey: 'tcp_connection_service',
        channelName: 'TCP connection service',
        channelDescription:
            'Shows when Flashbyte has an active TCP connection.',
        channelShowBadge: false,
        importance: NotificationImportance.Min,
        playSound: false,
        enableVibration: false,
        onlyAlertOnce: true,
      ),
      NotificationChannel(
        channelKey: 'file_transfer_progress',
        channelName: 'File transfer progress',
        channelDescription: 'Shows active Flashbyte file transfer progress.',
        channelShowBadge: false,
        importance: NotificationImportance.High,
        playSound: false,
        enableVibration: false,
        onlyAlertOnce: true,
      ),
      NotificationChannel(
        channelKey: 'file_offers',
        channelName: 'File offers',
        channelDescription: 'Shows incoming file offers and pending sends.',
        channelShowBadge: false,
        importance: NotificationImportance.High,
        playSound: false,
        enableVibration: false,
        onlyAlertOnce: true,
      ),
    ],
  );

  await AwesomeNotifications().setListeners(
    onActionReceivedMethod: onNotificationActionReceived,
    onDismissActionReceivedMethod: onNotificationDismissed,
  );

  if (await AppSettings.getUseTls()) {
    await TlsIdentityService.getOrCreateIdentity();
  }
  await AppAppearanceController.instance.load();
  await AppMotionController.instance.load();

  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  final AppAppearanceController appearanceController =
      AppAppearanceController.instance;
  final AppMotionController motionController = AppMotionController.instance;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([appearanceController, motionController]),
      builder: (context, child) {
        return DynamicColorBuilder(
          builder: (lightDynamic, darkDynamic) {
            return MaterialApp(
              builder: (context, child) {
                final data = MediaQuery.of(context);
                return MediaQuery(
                  data: data.copyWith(
                    disableAnimations: motionController.disableAnimations,
                  ),
                  child: child ?? const SizedBox.shrink(),
                );
              },
              theme: appearanceController.buildTheme(
                brightness: Brightness.light,
                dynamicScheme: lightDynamic,
              ),
              darkTheme: appearanceController.buildTheme(
                brightness: Brightness.dark,
                dynamicScheme: darkDynamic,
              ),
              themeMode: appearanceController.themeMode,
              home: const StartupEffects(child: StartPage()),
              navigatorObservers: [HeroineController()],
            );
          },
        );
      },
    );
  }
}

class StartupEffects extends StatefulWidget {
  const StartupEffects({required this.child, super.key});

  final Widget child;

  @override
  State<StartupEffects> createState() => _StartupEffectsState();
}

class _StartupEffectsState extends State<StartupEffects> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(AndroidConnectionNotificationService.instance.initialize());
      unawaited(_showBatteryOptimizationPromptIfNeeded());
      unawaited(_requestNotificationPermissionIfNeeded());
    });
  }

  Future<void> _showBatteryOptimizationPromptIfNeeded() async {
    if (!Platform.isAndroid || !mounted) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    if (!mounted || (prefs.getBool('hideBatteryOptimizationPrompt') ?? false)) {
      return;
    }

    final disabled =
        await DisableBatteryOptimization.isBatteryOptimizationDisabled == true;
    if (!mounted || disabled) {
      return;
    }

    var doNotShowAgain = false;
    final shouldOpenSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Allow background transfers'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Disable battery optimization for Flashbyte so active '
                    'connections and file transfers can keep running in the '
                    'background.',
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: doNotShowAgain,
                    title: const Text('Do not show again'),
                    subtitle: null,
                    onChanged: (value) {
                      setDialogState(() {
                        doNotShowAgain = value ?? false;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Not now'),
                ),
                FilledButton(
                  onPressed: doNotShowAgain
                      ? null
                      : () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Disable'),
                ),
              ],
            );
          },
        );
      },
    );

    if (doNotShowAgain) {
      await prefs.setBool('hideBatteryOptimizationPrompt', true);
    }

    if (shouldOpenSettings == true) {
      await DisableBatteryOptimization.showDisableBatteryOptimizationSettings();
    }
  }

  Future<void> _requestNotificationPermissionIfNeeded() async {
    if (!mounted) return;
    try {
      final allowed = await AwesomeNotifications().isNotificationAllowed();
      if (!allowed) {
        await AwesomeNotifications().requestPermissionToSendNotifications();
      }
    } catch (_) {
      // Notifications not supported on this platform (Windows, Linux, etc.)
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  List<DiscoveredDevice> _devices = [];
  final _starRotationTarget = ValueNotifier<double>(0);
  StreamSubscription<List<DiscoveredDevice>>? _discoverySub;
  int _previousDeviceCount = 0;
  final _seenDeviceIds = <String>{};

  @override
  void initState() {
    super.initState();
    _initDiscovery();
  }

  Future<void> _initDiscovery() async {
    try {
      final id = await AppSettings.getDeviceId();
      final port = await AppSettings.getPort();
      await DeviceDiscoveryService.instance.startDiscovery(
        localDeviceId: id,
        port: port,
      );
      DeviceDiscoveryService.instance.requestRefresh();
      if (mounted) {
        setState(() => _devices = DeviceDiscoveryService.instance.devices);
      }
    } catch (_) {}
    _discoverySub = DeviceDiscoveryService.instance.devicesStream.listen((d) {
      if (mounted) setState(() => _devices = d);
    });
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    DeviceDiscoveryService.instance.stopDiscovery();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final useDesktopLayout =
        !Platform.isAndroid &&
        !Platform.isIOS &&
        MediaQuery.sizeOf(context).width >= 1000;

    return Scaffold(
      body: SafeArea(
        child: useDesktopLayout ? _buildDesktopHome() : _buildMobileHome(),
      ),
    );
  }

  Widget _buildMobileHome() {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final brightness = Theme.of(context).brightness;

    return Stack(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Transform.translate(
            offset: Offset(50, 0),
            child: RepaintBoundary(
              child: _maybeAnimate(
                context,
                StarWidget(
                  key: ValueKey(
                    '${primaryColor.value}-${brightness.name}',
                  ),
                ),
                (child) => child.animate().fadeIn(
                  duration: 450.ms,
                  curve: Curves.easeOutCubic,
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: SizedBox(
            height: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _maybeAnimate(
                      context,
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Flash\nByte",
                            style: TextStyle(
                              fontSize: 50,
                              color: Theme.of(
                                context,
                              ).colorScheme.primaryFixed,
                            ),
                          ),
                          SizedBox(
                            height: 10,
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 5),
                            child: Text(
                              "Local file sharing",
                              style: TextStyle(
                                fontSize: 18,
                                color: Theme.of(
                                  context,
                                ).colorScheme.secondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      (child) => child
                          .animate()
                          .fadeIn(
                            delay: 80.ms,
                            duration: 420.ms,
                            curve: Curves.easeOutCubic,
                          )
                          .slideY(
                            begin: 0.06,
                            end: 0,
                            delay: 80.ms,
                            duration: 420.ms,
                            curve: Curves.easeOutCubic,
                          ),
                    ),
                    SizedBox(
                      height: 200,
                    ),
                  ],
                ),
                Spacer(),
                Column(
                  spacing: 12,
                  children: [
                    _maybeAnimate(
                      context,
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonal(
                          style: ButtonStyle(
                            padding: WidgetStatePropertyAll(
                              EdgeInsets.symmetric(vertical: 22),
                            ),
                          ),
                          onPressed: () => _openSharing(0),
                          child: const Text("Send"),
                        ),
                      ),
                      (child) => child
                          .animate()
                          .fadeIn(
                            delay: 170.ms,
                            duration: 360.ms,
                            curve: Curves.easeOutCubic,
                          )
                          .slideY(
                            begin: 0.05,
                            end: 0,
                            delay: 170.ms,
                            duration: 360.ms,
                            curve: Curves.easeOutCubic,
                          ),
                    ),
                    _maybeAnimate(
                      context,
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: ButtonStyle(
                            padding: WidgetStatePropertyAll(
                              EdgeInsets.symmetric(vertical: 22),
                            ),
                          ),
                          onPressed: () => _openSharing(1),
                          child: const Text("Receive"),
                        ),
                      ),
                      (child) => child
                          .animate()
                          .fadeIn(
                            delay: 240.ms,
                            duration: 360.ms,
                            curve: Curves.easeOutCubic,
                          )
                          .slideY(
                            begin: 0.05,
                            end: 0,
                            delay: 240.ms,
                            duration: 360.ms,
                            curve: Curves.easeOutCubic,
                          ),
                    ),
                    _maybeAnimate(
                      context,
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonalIcon(
                          style: const ButtonStyle(
                            padding: WidgetStatePropertyAll(
                              EdgeInsets.symmetric(vertical: 20),
                            ),
                          ),
                          onPressed: _openSettings,
                          icon: const Icon(Icons.settings_rounded),
                          label: const Text("Settings"),
                        ),
                      ),
                      (child) => child
                          .animate()
                          .fadeIn(
                            delay: 300.ms,
                            duration: 340.ms,
                            curve: Curves.easeOutCubic,
                          )
                          .slideY(
                            begin: 0.05,
                            end: 0,
                            delay: 300.ms,
                            duration: 340.ms,
                            curve: Curves.easeOutCubic,
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopHome() {
    final colorScheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: colorScheme.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
            child: Row(
              spacing: 48,
              children: [
                Expanded(
                  flex: 5,
                  child: SizedBox(
                    height: 440,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _maybeAnimate(
                          context,
                          Text(
                            "Flashbyte",
                            style: Theme.of(context).textTheme.displayMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          (child) => child
                              .animate()
                              .fadeIn(duration: 360.ms)
                              .slideY(
                                begin: 0.05,
                                end: 0,
                                duration: 360.ms,
                                curve: Curves.easeOutCubic,
                              ),
                        ),
                        const SizedBox(height: 10),
                        _maybeAnimate(
                          context,
                          Text(
                            "Share files with devices on your local network.",
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  height: 1.4,
                                ),
                          ),
                          (child) => child.animate().fadeIn(
                            delay: 70.ms,
                            duration: 340.ms,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          "Start a transfer",
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 14),
                        _maybeAnimate(
                          context,
                          Row(
                            children: [
                              Expanded(
                                child: _HomeActionCard(
                                  icon: Icons.north_east_rounded,
                                  title: "Send files",
                                  subtitle: "Choose files",
                                  backgroundColor:
                                      colorScheme.surfaceContainerHighest,
                                  foregroundColor: colorScheme.onSurface,
                                  onTap: () => _openSharing(0),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: _HomeActionCard(
                                  icon: Icons.south_west_rounded,
                                  title: "Receive files",
                                  subtitle: "Wait for a sender",
                                  backgroundColor: colorScheme.primary,
                                  foregroundColor: colorScheme.onPrimary,
                                  onTap: () => _openSharing(1),
                                ),
                              ),
                            ],
                          ),
                          (child) => child
                              .animate()
                              .fadeIn(delay: 140.ms, duration: 360.ms)
                              .slideY(
                                begin: 0.04,
                                end: 0,
                                delay: 140.ms,
                                duration: 360.ms,
                                curve: Curves.easeOutCubic,
                              ),
                        ),
                        const SizedBox(height: 12),
                        _maybeAnimate(
                          context,
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: FilledButton.tonalIcon(
                              onPressed: _openSettings,
                              icon: const Icon(Icons.settings_rounded),
                              label: const Text("Settings"),
                            ),
                          ),
                          (child) => child
                              .animate()
                              .fadeIn(delay: 200.ms, duration: 340.ms)
                              .slideY(
                                begin: 0.04,
                                end: 0,
                                delay: 200.ms,
                                duration: 340.ms,
                                curve: Curves.easeOutCubic,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  flex: 5,
                  child: _maybeAnimate(
                    context,
                    Container(
                      height: 440,
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 1,
                            spreadRadius: 1,
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.04),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: _buildOrbitLayout(colorScheme),
                    ),
                    (child) => child
                        .animate()
                        .fadeIn(delay: 120.ms, duration: 480.ms)
                        .scale(
                          begin: const Offset(0.98, 0.98),
                          end: const Offset(1, 1),
                          delay: 120.ms,
                          duration: 480.ms,
                          curve: Curves.easeOutCubic,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSharing(int initialTabIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            FileSelectionPage(initialTabIndex: initialTabIndex),
      ),
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SettingsPage()),
    );
  }

  Widget _buildOrbitLayout(ColorScheme colorScheme) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    if (_devices.length > _previousDeviceCount) {
      _starRotationTarget.value += 1;
    } else if (_devices.length < _previousDeviceCount) {
      _starRotationTarget.value -= 1;
    }
    _previousDeviceCount = _devices.length;

    final configs = _buildNodeConfigs(colorScheme);

    final starWidget = RepaintBoundary(
      child: StarWidget(
        key: ValueKey(
          'desktop-${colorScheme.primary.value}-${Theme.of(context).brightness.name}',
        ),
        size: 220,
        rotationTarget: _starRotationTarget,
      ),
    );

    if (reducedMotion) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Center(child: starWidget),
          for (final c in configs)
            _OrbitingNode(
              angle: c.angle,
              radius: c.radius,
              child: c.widget,
            ),
        ],
      );
    }

    return ListenableBuilder(
      listenable: _starRotationTarget,
      builder: (context, _) {
        return MotionBuilder(
          converter: SingleMotionConverter(),
          value: _starRotationTarget.value * 0.5,
          motion: Motion.smoothSpring(),
          child: starWidget,
          builder: (context, orbitValue, child) {
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Center(child: child!),
                for (final c in configs)
                  _OrbitingNode(
                    angle: c.angle + orbitValue,
                    radius: c.radius,
                    child: c.widget,
                  ),
              ],
            );
          },
        );
      },
    );
  }

  List<_NodeConfig> _buildNodeConfigs(ColorScheme colorScheme) {
    const maxNodes = 6;
    const remainingSlots = maxNodes - 1;
    final deviceCount = _devices.length;
    final showOverflow = deviceCount > remainingSlots;
    final nodeCount = showOverflow ? remainingSlots : deviceCount;

    const radii = [175.0, 175.0, 175.0, 175.0, 140.0, 140.0];
    const angles = [
      -0.79,
      -2.36,
      0.79,
      2.36,
      0.0,
      3.14,
    ];

    final isPhone = Platform.isAndroid || Platform.isIOS;
    final configs = <_NodeConfig>[
      _NodeConfig(
        angle: angles[0],
        radius: radii[0],
        widget: _NetworkNode(
          icon: isPhone ? Icons.phone_iphone_rounded : Icons.laptop_rounded,
          color: colorScheme.primaryContainer,
          foreground: colorScheme.onPrimaryContainer,
          badge: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.primary,
              borderRadius: BorderRadius.circular(100),
              border: Border.all(color: colorScheme.surface, width: 2),
            ),
            child: Text(
              'You',
              style: TextStyle(
                color: colorScheme.onPrimary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    ];

    for (var i = 0; i < nodeCount; i++) {
      final slot = i + 1;
      Widget node;
      if (showOverflow && i == remainingSlots - 1) {
        node = _NetworkNode(
          icon: Icons.more_horiz_rounded,
          label: '+${deviceCount - remainingSlots + 1}',
          color: colorScheme.surfaceContainerHighest,
          foreground: colorScheme.onSurfaceVariant,
        );
      } else {
        final device = _devices[i];
        final isNew = _seenDeviceIds.add(device.id);
        node = _NetworkNode(
          icon: device.type == DiscoveredDeviceType.laptop
              ? Icons.laptop_rounded
              : Icons.smartphone_rounded,
          color: device.type == DiscoveredDeviceType.laptop
              ? colorScheme.tertiaryContainer
              : colorScheme.secondaryContainer,
          foreground: device.type == DiscoveredDeviceType.laptop
              ? colorScheme.onTertiaryContainer
              : colorScheme.onSecondaryContainer,
        );
        if (isNew) {
          node = node
              .animate()
              .fadeIn(
                duration: 400.ms,
                curve: Curves.easeOutCubic,
              )
              .scale(
                begin: const Offset(0.5, 0.5),
                end: const Offset(1, 1),
                duration: 400.ms,
                curve: Curves.easeOutCubic,
              );
        }
      }
      configs.add(
        _NodeConfig(angle: angles[slot], radius: radii[slot], widget: node),
      );
    }
    return configs;
  }
}

class _HomeActionCard extends StatefulWidget {
  const _HomeActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onTap;

  @override
  State<_HomeActionCard> createState() => _HomeActionCardState();
}

class _HomeActionCardState extends State<_HomeActionCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    return AnimatedScale(
      scale: _pressed ? 0.96 : 1,
      duration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      child: Material(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onHighlightChanged: (value) {
            setState(() {
              _pressed = value;
            });
          },
          onTap: widget.onTap,
          child: SizedBox(
            height: 148,
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(widget.icon, color: widget.foregroundColor, size: 28),
                  const Spacer(),
                  Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: widget.foregroundColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    widget.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: widget.foregroundColor.withValues(alpha: 0.72),
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NetworkNode extends StatelessWidget {
  const _NetworkNode({
    required this.icon,
    required this.color,
    required this.foreground,
    this.label,
    this.badge,
  });

  final IconData icon;
  final Color color;
  final Color foreground;
  final String? label;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.07),
                    blurRadius: 12,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: SizedBox.square(
                dimension: 58,
                child: Icon(icon, color: foreground, size: 25),
              ),
            ),
            if (badge != null) Positioned(top: -4, right: -4, child: badge!),
          ],
        ),
        if (label != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              label!,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: foreground),
            ),
          ),
      ],
    );
  }
}

class _NodeConfig {
  const _NodeConfig({
    required this.angle,
    required this.radius,
    required this.widget,
  });
  final double angle;
  final double radius;
  final Widget widget;
}

class _OrbitingNode extends StatelessWidget {
  const _OrbitingNode({
    required this.angle,
    required this.radius,
    required this.child,
  });

  final double angle;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: Transform.translate(
        offset: Offset(
          radius * math.cos(angle),
          radius * math.sin(angle),
        ),
        child: child,
      ),
    );
  }
}

class StarWidget extends StatefulWidget {
  const StarWidget({super.key, this.size = 200, this.rotationTarget});

  final double size;
  final ValueNotifier<double>? rotationTarget;

  @override
  State<StarWidget> createState() => _StarWidgetState();
}

class _StarWidgetState extends State<StarWidget>
    with SingleTickerProviderStateMixin {
  double rotation = 0.0;
  late double _lastAngle;

  final List<RoundedPolygon> shapeList = [
    MaterialShapes.clover4Leaf,
    MaterialShapes.verySunny,
    MaterialShapes.pill,
    MaterialShapes.flower,
    MaterialShapes.oval,
    MaterialShapes.diamond,
    MaterialShapes.sunny,
    MaterialShapes.arch,
  ];

  int current = 0;

  late Morph morph;
  late AnimationController controller;

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    morph = Morph(
      shapeList[current],
      shapeList[current],
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      rotation = -5;
      widget.rotationTarget?.value = rotation;
      if (mounted) setState(() {});
    });
  }

  void goToShape(int newIndex) {
    setState(() {
      morph = Morph(
        shapeList[current],
        shapeList[newIndex],
      );

      controller.forward(from: 0);
      current = newIndex;
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final paintedShape = AnimatedBuilder(
      animation: controller,
      builder: (_, _) {
        return CustomPaint(
          painter: MorphPainter(
            color: Theme.of(context).colorScheme.primary,
            morph: morph,
            progress: reducedMotion ? 1 : controller.value,
          ),
          child: SizedBox(
            width: widget.size,
            height: widget.size,
          ),
        );
      },
    );

    if (reducedMotion) {
      return paintedShape;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (details) {
        final c = widget.size / 2;
        _lastAngle = math.atan2(
          details.localPosition.dy - c,
          details.localPosition.dx - c,
        );
      },
      onPanUpdate: (details) {
        final c = widget.size / 2;
        final angle = math.atan2(
          details.localPosition.dy - c,
          details.localPosition.dx - c,
        );
        setState(() {
          var delta = angle - _lastAngle;
          if (delta > math.pi) delta -= 2 * math.pi;
          if (delta < -math.pi) delta += 2 * math.pi;
          rotation += delta;
        });
        _lastAngle = angle;
        widget.rotationTarget?.value = rotation;
      },
      onPanEnd: (details) {
        final v = details.velocity.pixelsPerSecond.dy;
        final h = details.velocity.pixelsPerSecond.dx;

        final isSpun = ((v + h) / 3500) >= 1;
        final isSpunReverse = ((v + h) / 3500) <= -1;

        if (isSpun) {
          final newIndex = (current + 1) % shapeList.length;
          HapticFeedback.vibrate();
          goToShape(newIndex);
        } else if (isSpunReverse) {
          final newIndex = (current - 1 + shapeList.length) % shapeList.length;
          HapticFeedback.vibrate();
          goToShape(newIndex);
        }
      },
      child: MotionBuilder(
        converter: SingleMotionConverter(),
        value: rotation,
        motion: Motion.bouncySpring(),
        builder: (context, value, child) {
          return Transform.rotate(
            angle: value,
            child: child,
          );
        },
        child: paintedShape,
      ),
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

class MorphPainter extends CustomPainter {
  final Morph morph;
  final Color color;
  final double progress;

  MorphPainter({
    required this.color,
    required this.morph,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = morph.toPath(progress: progress);

    canvas
      ..save()
      ..scale(size.width)
      ..drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..color = color,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(covariant MorphPainter old) {
    return old.morph != morph || old.progress != progress;
  }
}
