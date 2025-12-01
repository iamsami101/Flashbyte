import 'package:flashbyte/classes/hero_page_route.dart';
import 'package:flutter/material.dart';

void showHeroDialog({
  required BuildContext context,
  required Widget child,
  required String tag,
  List<Widget>? actions,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
}) {
  Navigator.push(
    context,
    HeroDialogRoute(
      padding: padding,
      heroTag: tag,
      heroChild: child,
    ),
  );
}
