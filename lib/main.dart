import 'dart:async';
import 'dart:io';

import 'package:disable_battery_optimization/disable_battery_optimization.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flashbyte/classes/android_connection_notification_service.dart';
import 'package:flashbyte/classes/app_appearance_controller.dart';
import 'package:flashbyte/tcp_socket_pages/file_selection_page.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:heroine/heroine.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:motor/motor.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppAppearanceController.instance.load();
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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appearanceController,
      builder: (context, child) {
        return DynamicColorBuilder(
          builder: (lightDynamic, darkDynamic) {
            return MaterialApp(
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

  @override
  Widget build(BuildContext context) => widget.child;
}

class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
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
              child:
                  StarWidget(
                    key: ValueKey(
                      '${primaryColor.value}-${brightness.name}',
                    ),
                  ).animate().fadeIn(
                    duration: 450.ms,
                    curve: Curves.easeOutCubic,
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
                        )
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
                    SizedBox(
                      height: 200,
                    ),
                  ],
                ),
                Spacer(),
                Column(
                  spacing: 12,
                  children: [
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
                        )
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
                        )
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
    final primaryColor = colorScheme.primary;
    final brightness = Theme.of(context).brightness;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.surface,
            colorScheme.surfaceContainerLow.withValues(alpha: 0.72),
          ],
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 40),
            child: Row(
              spacing: 64,
              children: [
                Expanded(
                  flex: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      DecoratedBox(
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              child: Text(
                                "LOCAL  •  DIRECT  •  YOURS",
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      color: colorScheme.onPrimaryContainer,
                                      letterSpacing: 1.2,
                                    ),
                              ),
                            ),
                          )
                          .animate()
                          .fadeIn(duration: 320.ms)
                          .slideY(
                            begin: 0.08,
                            end: 0,
                            duration: 320.ms,
                            curve: Curves.easeOutCubic,
                          ),
                      const SizedBox(height: 26),
                      Text(
                            "Move files.\nSkip the cloud.",
                            style: Theme.of(context).textTheme.displayLarge
                                ?.copyWith(
                                  fontSize: 64,
                                  height: 0.98,
                                  letterSpacing: -2.6,
                                  fontWeight: FontWeight.w600,
                                ),
                          )
                          .animate()
                          .fadeIn(delay: 80.ms, duration: 400.ms)
                          .slideY(
                            begin: 0.05,
                            end: 0,
                            delay: 80.ms,
                            duration: 400.ms,
                            curve: Curves.easeOutCubic,
                          ),
                      const SizedBox(height: 22),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child:
                            Text(
                                  "Private, fast file sharing for devices on the same network. No accounts, uploads, or detours.",
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        height: 1.5,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                )
                                .animate()
                                .fadeIn(delay: 150.ms, duration: 380.ms)
                                .slideY(
                                  begin: 0.05,
                                  end: 0,
                                  delay: 150.ms,
                                  duration: 380.ms,
                                  curve: Curves.easeOutCubic,
                                ),
                      ),
                      const SizedBox(height: 32),
                      Row(
                        spacing: 20,
                        children: [
                          _buildFeature(
                            Icons.shield_outlined,
                            "Private by design",
                          ),
                          _buildFeature(Icons.bolt_rounded, "Network speed"),
                          _buildFeature(
                            Icons.devices_rounded,
                            "Cross-platform",
                          ),
                        ],
                      ).animate().fadeIn(
                        delay: 220.ms,
                        duration: 360.ms,
                      ),
                      const SizedBox(height: 44),
                      Row(
                        children: [
                          Expanded(
                            child: _HomeActionCard(
                              icon: Icons.north_east_rounded,
                              title: "Send files",
                              subtitle: "Choose files and find a nearby device",
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
                              subtitle: "Make this device visible and ready",
                              backgroundColor: colorScheme.primary,
                              foregroundColor: colorScheme.onPrimary,
                              onTap: () => _openSharing(1),
                            ),
                          ),
                        ],
                      ).animate().fadeIn(
                        delay: 280.ms,
                        duration: 380.ms,
                        curve: Curves.easeOutCubic,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 5,
                  child:
                      Container(
                            constraints: const BoxConstraints(
                              minHeight: 520,
                              maxHeight: 620,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainer,
                              borderRadius: BorderRadius.circular(32),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.08),
                                  blurRadius: 1,
                                  spreadRadius: 1,
                                ),
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.06),
                                  blurRadius: 22,
                                  offset: const Offset(0, 12),
                                ),
                              ],
                            ),
                            child: Stack(
                              children: [
                                Positioned(
                                  top: 30,
                                  left: 30,
                                  child: _NetworkNode(
                                    icon: Icons.laptop_rounded,
                                    color: colorScheme.tertiaryContainer,
                                    foreground: colorScheme.onTertiaryContainer,
                                  ),
                                ),
                                Positioned(
                                  right: 34,
                                  bottom: 94,
                                  child: _NetworkNode(
                                    icon: Icons.smartphone_rounded,
                                    color: colorScheme.secondaryContainer,
                                    foreground:
                                        colorScheme.onSecondaryContainer,
                                  ),
                                ),
                                Center(
                                  child: RepaintBoundary(
                                    child: StarWidget(
                                      key: ValueKey(
                                        'desktop-${primaryColor.value}-${brightness.name}',
                                      ),
                                      size: 270,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: 28,
                                  right: 28,
                                  bottom: 26,
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.wifi_tethering_rounded,
                                        size: 20,
                                        color: colorScheme.primary,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          "Drag and flick the shape. Your files stay closer.",
                                          style:
                                              Theme.of(
                                                context,
                                              ).textTheme.bodyMedium?.copyWith(
                                                color: colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          )
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeature(IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 7,
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        Text(label, style: Theme.of(context).textTheme.labelLarge),
      ],
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
    return AnimatedScale(
      scale: _pressed ? 0.96 : 1,
      duration: const Duration(milliseconds: 120),
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
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 148),
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
  });

  final IconData icon;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
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
    );
  }
}

class StarWidget extends StatefulWidget {
  const StarWidget({super.key, this.size = 200});

  final double size;

  @override
  State<StarWidget> createState() => _StarWidgetState();
}

class _StarWidgetState extends State<StarWidget>
    with SingleTickerProviderStateMixin {
  double rotation = 0.0;

  final List<RoundedPolygon> shapeList = [
    MaterialShapes.clover4Leaf,
    MaterialShapes.verySunny,
    MaterialShapes.pill,
    MaterialShapes.flower,
    MaterialShapes.oval,
    MaterialShapes.sunny,
    MaterialShapes.arch,
  ];

  int current = 0;
  int nextIndex = 0;

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

    WidgetsBinding.instance.addPostFrameCallback(
      (_) => setState(() => rotation = -5),
    );
  }

  void goToShape(int newIndex) {
    setState(() {
      nextIndex = newIndex;

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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) {
        setState(() {
          rotation += details.delta.dx / 75;
          rotation += details.delta.dy / -75;
        });
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
        child: AnimatedBuilder(
          animation: controller,
          builder: (_, _) {
            return CustomPaint(
              painter: MorphPainter(
                color: Theme.of(context).colorScheme.primary,
                morph: morph,
                progress: controller.value,
              ),
              child: SizedBox(
                width: widget.size,
                height: widget.size,
              ),
            );
          },
        ),
      ),
    );
  }
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
