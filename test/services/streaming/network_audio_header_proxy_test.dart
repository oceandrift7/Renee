import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/streaming/network_audio_header_proxy.dart';

void main() {
  final upstream = Uri.parse(
    'https://rr1.googlevideo.com/videoplayback?expire=9999999999&sig=secret',
  );

  test('preserves mobile-client headers and byte ranges without downloading', () async {
    final seen = <http.Request>[];
    final mock = MockClient((request) async {
      seen.add(request);
      return http.Response(
        'audio',
        206,
        headers: {
          'content-type': 'audio/mp4',
          'content-length': '5',
          'content-range': 'bytes 0-4/12345',
          'accept-ranges': 'bytes',
        },
      );
    });
    final proxy = NetworkAudioHeaderProxy(client: mock);
    final httpClient = HttpClient();
    try {
      final local = await proxy.prepare(
        upstream,
        headers: {'User-Agent': 'YouTube-iOS-client/123'},
      );
      expect(local.scheme, 'http');
      expect(local.host, '127.0.0.1');
      expect(local.toString(), isNot(contains('sig=')));
      expect(local.toString(), isNot(contains('googlevideo.com')));

      final get = await httpClient.getUrl(local);
      get.headers.set(HttpHeaders.rangeHeader, 'bytes=0-4');
      final response = await get.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-4/12345',
      );
      expect(utf8.decode(await response.fold<List<int>>(
        <int>[],
        (previous, bytes) => previous..addAll(bytes),
      )), 'audio');
      expect(seen, hasLength(1));
      expect(seen.single.url, upstream);
      expect(seen.single.headers['user-agent'], 'YouTube-iOS-client/123');
      expect(seen.single.headers['range'], 'bytes=0-4');
    } finally {
      httpClient.close(force: true);
      await proxy.dispose();
      mock.close();
    }
  });

  test('revokes old source URLs and accepts a new token for the new song', () async {
    final client = MockClient(
      (_) async => http.Response('ok', 200, headers: {'content-type': 'audio/mp4'}),
    );
    final proxy = NetworkAudioHeaderProxy(client: client);
    final httpClient = HttpClient();
    try {
      final old = await proxy.prepare(upstream, headers: {'User-Agent': 'ios'});
      final fresh = await proxy.prepare(upstream, headers: {'User-Agent': 'ios'});
      expect(old.path, isNot(fresh.path));
      final former = await (await httpClient.getUrl(old)).close();
      expect(former.statusCode, HttpStatus.notFound);
      await former.drain();
      final current = await (await httpClient.getUrl(fresh)).close();
      expect(current.statusCode, HttpStatus.ok);
      await current.drain();
      proxy.revoke();
      final revoked = await (await httpClient.getUrl(fresh)).close();
      expect(revoked.statusCode, HttpStatus.notFound);
      await revoked.drain();
    } finally {
      httpClient.close(force: true);
      await proxy.dispose();
      client.close();
    }
  });

  test('blocks non-Googlevideo upstream URLs and unsupported headers', () async {
    final proxy = NetworkAudioHeaderProxy(client: MockClient((_) async {
      fail('network must not be requested');
    }));
    try {
      expect(
        NetworkAudioHeaderProxy.isTrustedUpstream(
          Uri.parse('https://rr1.googlevideo.com.example.org/file'),
        ),
        isFalse,
      );
      await expectLater(
        proxy.prepare(
          Uri.parse('https://localhost/internal'),
          headers: {'User-Agent': 'test'},
        ),
        throwsArgumentError,
      );
      await expectLater(
        proxy.prepare(
          upstream,
          headers: {'Host': 'malicious.example.org'},
        ),
        throwsArgumentError,
      );
    } finally {
      await proxy.dispose();
    }
  });
}
