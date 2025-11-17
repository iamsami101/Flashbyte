import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:heroine/heroine.dart';

class HeroDialogRoute extends PageRoute<void> {
  String heroTag;
  Widget heroChild;
  List<Widget>? actions;
  final EdgeInsetsGeometry padding;

  HeroDialogRoute({
    this.padding = EdgeInsetsGeometry.zero,
    this.actions,
    super.settings,
    required this.heroTag,
    required this.heroChild,
  });

  @override
  Color? get barrierColor => Colors.black.withAlpha(50);

  @override
  bool get opaque => false;

  @override
  String? get barrierLabel => "Dialog Dismiss Barrier";

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Spacer(),
        SizedBox(
          width: MediaQuery.sizeOf(context).width * 0.7,
          child: DragDismissable(
            spring: Spring.bouncy,
            child: Hero(
              tag: heroTag,
              flightShuttleBuilder: FadeThroughShuttleBuilder(
                  fadeColor: Theme.of(context).colorScheme.surface),
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: heroChild,
              ),
            ),
          ),
        ),
        const Spacer(),
        if (actions != null) ...actions!,
      ],
    );
  }

  @override
  bool get barrierDismissible => true;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => 500.ms;
}
