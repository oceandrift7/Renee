import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/streaming/youtube_music_direct_resolver.dart';
import 'package:mornye/services/streaming/youtube_music_signed_session.dart';

void main() {
  const session = YouTubeMusicSignedSession(
    cookies: {
      'SAPISID': 'example-sapisid',
      'LOGIN_INFO': 'fake-login',
    },
    clientVersion: '1.20260708.00.00',
    visitorData: 'CgtExampleVisitor123',
    authUser: '1',
    delegatedSessionId: 'UC123',
  );

  test('signs the exact YouTube Music origin with a deterministic timestamp', () {
    final headers = session.headers(
      now: DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    )!;
    expect(headers['Authorization'],
        'SAPISIDHASH 1700000000_6cf2c8de22a38e602732010a5c8a4e066e7dbedb');
    expect(headers['Origin'], YouTubeMusicSignedSession.origin);
    expect(headers['X-Goog-AuthUser'], '1');
    expect(headers['X-Goog-PageId'], 'UC123');
    expect(headers['X-Goog-Visitor-Id'], 'CgtExampleVisitor123');
    expect(headers['Cookie'], contains('SAPISID=example-sapisid'));
    expect(headers.toString(), isNot(contains('https://rr1.googlevideo.com')));
  });

  test('rejects missing signing cookie and header injection', () {
    expect(
      const YouTubeMusicSignedSession(
        cookies: {'LOGIN_INFO': 'fake-login'},
        clientVersion: '1.20260708.00.00',
      ).headers(),
      isNull,
    );
    expect(
      const YouTubeMusicSignedSession(
        cookies: {'SAPISID': 'secret\r\nAuthorization: bad'},
        clientVersion: '1.20260708.00.00',
      ).headers(),
      isNull,
    );
    expect(
      const YouTubeMusicSignedSession(
        cookies: {'SAPISID': 'secret'},
        clientVersion: '1.20260708.00.00',
        authUser: '-1',
      ).headers(),
      isNull,
    );
  });

  test('private persisted format round trips only after validation', () {
    final serialized = jsonDecode(jsonEncode(session.toPrivateJson()));
    final restored = YouTubeMusicSignedSession.fromPrivateJson(serialized)!;
    expect(restored.headers()?['Cookie'], contains('SAPISID='));
    expect(
      YouTubeMusicSignedSession.fromPrivateJson({
        'version': 1,
        'cookies': {'LOGIN_INFO': 'x'},
        'clientVersion': '1.20260708.00.00',
      }),
      isNull,
    );
  });

  test('signed in WEB_REMIX is scoped to music.youtube.com only', () async {
    var signedCalls = 0;
    var unauthenticatedCalls = 0;
    var mediaCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        if (request.url.host.endsWith('.googlevideo.com')) {
          mediaCalls++;
          expect(request.headers['cookie'], isNull);
          expect(request.headers['authorization'], isNull);
          expect(request.headers['user-agent'], contains('Chrome/142'));
          expect(request.headers['referer'], 'https://music.youtube.com/');
          expect(request.headers['range'], 'bytes=0-16383');
          return http.Response('media', 206,
              headers: {'content-type': 'audio/mp4'});
        }
        fail('Signed WEB_REMIX success must not fetch a guest visitor ID.');
      }
      if (request.url.host == 'music.youtube.com') {
        signedCalls++;
        expect(request.headers['cookie'], contains('example-sapisid'));
        expect(request.headers['authorization'], startsWith('SAPISIDHASH '));
        expect(request.headers['x-goog-authuser'], '1');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final context = body['context'] as Map<String, dynamic>;
        expect((context['user'] as Map)['onBehalfOfUser'], 'UC123');
        return http.Response(jsonEncode({
          'playabilityStatus': {'status': 'OK'},
          'streamingData': {
            'adaptiveFormats': [{
              'itag': 140,
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
              'bitrate': 128000,
              'url': 'https://rr1.googlevideo.com/videoplayback?expire=9999999999',
            }],
          },
        }), 200);
      }
      unauthenticatedCalls++;
      fail('No guest clients after signed player returned verified audio.');
    });
    final resolver = YouTubeMusicDirectResolver(
      client: client,
      signedInSession: session,
    );
    try {
      final result = await resolver.resolve('Z85lxckrtzg');
      expect(result?.uri.host, 'rr1.googlevideo.com');
      expect(result?.headers['User-Agent'], contains('Chrome/142'));
      expect(result?.headers.keys, isNot(contains('Cookie')));
      expect(signedCalls, 1);
      expect(mediaCalls, 1);
      expect(unauthenticatedCalls, 0);
    } finally {
      resolver.close();
      client.close();
    }
  });

  test('signed-in refusal does not forward cookies into guest fallbacks', () async {
    var signedCalls = 0;
    var guestCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return request.url.host.endsWith('.googlevideo.com')
          ? http.Response('audio', 206, headers: {'content-type': 'audio/mp4'})
          : http.Response('', 503);
      }
      if (request.url.host == 'music.youtube.com') {
        signedCalls++;
        return http.Response(jsonEncode({
          'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
        }), 200);
      }
      guestCalls++;
      expect(request.headers['authorization'], isNull);
      expect(request.headers['cookie'], isNull);
      return http.Response(jsonEncode({
        'playabilityStatus': {'status': 'OK'},
        'streamingData': {
          'adaptiveFormats': [{
            'itag': 140,
            'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
            'bitrate': 128000,
            'url': 'https://rr1.googlevideo.com/videoplayback?expire=9999999999',
          }],
        },
      }), 200);
    });
    final resolver = YouTubeMusicDirectResolver(
      client: client,
      signedInSession: session,
    );
    try {
      expect(await resolver.resolve('Z85lxckrtzg'), isNotNull);
      expect(signedCalls, 1);
      expect(guestCalls, 1);
    } finally {
      resolver.close();
      client.close();
    }
  });
}
