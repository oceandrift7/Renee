import 'package:flutter/services.dart';
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/base_ejs_solver.dart';
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/ejs.dart';

/// Bridges the upstream EJS cipher solver to iOS JavaScriptCore instead of
/// spawning Deno (which cannot run as a subprocess inside an iOS app).
///
/// Upstream EJS modules are hash-verified by youtube_explode_dart before being
/// evaluated. Execution occurs off the iOS main thread. This is unofficial
/// public-media extraction only; no logins, cookies, or DRM workarounds.
class ReneeIosEjsSolver extends BaseEJSSolver {
  ReneeIosEjsSolver._();

  static const _channel = MethodChannel('com.zarz.mornye/youtube_js');
  static Future<ReneeIosEjsSolver>? _initialized;

  /// Coalesce startup across requests and reuse the native JS context.
  static Future<ReneeIosEjsSolver> initialize() =>
      _initialized ??= _initializeOnce();

  static Future<ReneeIosEjsSolver> _initializeOnce() async {
    try {
      final modules = await EJSBuilder.getJSModules();
      final ready = await _channel.invokeMethod<bool>(
        'initialize',
        {'script': modules},
      );
      if (ready != true) throw StateError('iOS cipher engine unavailable');
      return ReneeIosEjsSolver._();
    } catch (_) {
      // A future attempt should be allowed after a temporary network error.
      _initialized = null;
      rethrow;
    }
  }

  @override
  Future<String> executeJavaScript(String jsCode) async {
    final result = await _channel.invokeMethod<String>(
      'evaluate',
      {'script': jsCode},
    );
    if (result == null || result.isEmpty) {
      throw StateError('iOS cipher evaluator returned no result');
    }
    return result;
  }
}
