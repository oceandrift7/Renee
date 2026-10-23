import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Opt-in, browser-authenticated YouTube Music session credentials.
///
/// Session cookies are bearer credentials. They must never be printed,
/// persisted in SharedPreferences, included in crash reports or put on an
/// arbitrary host. Capture is deliberately NOT implemented here: Google's
/// OAuth flow does not permit arbitrary embedded WKWebViews.
class YouTubeMusicSignedSession {
  const YouTubeMusicSignedSession({
    required this.cookies,
    required this.clientVersion,
    this.apiKey,
    this.visitorData,
    this.authUser = '0',
    this.delegatedSessionId,
  });

  final Map<String, String> cookies;
  final String clientVersion;
  /// Public client API key copied from YouTube Music's own ytcfg.
  final String? apiKey;
  final String? visitorData;
  final String authUser;
  final String? delegatedSessionId;

  static const origin = 'https://music.youtube.com';
  static const cookieNames = [
    '__Secure-3PAPISID',
    '__Secure-1PAPISID',
    'SAPISID',
  ];

  String? get _sapisid {
    for (final name in cookieNames) {
      final value = cookies[name];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// Merely having cookies does not prove Google has accepted the login.
  bool get hasSigningCookie => _sapisid != null;

  /// Build request-specific, origin-bound auth headers.
  /// No signed audio URL, cookie or hash is ever logged.
  Map<String, String>? headers({DateTime? now}) {
    final sid = _sapisid;
    if (sid == null ||
        !RegExp(r'^[0-9A-Za-z._%-]{1,2048}$').hasMatch(sid) ||
        !RegExp(r'^\d{1,3}$').hasMatch(authUser) ||
        !RegExp(r'^[0-9A-Za-z._-]{1,96}$').hasMatch(clientVersion) ||
        (apiKey != null &&
            !RegExp(r'^AIza[0-9A-Za-z_-]{20,100}$').hasMatch(apiKey!))) {
      return null;
    }
    final entries = <String>[];
    for (final entry in cookies.entries) {
      if (!RegExp(r'^[-A-Za-z0-9_]{1,128}$').hasMatch(entry.key) ||
          !RegExp(r'^[\x21-\x3A\x3C-\x7E]{1,4096}$')
              .hasMatch(entry.value)) {
        return null;
      }
      entries.add('${entry.key}=${entry.value}');
    }

    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final payload = '$timestamp $sid $origin';
    final hash = sha1.convert(utf8.encode(payload)).toString();

    return {
      'Content-Type': 'application/json',
      'User-Agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/142.0.0.0 Safari/537.36',
      'Origin': origin,
      'Referer': '$origin/',
      'X-Origin': origin,
      'X-YouTube-Client-Name': '67',
      'X-YouTube-Client-Version': clientVersion,
      'X-Goog-AuthUser': authUser,
      'Cookie': entries.join('; '),
      'Authorization': 'SAPISIDHASH ${timestamp}_$hash',
      if (visitorData != null && visitorData!.isNotEmpty)
        'X-Goog-Visitor-Id': visitorData!,
      if (delegatedSessionId != null && delegatedSessionId!.isNotEmpty)
        'X-Goog-PageId': delegatedSessionId!,
    };
  }

  Map<String, dynamic> toPrivateJson() => {
    'version': 1,
    'cookies': cookies,
    'clientVersion': clientVersion,
    'apiKey': apiKey,
    'visitorData': visitorData,
    'authUser': authUser,
    'delegatedSessionId': delegatedSessionId,
  };

  static YouTubeMusicSignedSession? fromPrivateJson(Object? raw) {
    if (raw is! Map || raw['version'] != 1 ||
        raw['cookies'] is! Map || raw['clientVersion'] is! String) {
      return null;
    }
    final map = raw['cookies'] as Map;
    if (map.keys.any((key) => key is! String) ||
        map.values.any((value) => value is! String)) {
      return null;
    }
    final session = YouTubeMusicSignedSession(
      cookies: Map<String, String>.from(map),
      clientVersion: raw['clientVersion'] as String,
      apiKey: raw['apiKey'] as String?,
      visitorData: raw['visitorData'] as String?,
      authUser: raw['authUser'] as String? ?? '0',
      delegatedSessionId: raw['delegatedSessionId'] as String?,
    );
    return session.headers() == null ? null : session;
  }
}

/// Isolated secure storage for a future explicitly authorized account flow.
/// No credentials are imported or collected until the user opts in.
class YouTubeMusicSessionStore {
  const YouTubeMusicSessionStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const _key = 'renee.ytmusic.account-session.v1';
  final FlutterSecureStorage _storage;

  Future<YouTubeMusicSignedSession?> read() async {
    try {
      final data = await _storage.read(key: _key);
      return data == null
          ? null
          : YouTubeMusicSignedSession.fromPrivateJson(jsonDecode(data));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(YouTubeMusicSignedSession session) async {
    if (session.headers() == null) {
      throw ArgumentError('Invalid session credentials');
    }
    await _storage.write(key: _key, value: jsonEncode(session.toPrivateJson()));
  }

  Future<void> clear() => _storage.delete(key: _key);
}
