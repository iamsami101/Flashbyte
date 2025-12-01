import 'package:flashbyte/tcp_socket_pages/main_page.dart';
import 'package:flashbyte/tcp_socket_pages/tcp_chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:heroine/heroine.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:motor/motor.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.green,
      ),
      home: StartPage(),
      navigatorObservers: [HeroineController()],
    );
  }
}

class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Transform.translate(
                offset: Offset(50, 0),
                child: RepaintBoundary(child: StarWidget()),
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
                        Text(
                          "Flash\nByte",
                          style: TextStyle(
                            fontSize: 50,
                            color: Theme.of(context).colorScheme.primaryFixed,
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
                        SizedBox(
                          height: 200,
                        ),
                      ],
                    ),
                    Spacer(),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ButtonStyle(
                          padding: WidgetStatePropertyAll(
                            EdgeInsets.symmetric(vertical: 30),
                          ),
                        ),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => TcpSockets(),
                            ),
                          );
                        },
                        child: Text("Start"),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StarWidget extends StatefulWidget {
  const StarWidget({super.key});

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

        if ((v >= 3500) || (h >= 3500)) {
          final newIndex = (current + 1) % shapeList.length;
          HapticFeedback.vibrate();
          goToShape(newIndex);
        }
        if ((v <= -3500) || (h <= -3500)) {
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
              child: const SizedBox(
                width: 200,
                height: 200,
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
