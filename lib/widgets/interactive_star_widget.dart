import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

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

  late final AnimationController _idleController;
  late final AnimationController _morphController;
  late Morph _morph;
  Timer? _resumeTimer;
  double _gestureRotation = 0;
  double _idleRotation = 0;
  int _currentShape = 0;
  int _lastIdleSegment = -1;

  @override
  void initState() {
    super.initState();
    _morph = Morph(_shapes.first, _shapes.first);
    _idleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 9),
    )..addListener(_advanceIdle);
    _morphController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    if (widget.isActive) {
      _idleController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant InteractiveStarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive == oldWidget.isActive) return;
    if (widget.isActive) {
      _idleController.repeat();
    } else {
      _idleController.stop();
    }
  }

  void _advanceIdle() {
    final phase = _idleController.value;
    _idleRotation = _idleTurns(phase) * math.pi * 2;
    final segment = (phase * 4).floor();
    if (segment != _lastIdleSegment) {
      _lastIdleSegment = segment;
      if (segment == 1 || segment == 3) {
        _goToShape((_currentShape + 1) % _shapes.length);
      }
    }
    if (mounted) setState(() {});
  }

  double _idleTurns(double phase) {
    if (phase < 0.25) return phase * 2.4;
    if (phase < 0.5) {
      final t = Curves.easeIn.transform((phase - 0.25) * 4);
      return 0.6 + (t * 1.05);
    }
    if (phase < 0.75) {
      final t = Curves.easeOut.transform((phase - 0.5) * 4);
      return 1.65 + (t * 0.75);
    }
    return 2.4 + ((phase - 0.75) * 2.4);
  }

  void _goToShape(int next) {
    _morph = Morph(_shapes[_currentShape], _shapes[next]);
    _currentShape = next;
    _morphController.forward(from: 0);
  }

  void _pauseIdle() {
    _resumeTimer?.cancel();
    _idleController.stop();
  }

  void _resumeIdle() {
    _resumeTimer?.cancel();
    if (!widget.isActive) return;
    _resumeTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted && widget.isActive) _idleController.repeat();
    });
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _idleController.dispose();
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
          _gestureRotation += details.delta.dx / 75;
          _gestureRotation += details.delta.dy / -75;
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
      child: AnimatedBuilder(
        animation: _morphController,
        builder: (context, child) {
          return Transform.rotate(
            angle: _idleRotation + _gestureRotation,
            child: CustomPaint(
              painter: _InteractiveMorphPainter(
                color: Theme.of(context).colorScheme.primary,
                morph: _morph,
                progress: _morphController.value,
              ),
              child: SizedBox.square(dimension: widget.size),
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
