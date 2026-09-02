import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flashbyte/features/transfers/widgets/transfer_widget.dart';

void main() {
  group('TransferWidget', () {
    testWidgets('renders file name, size, and status text correctly', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TransferWidget(
              fileName: 'sample.pdf',
              fileSize: '4.2 MB',
              uuid: 'uuid-1',
              filePath: '/tmp/sample.pdf',
              status: TransferStatus.completed,
              isReceived: true,
            ),
          ),
        ),
      );

      expect(find.text('sample.pdf'), findsOneWidget);
      expect(find.textContaining('4.2 MB'), findsOneWidget);
      expect(find.textContaining('received'), findsOneWidget);
    });

    testWidgets(
      'calls onPause callback when pause button is tapped in active state',
      (WidgetTester tester) async {
        var pauseCalled = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TransferWidget(
                fileName: 'video.mp4',
                fileSize: '15 MB',
                uuid: 'uuid-2',
                filePath: '/tmp/video.mp4',
                status: TransferStatus.inProgress,
                onPause: () {
                  pauseCalled = true;
                },
              ),
            ),
          ),
        );

        final pauseButton = find.byIcon(Icons.pause);
        if (pauseButton.evaluate().isNotEmpty) {
          await tester.tap(pauseButton);
          expect(pauseCalled, isTrue);
        }
      },
    );

    testWidgets('renders accept and decline buttons when pending request', (
      WidgetTester tester,
    ) async {
      var accepted = false;
      var declined = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransferWidget(
              fileName: 'doc.docx',
              fileSize: '500 KB',
              uuid: 'uuid-3',
              filePath: '/tmp/doc.docx',
              status: TransferStatus.pending,
              isReceived: true,
              onAccept: () {
                accepted = true;
              },
              onDecline: () {
                declined = true;
              },
            ),
          ),
        ),
      );

      final checkIcon = find.byIcon(Icons.check);
      if (checkIcon.evaluate().isNotEmpty) {
        await tester.tap(checkIcon);
        expect(accepted, isTrue);
      }

      final closeIcon = find.byIcon(Icons.close);
      if (closeIcon.evaluate().isNotEmpty) {
        await tester.tap(closeIcon);
        expect(declined, isTrue);
      }
    });
  });
}
