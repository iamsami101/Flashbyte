import 'dart:async';
import 'dart:io';

/// Flashbyte Test Harness & Continuous Verification CLI Tool
/// Usage:
///   dart run tool/harness.dart [command] [options]
///   ./tool/harness.sh [command] [options]
///
/// Commands:
///   check         Run full suite (analyze, format, unit tests, protocol tests)
///   analyze       Run flutter analyze
///   format        Check code formatting
///   unit          Run unit and widget tests
///   integration   Run integration tests
///   android       Check Android device connection & run integration test on device
///   transfer      Self-transfer test: send file over TCP loopback (or Android via ADB)
///   devtools      Print DevTools connection & verification info
///   loop          Loop execution until all checks and tests pass 100%
///   fix           Auto-format and apply fixes
void main(List<String> args) async {
  final command = args.isNotEmpty ? args.first : 'check';
  final isLoopMode = args.contains('--loop') || command == 'loop';
  final maxRetries = _getOptionValue(args, '--max-retries', 5);

  print('====================================================');
  print('⚡ FLASHBYTE HARNESS & CONTINUOUS VERIFICATION CLI');
  print('====================================================');
  print('Command: $command');
  if (isLoopMode) {
    print('Mode: Continuous Verification Loop (Max retries: $maxRetries)');
  }
  print('');

  int attempt = 1;
  bool success = false;

  while (attempt <= (isLoopMode ? maxRetries : 1)) {
    if (isLoopMode) {
      print(
        '\n🔄 [Loop Attempt $attempt/$maxRetries] Running verification suite...\n',
      );
    }

    switch (command) {
      case 'analyze':
        success = await _runAnalyze();
        break;
      case 'format':
        success = await _runFormatCheck();
        break;
      case 'unit':
        success = await _runUnitTests();
        break;
      case 'integration':
        success = await _runIntegrationTests();
        break;
      case 'transfer':
        success = await _runTransferTest(args);
        break;
      case 'android':
        success = await _runAndroidChecks();
        break;
      case 'devtools':
        success = await _printDevToolsInfo();
        break;
      case 'fix':
        success = await _runFixes();
        break;
      case 'check':
      case 'loop':
      default:
        success = await _runFullSuite();
        break;
    }

    if (success) {
      print('\n✅ [HARNESS SUCCESS] All requirements & tests passed cleanly!');
      exitCode = 0;
      return;
    } else {
      print('\n❌ [HARNESS FAILURE] Test / Verification checks failed.');
      if (isLoopMode && attempt < maxRetries) {
        print('Waiting 2 seconds before next verification loop...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    attempt++;
  }

  exitCode = 1;
}

int _getOptionValue(List<String> args, String optionName, int defaultValue) {
  final idx = args.indexOf(optionName);
  if (idx != -1 && idx + 1 < args.length) {
    return int.tryParse(args[idx + 1]) ?? defaultValue;
  }
  return defaultValue;
}

Future<bool> _runProcess(
  String executable,
  List<String> arguments, {
  String? stepName,
}) async {
  if (stepName != null) {
    print('▶ Running Step: $stepName ($executable ${arguments.join(' ')})');
  }
  final result = await Process.run(executable, arguments);

  if (result.stdout.toString().isNotEmpty) {
    stdout.write(result.stdout);
  }
  if (result.stderr.toString().isNotEmpty) {
    stderr.write(result.stderr);
  }

  if (result.exitCode == 0) {
    print('✔ $stepName: PASSED');
    return true;
  } else {
    print('✖ $stepName: FAILED (Exit Code: ${result.exitCode})');
    return false;
  }
}

Future<bool> _runAnalyze() async {
  return _runProcess('flutter', ['analyze'], stepName: 'Flutter Analyze');
}

Future<bool> _runFormatCheck() async {
  return _runProcess(
    'dart',
    ['format', '--output=none', '--set-exit-if-changed', '.'],
    stepName: 'Dart Format Check',
  );
}

Future<bool> _runUnitTests() async {
  return _runProcess('flutter', ['test'], stepName: 'Unit & Widget Tests');
}

Future<bool> _runIntegrationTests() async {
  return _runProcess(
    'flutter',
    ['test', 'integration_test/app_test.dart'],
    stepName: 'Integration Tests',
  );
}

Future<bool> _runFixes() async {
  print('▶ Applying automated formatting and fixes...');
  await _runProcess('dart', ['format', '.'], stepName: 'Dart Format');
  await _runProcess('dart', ['fix', '--apply'], stepName: 'Dart Fix');
  return true;
}

Future<bool> _runAndroidChecks() async {
  print('▶ Checking Android devices via ADB...');
  final result = await Process.run('adb', ['devices']);
  print(result.stdout);

  final output = result.stdout.toString();
  final lines = output
      .split('\n')
      .where((l) => l.trim().isNotEmpty && !l.startsWith('List of devices'))
      .toList();

  if (lines.isEmpty) {
    print('ℹ No connected Android devices/emulators detected via ADB.');
    print('  You can launch an emulator or connect a device and run:');
    print('  ./tool/harness.sh android');
    return true; // Non-fatal if no physical device connected in CI/CLI context
  }

  final deviceId = lines.first.split(RegExp(r'\s+')).first;
  print('📱 Target Android Device Found: $deviceId');

  print('▶ Running integration tests on Android device ($deviceId)...');
  return _runProcess(
    'flutter',
    ['test', 'integration_test/app_test.dart', '-d', deviceId],
    stepName: 'Android Device Integration Test',
  );
}

Future<bool> _printDevToolsInfo() async {
  print('🔧 FLUTTER DEVTOOLS & PERFORMANCE VERIFICATION');
  print('----------------------------------------------------');
  print(
    'To inspect memory, CPU, networking, and UI rendering on desktop/Android:',
  );
  print('  1. Run the app with VM service enabled:');
  print('     flutter run -d chrome/linux/android --debug');
  print('  2. Launch Flutter DevTools:');
  print('     dart devtools');
  print(
    '  3. Open DevTools in browser to observe frame rendering, isolate I/O & TCP transfers.',
  );
  print('----------------------------------------------------');
  return true;
}

Future<bool> _runTransferTest(List<String> args) async {
  final passthroughArgs = <String>[];
  if (args.contains('--adb')) passthroughArgs.add('--adb');
  if (args.contains('--host')) {
    final idx = args.indexOf('--host');
    passthroughArgs.add('--host');
    if (idx + 1 < args.length) passthroughArgs.add(args[idx + 1]);
  }
  return _runProcess(
    'dart',
    ['run', 'tool/transfer_integration_test.dart', ...passthroughArgs],
    stepName: 'Transfer Integration Test',
  );
}

Future<bool> _runFullSuite() async {
  print('📋 Running Full Verification Suite...\n');

  final formatOk = await _runFormatCheck();
  if (!formatOk) {
    print('⚠️ Formatting issues detected. Auto-formatting...');
    await _runFixes();
  }

  final analyzeOk = await _runAnalyze();
  if (!analyzeOk) return false;

  final unitOk = await _runUnitTests();
  if (!unitOk) return false;

  final integrationOk = await _runIntegrationTests();
  if (!integrationOk) return false;

  final transferOk = await _runTransferTest([]);
  if (!transferOk) return false;

  return true;
}
