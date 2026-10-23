import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Bridges client-bound media HTTP headers to iOS AVPlayer through a
/// loopback-only, byte-range streaming relay. Inspired by the client identity
/// handling in BitChord and Lokal-Konnekt; independently written for Renée.
///
/// AVPlayer cannot receive custom request headers via audioplayers_darwin.
/// No media is buffered to disk, and signed Googlevideo URLs or credentials
/// are never returned in the local URL or printed in diagnostics.
///
/// This only handles direct, independently authorized HTTPS Googlevideo audio
/// resources. It is not a YouTube login, signature, or PO-token implementation.
class NetworkAudioHeaderProxy {
  NetworkAudioHeaderProxy({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  static final shared = NetworkAudioHeaderProxy();

  final http.Client _client;
  final bool _ownsClient;
  HttpServer? _server;
  Future<HttpServer>? _starting;
  _ProxyTrack? _track;
  bool _closed = false;

  /// Reject arbitrary URLs to keep a locally exposed endpoint from becoming
  /// an open proxy into a device's LAN or to untrusted Internet services.
  static bool isTrustedUpstream(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.host.toLowerCase().endsWith('.googlevideo.com') &&
      uri.host.length > '.googlevideo.com'.length;

  Future<HttpServer> _listen() async {
    final existing = _server;
    if (existing != null) return existing;
    final inProgress = _starting;
    if (inProgress != null) return inProgress;

    final future = HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _starting = future;
    try {
      final server = await future;
      if (_closed) {
        await server.close(force: true);
        throw StateError('Network audio proxy was closed');
      }
      _server = server;
      server.listen((request) => unawaited(_relay(request)));
      return server;
    } finally {
      _starting = null;
    }
  }

  /// Replaces the active source. Old local URLs become invalid immediately.
  /// The random path is not a signed Googlevideo URL or an account credential.
  Future<Uri> prepare(
    Uri upstream, {
    required Map<String, String> headers,
  }) async {
    if (_closed) throw StateError('Network audio proxy was closed');
    if (!isTrustedUpstream(upstream) || headers.isEmpty) {
      throw ArgumentError('Requires a trusted HTTPS audio URL and headers');
    }
    if (headers.keys.any(
      (key) => !const {
        'user-agent',
        'referer',
        'origin',
        'cookie',
        'authorization',
        'x-goog-visitor-id',
      }.contains(key.toLowerCase()),
    )) {
      throw ArgumentError('Unsupported upstream request header');
    }
    final server = await _listen();
    final random = Random.secure();
    final token = base64UrlEncode(
      List<int>.generate(24, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    _track = _ProxyTrack(token, upstream, Map.of(headers));
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      path: '/$token/stream.m4a',
    );
  }

  void revoke() {
    _track = null;
  }

  Future<void> _relay(HttpRequest local) async {
    final track = _track;
    if (track == null ||
        local.uri.path != '/${track.token}/stream.m4a' ||
        (local.method != 'GET' && local.method != 'HEAD')) {
      local.response.statusCode = HttpStatus.notFound;
      await local.response.close();
      return;
    }
    try {
      final request = http.Request(local.method, track.uri)
        ..followRedirects = false
        ..headers.addAll(track.headers)
        ..headers['Accept-Encoding'] = 'identity';
      final range = local.headers.value(HttpHeaders.rangeHeader);
      if (range != null) request.headers[HttpHeaders.rangeHeader] = range;
      final ifRange = local.headers.value(HttpHeaders.ifRangeHeader);
      if (ifRange != null) request.headers[HttpHeaders.ifRangeHeader] = ifRange;

      final result = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (_track?.token != track.token ||
          (result.statusCode != HttpStatus.ok &&
              result.statusCode != HttpStatus.partialContent)) {
        local.response.statusCode = HttpStatus.badGateway;
        await local.response.close();
        return;
      }
      local.response.statusCode = result.statusCode;
      for (final name in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final value = result.headers[name];
        if (value != null) local.response.headers.set(name, value);
      }
      if (local.method == 'HEAD') {
        await local.response.close();
        return;
      }
      await result.stream.pipe(local.response);
    } catch (_) {
      // Never log signed URLs, cookies, or upstream exception text.
      try {
        local.response.statusCode = HttpStatus.badGateway;
        await local.response.close();
      } catch (_) {
        // The player may disconnect while a range request is in flight.
      }
    }
  }

  Future<void> dispose() async {
    _closed = true;
    revoke();
    await _server?.close(force: true);
    _server = null;
    if (_ownsClient) _client.close();
  }
}

class _ProxyTrack {
  const _ProxyTrack(this.token, this.uri, this.headers);
  final String token;
  final Uri uri;
  final Map<String, String> headers;
}
