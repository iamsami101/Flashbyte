import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:motor/motor.dart';

class InteractiveStarWidget extends StatefulWidget {
  const InteractiveStarWidget({
    super.key,
    this.size = 220,
    this.isActive = true,
  });

  final double size;
  final bool isActive;

  @override
  State<InteractiveStarWidget> createState() => _InteractiveStarWidgetState();
}

class _InteractiveStarWidgetState extends State<InteractiveStarWidget>
    with TickerProviderStateMixin {
  final List<RoundedPolygon> _shapes = [
    MaterialShapes.clover4Leaf,
    MaterialShapes.verySunny,
    MaterialShapes.pill,
    MaterialShapes.flower,
    MaterialShapes.oval,
    MaterialShapes.diamond,
    MaterialShapes.sunny,
    MaterialShapes.arch,
  ];

  late final AnimationController _morphController;
  late Morph _morph;
  Timer? _resumeTimer;
  double _rotationTarget = 0;
  Motion _rotationMotion = const Motion.curved(
    Duration(milliseconds: 2200),
    Curves.linear,
  );
  int _currentShape = 0;
  int _idleGeneration = 0;

  @override
  void initState() {
    super.initState();
    _morph = Morph(_shapes.first, _shapes.first);
    _morphController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    if (widget.isActive) {
      _startIdleLoop();
    }
  }

  @override
  void didUpdateWidget(covariant InteractiveStarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive == oldWidget.isActive) return;
    if (widget.isActive) {
      _startIdleLoop();
    } else {
      _pauseIdle();
    }
  }

  void _startIdleLoop() {
    final generation = ++_idleGeneration;
    _runIdleCycle(generation);
  }

  Future<void> _runIdleCycle(int generation) async {
    while (mounted && widget.isActive && generation == _idleGeneration) {
      _setIdleRotation(
        turns: 0.7,
        duration: const Duration(milliseconds: 2200),
        curve: Curves.linear,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      if (!_shouldContinueIdle(generation)) return;

      _setIdleRotation(
        turns: 1.35,
        duration: const Duration(milliseconds: 1500),
        curve: Curves.easeInCubic,
      );
      await Future<void>.delayed(const Duration(milliseconds: 720));
      if (!_shouldContinueIdle(generation)) return;
      _goToShape((_currentShape + 1) % _shapes.length);
      await Future<void>.delayed(const Duration(milliseconds: 780));
      if (!_shouldContinueIdle(generation)) return;

      _setIdleRotation(
        turns: 0.65,
        duration: const Duration(milliseconds: 1700),
        curve: Curves.easeOutCubic,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1700));
    }
  }

  bool _shouldContinueIdle(int generation) {
    return mounted && widget.isActive && generation == _idleGeneration;
  }

  void _setIdleRotation({
    required double turns,
    required Duration duration,
    required Curve curve,
  }) {
    if (!mounted) return;
    setState(() {
      _rotationTarget += turns * 6.283185307179586;
      _rotationMotion = Motion.curved(duration, curve);
    });
  }

  void _goToShape(int next) {
    _morph = Morph(_shapes[_currentShape], _shapes[next]);
    _currentShape = next;
    _morphController.forward(from: 0);
  }

  void _pauseIdle() {
    _resumeTimer?.cancel();
    _idleGeneration++;
    setState(() => _rotationMotion = const Motion.interactiveSpring());
  }

  void _resumeIdle() {
    _resumeTimer?.cancel();
    if (!widget.isActive) return;
    _resumeTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted && widget.isActive) _startIdleLoop();
    });
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _morphController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => _pauseIdle(),
      onPanUpdate: (details) {
        setState(() {
          _rotationTarget += details.delta.dx / 75;
          _rotationTarget += details.delta.dy / -75;
          _rotationMotion = const Motion.interactiveSpring();
        });
      },
      onPanEnd: (details) {
        final velocity = details.velocity.pixelsPerSecond;
        final spin = (velocity.dy + velocity.dx) / 3500;
        if (spin >= 1) {
          HapticFeedback.vibrate();
          _goToShape((_currentShape + 1) % _shapes.length);
        } else if (spin <= -1) {
          HapticFeedback.vibrate();
          _goToShape((_currentShape - 1 + _shapes.length) % _shapes.length);
        }
        _resumeIdle();
      },
      onPanCancel: _resumeIdle,
      child: SingleMotionBuilder(
        value: _rotationTarget,
        motion: _rotationMotion,
        builder: (context, rotation, child) {
          return Transform.rotate(
            angle: rotation,
            child: AnimatedBuilder(
              animation: _morphController,
              builder: (context, child) => CustomPaint(
                painter: _InteractiveMorphPainter(
                  color: Theme.of(context).colorScheme.primary,
                  morph: _morph,
                  progress: _morphController.value,
                ),
                child: SizedBox.square(dimension: widget.size),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _InteractiveMorphPainter extends CustomPainter {
  const _InteractiveMorphPainter({
    required this.color,
    required this.morph,
    required this.progress,
  });

  final Color color;
  final Morph morph;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width)
      ..drawPath(
        morph.toPath(progress: progress),
        Paint()
          ..style = PaintingStyle.fill
          ..color = color,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(covariant _InteractiveMorphPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.morph != morph ||
        oldDelegate.progress != progress;
  }
}
