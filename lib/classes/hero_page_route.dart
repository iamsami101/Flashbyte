import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:heroine/heroine.dart';

class HeroDialogRoute extends HeroinePageRoute {
  final String heroTag;
  final Widget heroChild;
  final Color? fadeColor;
  final Alignment? alignment;
  final double? duration;
  final EdgeInsetsGeometry padding;

  HeroDialogRoute({
    this.duration = .3,
    this.padding = EdgeInsetsGeometry.zero,
    this.alignment,
    this.fadeColor,
    required this.heroTag,
    required this.heroChild,
  });

  @override
  bool get fullscreenDialog => false;

  @override
  Color? get barrierColor => Colors.black.withAlpha(50);

  @override
  bool get opaque => false;

  @override
  String? get barrierLabel => "Dialog Dismiss Area";

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return GestureDetector(
      onTap: () {
        if (FocusManager.instance.primaryFocus != null) {
          FocusManager.instance.primaryFocus!.unfocus();
          return;
        }
        Navigator.pop(context);
      },
      child: Align(
        alignment: alignment ?? Alignment.center,
        child: Padding(
          padding: EdgeInsetsGeometry.only(
            left: padding.horizontal / 2,
            right: padding.horizontal / 2,
            top: padding.vertical / 2,
            bottom:
                MediaQuery.viewInsetsOf(context).bottom <= padding.vertical / 2
                ? padding.vertical / 2
                : MediaQuery.of(context).viewInsets.bottom +
                      padding.horizontal / 2,
          ),
          child: DragDismissable(
            motion: CupertinoMotion.bouncy(),
            child: Heroine(
              motion: CupertinoMotion.bouncy(),
              tag: heroTag,
              flightShuttleBuilder: fadeColor == null
                  ? null
                  : FadeThroughShuttleBuilder(fadeColor: fadeColor!),
              child: heroChild,
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool get barrierDismissible => true;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => Duration(milliseconds: 300);

  @override
  ValueListenable<Offset> get dismissOffset => throw UnimplementedError();

  @override
  ValueListenable<double> get dismissProgress => throw UnimplementedError();

  @override
  void cancelDismiss() {}

  @override
  void updateDismiss(double progress, Offset offset) {}
}
