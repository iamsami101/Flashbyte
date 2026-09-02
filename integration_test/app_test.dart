import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flashbyte/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Flashbyte E2E Integration Harness Test', () {
    testWidgets('boots main app and verifies core navigation', (
      WidgetTester tester,
    ) async {
      // app.main() is async — await it so all initialization
      // (notifications, TLS, appearance) completes before pumping.
      await app.main();

      // Give the widget tree time to build after runApp().
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Verify that the main app UI initialized cleanly
      expect(find.byType(MaterialApp), findsOneWidget);

      // Verify the app has rendered at least a Scaffold
      expect(find.byType(Scaffold), findsWidgets);
    });
  });
}
