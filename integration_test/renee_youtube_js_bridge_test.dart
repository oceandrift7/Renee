import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Verifies that the physical iOS JavaScriptCore Flutter bridge is registered,
/// performs evaluation off the UI thread, and returns a JSON result.
/// No YouTube traffic or user account is required for this test.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native JavaScriptCore evaluates a cipher-style challenge', (
    tester,
  ) async {
    const channel = MethodChannel('com.zarz.mornye/youtube_js');
    final initialized = await channel.invokeMethod<bool>('initialize', {
      'script': 'globalThis.jsc = (input) => ({type: "result", responses: input.requests});',
    });
    expect(initialized, isTrue);
    final raw = await channel.invokeMethod<String>('evaluate', {
      'script': 'JSON.stringify(jsc({requests: [1, 2, 3]}))',
    });
    expect(raw, isNotNull);
    final decoded = jsonDecode(raw!) as Map<String, dynamic>;
    expect(decoded['responses'], [1, 2, 3]);
  });
}
