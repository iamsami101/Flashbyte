import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

/// A larger, slower Material 3 Expressive indicator.
class SlowM3ELoadingIndicator extends StatefulWidget {
  const SlowM3ELoadingIndicator({
    super.key,
    required this.size,
    required this.isActive,
    this.staticShape = false,
  });

  final double size;
  final bool isActive;
  final bool staticShape;

  @override
  State<SlowM3ELoadingIndicator> createState() =>
      _SlowM3ELoadingIndicatorState();
}

class _SlowM3ELoadingIndicatorState extends State<SlowM3ELoadingIndicator>
    with TickerProviderStateMixin {
  static final _polygons = <RoundedPolygon>[
    MaterialShapes.softBurst,
    MaterialShapes.cookie9Sided,
    MaterialShapes.pentagon,
    MaterialShapes.pill,
    MaterialShapes.sunny,
    MaterialShapes.cookie4Sided,
    MaterialShapes.oval,
  ];

  late final AnimationController _rotationController;
  late final AnimationController _morphController;
  late final List<Morph> _morphs;
  Timer? _morphTimer;
  int _morphIndex = 0;

  @override
  void initState() {
    super.initState();
    _morphs = [
      for (var index = 0; index < _polygons.length; index++)
        Morph(_polygons[index], _polygons[(index + 1) % _polygons.length]),
    ];
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    _morphController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _updatePlayback();
  }

  @override
  void didUpdateWidget(covariant SlowM3ELoadingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive ||
        oldWidget.staticShape != widget.staticShape) {
      _updatePlayback();
    }
  }

  void _updatePlayback() {
    _morphTimer?.cancel();
    if (!widget.isActive || widget.staticShape) {
      _rotationController.stop();
      _morphController.stop();
      return;
    }
    _rotationController.repeat();
    _morphTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _advanceMorph(),
    );
    _advanceMorph();
  }

  void _advanceMorph() {
    if (!mounted || !widget.isActive) return;
    setState(() => _morphIndex = (_morphIndex + 1) % _morphs.length);
    _morphController.forward(from: 0);
  }

  @override
  void dispose() {
    _morphTimer?.cancel();
    _rotationController.dispose();
    _morphController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.staticShape) {
      return CustomPaint(
        painter: _StaticM3EShapePainter(
          color: Theme.of(context).colorScheme.primary,
          shape: MaterialShapes.clover4Leaf,
        ),
        child: SizedBox.square(dimension: widget.size),
      );
    }

    return AnimatedBuilder(
      animation: Listenable.merge([_rotationController, _morphController]),
      builder: (context, child) => Transform.rotate(
        angle: _rotationController.value * math.pi * 2,
        child: CustomPaint(
          painter: _SlowM3EPainter(
            color: Theme.of(context).colorScheme.primary,
            morph: _morphs[_morphIndex],
            progress: Curves.easeInOutCubic.transform(_morphController.value),
          ),
          child: SizedBox.square(dimension: widget.size),
        ),
      ),
    );
  }
}

class _StaticM3EShapePainter extends CustomPainter {
  const _StaticM3EShapePainter({
    required this.color,
    required this.shape,
  });

  final Color color;
  final RoundedPolygon shape;

  @override
  void paint(Canvas canvas, Size size) {
    final path = shape.toPath().transform(
      Matrix4.diagonal3Values(size.width * 0.74, size.height * 0.74, 1).storage,
    );
    final centeredPath = path.shift(
      size.center(Offset.zero) - path.getBounds().center,
    );
    canvas.drawPath(
      centeredPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _StaticM3EShapePainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.shape != shape;
  }
}

class _SlowM3EPainter extends CustomPainter {
  const _SlowM3EPainter({
    required this.color,
    required this.morph,
    required this.progress,
  });

  final Color color;
  final Morph morph;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final normalizedPath = morph.toPath(progress: progress);
    final path = normalizedPath.transform(
      Matrix4.diagonal3Values(size.width * 0.74, size.height * 0.74, 1).storage,
    );
    final centeredPath = path.shift(
      size.center(Offset.zero) - path.getBounds().center,
    );
    canvas.drawPath(
      centeredPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _SlowM3EPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.morph != morph ||
        oldDelegate.progress != progress;
  }
}
