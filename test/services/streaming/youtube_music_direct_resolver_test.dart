import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mornye/services/streaming/youtube_music_direct_resolver.dart';
import 'package:mornye/services/streaming/streaming_playback_issue.dart';

void main() {
  final aac = {
    'itag': 140,
    'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
    'bitrate': 128000,
    'url': 'https://rr1.googlevideo.com/videoplayback?expire=9999999999',
  };
  final opus = {
    'itag': 251,
    'mimeType': 'audio/webm; codecs="opus"',
    'bitrate': 160000,
    'url': 'https://rr1.googlevideo.com/videoplayback',
  };
  Map<String, dynamic> payload(List<Map<String, dynamic>> formats) => {
    'playabilityStatus': {'status': 'OK'},
    'streamingData': {'adaptiveFormats': formats},
  };

  test('chooses iOS-compatible progressive AAC rather than WebM/Opus', () {
    final result = YouTubeMusicDirectResolver.resourceFromPlayerResponse(
      payload([opus, aac]),
    );
    expect(result?.uri.host, 'rr1.googlevideo.com');
    expect(result?.headers, isEmpty);
  });

  test('rejects expired audio URLs and accepts fresh alternatives', () {
    final result = YouTubeMusicDirectResolver.resourceFromPlayerResponse(
      payload([
        {
          ...aac,
          'url': 'https://rr1.googlevideo.com/videoplayback?expire=1000',
        },
        {
          ...aac,
          'itag': 140,
          'url': 'https://rr2.googlevideo.com/videoplayback?expire=9999999999',
        },
      ]),
    );
    expect(result?.uri.host, 'rr2.googlevideo.com');
    expect(
      YouTubeMusicDirectResolver.resourceFromPlayerResponse(
        payload([
          {
            ...aac,
            'url': 'https://rr1.googlevideo.com/videoplayback?expire=1000',
          },
        ]),
      ),
      isNull,
    );
  });

  test('allows a 96 kbps AAC preparation fallback but never 48 kbps', () {
    final acceptableFallback = {
      ...aac,
      'bitrate': 96000,
      'url': 'https://rr2.googlevideo.com/videoplayback?expire=9999999999',
    };
    final rejectedFallback = {
      ...aac,
      'itag': 139,
      'bitrate': 48000,
      'url': 'https://rr3.googlevideo.com/videoplayback?expire=9999999999',
    };
    final result = YouTubeMusicDirectResolver.resourceFromPlayerResponse(
      payload([opus, rejectedFallback, acceptableFallback, aac]),
    );
    expect(result?.uri.host, 'rr1.googlevideo.com');
    expect(result?.fallbackUris.length, 1);
    expect(result?.fallbackUris.single.host, 'rr2.googlevideo.com');

    final noPoorQualityFallback =
        YouTubeMusicDirectResolver.resourceFromPlayerResponse(
          payload([rejectedFallback, aac]),
        );
    expect(noPoorQualityFallback?.uri.host, 'rr1.googlevideo.com');
    expect(noPoorQualityFallback?.fallbackUris, isEmpty);

    expect(
      YouTubeMusicDirectResolver.resourceFromPlayerResponse(
        payload([rejectedFallback]),
      ),
      isNull,
    );
  });

  test('prefers 128 kbps AAC over 96 kbps and 160 kbps alternatives', () {
    final result = YouTubeMusicDirectResolver.resourceFromPlayerResponse(
      payload([
        {...aac, 'bitrate': 96000},
        {...aac, 'bitrate': 160000, 'itag': 141},
        aac,
      ]),
    );
    expect(result?.uri.toString(), aac['url']);
  });

  test('declines gated and unavailable videos', () {
    expect(
      YouTubeMusicDirectResolver.resourceFromPlayerResponse({
        'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
        'streamingData': {
          'adaptiveFormats': [aac],
        },
      }),
      isNull,
    );
  });

  test('declines unsupported or ciphered audio', () {
    expect(
      YouTubeMusicDirectResolver.resourceFromPlayerResponse(payload([opus])),
      isNull,
    );
    expect(
      YouTubeMusicDirectResolver.resourceFromPlayerResponse(
        payload([
          {'itag': 140, 'mimeType': 'audio/mp4', 'signatureCipher': 's=abc'},
        ]),
      ),
      isNull,
    );
  });

  test('rejects untrusted URL hosts', () {
    expect(
      YouTubeMusicDirectResolver.resourceFromPlayerResponse(
        payload([
          {...aac, 'url': 'https://not-googlevideo.example.org/song.m4a'},
        ]),
      ),
      isNull,
    );
  });

  test(
    'resolver makes one player API request, not a full media download',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          if (request.url.host.endsWith('.googlevideo.com')) {
            expect(request.headers['range'], 'bytes=0-16383');
            return http.Response(
              'audio bytes',
              206,
              headers: {'content-type': 'audio/mp4'},
            );
          }
          return http.Response('<html></html>', 200);
        }
        calls++;
        expect(request.method, 'POST');
        expect(request.url.host, 'www.youtube.com');
        final json = jsonDecode(request.body) as Map<String, dynamic>;
        expect(json['videoId'], 'abcdefghijk');
        return http.Response(jsonEncode(payload([aac])), 200);
      });
      final source = YouTubeMusicDirectResolver(client: client);
      final resource = await source.resolve('abcdefghijk');
      expect(resource?.uri.scheme, 'https');
      expect(calls, 1);
      source.close();
      client.close();
    },
  );

  test('reports access denial without exposing API response bodies', () async {
    final client = MockClient(
      (request) async => request.method == 'GET'
          ? http.Response('<html></html>', 200)
          : http.Response('a sensitive URL must never be displayed', 403),
    );
    final resolver = YouTubeMusicDirectResolver(client: client);
    StreamingPlaybackIssue? issue;
    final result = await resolver.resolve(
      'Z85lxckrtzg',
      onIssue: (value) => issue = value,
    );
    expect(result, isNull);
    expect(issue?.code, StreamingPlaybackIssueCode.youtubeHttpFailure);
    expect(issue?.clientAttempts.length, 4);
    expect(issue?.httpStatus, 403);
    expect(issue?.userMessage, contains('HTTP 403'));
    expect(issue?.userMessage, isNot(contains('sensitive URL')));
    client.close();
  });

  test('identifies rejected video playability status', () async {
    final client = MockClient(
      (request) async => request.method == 'GET'
          ? http.Response('<html></html>', 200)
          : http.Response(
              jsonEncode({
                'playabilityStatus': {
                  'status': 'LOGIN_REQUIRED',
                  'reason': 'private provider message',
                },
              }),
              200,
            ),
    );
    final resolver = YouTubeMusicDirectResolver(client: client);
    StreamingPlaybackIssue? issue;
    expect(
      await resolver.resolve('Z85lxckrtzg', onIssue: (value) => issue = value),
      isNull,
    );
    expect(issue?.code, StreamingPlaybackIssueCode.youtubeRestricted);
    expect(issue?.youtubeStatus, 'LOGIN_REQUIRED');
    expect(issue?.clientAttempts, hasLength(4));
    expect(issue?.userMessage, isNot(contains('private provider message')));
    client.close();
  });

  test('distinguishes unsupported audio from missing streaming data', () async {
    final responses = [
      ...List.generate(4, (_) => payload([opus])),
      ...List.generate(
        4,
        (_) => {
          'playabilityStatus': {'status': 'OK'},
        },
      ),
    ];
    var index = 0;
    final client = MockClient(
      (request) async => http.Response(
        request.method == 'GET'
            ? '<html></html>'
            : jsonEncode(responses[index++]),
        200,
      ),
    );
    final resolver = YouTubeMusicDirectResolver(client: client);
    final issues = <StreamingPlaybackIssue>[];
    for (var i = 0; i < 2; i++) {
      expect(
        await resolver.resolve('Z85lxckrtzg', onIssue: issues.add),
        isNull,
      );
    }
    // Each resolution now exhausts all profiles before reporting once.
    expect(issues, hasLength(2));
    expect(
      issues.first.code,
      StreamingPlaybackIssueCode.youtubeUnsupportedAudio,
    );
    expect(issues.last.code, StreamingPlaybackIssueCode.noAudioResource);
    client.close();
  });

  test('reports invalid YouTube ID before any network request', () async {
    final client = MockClient((_) async {
      fail('network must not be reached for an invalid ID');
    });
    final resolver = YouTubeMusicDirectResolver(client: client);
    StreamingPlaybackIssue? issue;
    expect(
      await resolver.resolve('not-an-id', onIssue: (value) => issue = value),
      isNull,
    );
    expect(issue?.code, StreamingPlaybackIssueCode.invalidVideoId);
    client.close();
  });

  test(
    'uses a public visitor ID in client context and request header',
    () async {
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          if (request.url.host.endsWith('.googlevideo.com')) {
            return http.Response(
              'audio bytes',
              206,
              headers: {'content-type': 'audio/mp4'},
            );
          }
          return http.Response(
            '<script>{"visitorData":"CgtTestVisitorValue123"}</script>',
            200,
          );
        }
        expect(request.headers['x-goog-visitor-id'], 'CgtTestVisitorValue123');
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        final context = payload['context'] as Map<String, dynamic>;
        final clientContext = context['client'] as Map<String, dynamic>;
        expect(clientContext['visitorData'], 'CgtTestVisitorValue123');
        expect(clientContext['clientName'], 'VISIONOS');
        expect(request.headers['x-youtube-client-name'], '101');
        return http.Response(
          jsonEncode({
            'playabilityStatus': {'status': 'OK'},
            'streamingData': {
              'adaptiveFormats': [aac],
            },
          }),
          200,
        );
      });
      final resolver = YouTubeMusicDirectResolver(client: client);
      expect(await resolver.resolve('Z85lxckrtzg'), isNotNull);
      client.close();
    },
  );

  test(
    'falls back after LOGIN_REQUIRED without leaking failed status',
    () async {
      var posted = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          return request.url.host.endsWith('.googlevideo.com')
              ? http.Response(
                  'audio bytes',
                  206,
                  headers: {'content-type': 'audio/mp4'},
                )
              : http.Response('', 503);
        }
        posted++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['videoId'], 'Z85lxckrtzg');
        if (posted == 1) {
          expect(request.headers['x-youtube-client-name'], '101');
          return http.Response(
            jsonEncode({
              'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
            }),
            200,
          );
        }
        expect(request.headers['x-youtube-client-name'], '28');
        return http.Response(jsonEncode(payload([aac])), 200);
      });
      final issues = <StreamingPlaybackIssue>[];
      final resolver = YouTubeMusicDirectResolver(client: client);
      final result = await resolver.resolve('Z85lxckrtzg', onIssue: issues.add);
      expect(result?.uri.host, 'rr1.googlevideo.com');
      expect(posted, 2);
      expect(issues, isEmpty);
      client.close();
    },
  );

  test(
    'reports bounded, sanitized status across all failing profiles',
    () async {
      var posts = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET') return http.Response('', 500);
        posts++;
        return http.Response(
          jsonEncode({
            'playabilityStatus': {
              'status': 'LOGIN_REQUIRED',
              'reason': 'signed=secret-private-url',
            },
          }),
          200,
        );
      });
      final resolver = YouTubeMusicDirectResolver(client: client);
      final issues = <StreamingPlaybackIssue>[];
      expect(
        await resolver.resolve('Z85lxckrtzg', onIssue: issues.add),
        isNull,
      );
      expect(posts, 4);
      expect(issues, hasLength(1));
      expect(issues.single.code, StreamingPlaybackIssueCode.youtubeRestricted);
      expect(issues.single.clientAttempts, hasLength(4));
      expect(issues.single.userMessage, contains('VISIONOS:LOGIN_REQUIRED'));
      expect(issues.single.userMessage, isNot(contains('secret-private-url')));
      client.close();
    },
  );

  test('skips a refused media URL and verifies the next client', () async {
    var posts = 0;
    var probes = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        if (!request.url.host.endsWith('.googlevideo.com')) {
          return http.Response('', 503);
        }
        probes++;
        expect(request.headers['range'], 'bytes=0-16383');
        return probes == 1
            ? http.Response('forbidden', 403)
            : http.Response(
                'audio bytes',
                206,
                headers: {'content-type': 'audio/mp4'},
              );
      }
      posts++;
      return http.Response(
        jsonEncode(
          payload([
            {
              ...aac,
              'url':
                  'https://rr$posts.googlevideo.com/videoplayback?expire=9999999999',
            },
          ]),
        ),
        200,
      );
    });
    final resolver = YouTubeMusicDirectResolver(client: client);
    final issues = <StreamingPlaybackIssue>[];
    final result = await resolver.resolve('Z85lxckrtzg', onIssue: issues.add);
    expect(result?.uri.host, 'rr2.googlevideo.com');
    expect(posts, 2);
    expect(probes, 2);
    expect(issues, isEmpty);
    client.close();
  });

  test('uses verified AAC backup when primary media is rejected', () async {
    var probes = 0;
    var posts = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        if (!request.url.host.endsWith('.googlevideo.com')) {
          return http.Response('', 503);
        }
        probes++;
        return request.url.host == 'rr1.googlevideo.com'
            ? http.Response(
                '<html>challenge</html>',
                200,
                headers: {'content-type': 'text/html'},
              )
            : http.Response(
                'audio bytes',
                206,
                headers: {'content-type': 'audio/mp4'},
              );
      }
      posts++;
      return http.Response(
        jsonEncode(
          payload([
            aac,
            {
              ...aac,
              'bitrate': 96000,
              'url':
                  'https://rr2.googlevideo.com/videoplayback?expire=9999999999',
            },
          ]),
        ),
        200,
      );
    });
    final resolver = YouTubeMusicDirectResolver(client: client);
    final result = await resolver.resolve('Z85lxckrtzg');
    expect(result?.uri.host, 'rr2.googlevideo.com');
    expect(posts, 1);
    expect(probes, 2);
    client.close();
  });

  test(
    'embedded profile supplies third-party context and verified audio',
    () async {
      var profileCalls = 0;
      final payloadWithAudio = payload([aac]);
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          if (request.url.host.endsWith('.googlevideo.com')) {
            expect(request.headers['range'], 'bytes=0-16383');
            return http.Response(
              'audio bytes',
              206,
              headers: {'content-type': 'audio/mp4'},
            );
          }
          return http.Response('', 503);
        }
        profileCalls++;
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        final context = payload['context'] as Map<String, dynamic>;
        final clientContext = context['client'] as Map<String, dynamic>;
        if (profileCalls < 4) {
          expect(context, isNot(contains('thirdParty')));
          return http.Response(
            jsonEncode({
              'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
            }),
            200,
          );
        }
        expect(request.headers['x-youtube-client-name'], '56');
        expect(request.headers['referer'], 'https://www.youtube.com/');
        expect(clientContext['clientName'], 'WEB_EMBEDDED_PLAYER');
        expect(clientContext['clientVersion'], '2.20260708.00.00');
        expect(clientContext['userAgent'], contains('Safari'));
        expect(
          context['thirdParty'],
          {'embedUrl': 'https://www.youtube.com/'},
        );
        return http.Response(jsonEncode(payloadWithAudio), 200);
      });
      // The fixture represents a successfully permitted embed, never a
      // workaround for recordings YouTube reports as restricted.
      final resolver = YouTubeMusicDirectResolver(client: client);
      final issues = <StreamingPlaybackIssue>[];
      final media = await resolver.resolve('Z85lxckrtzg', onIssue: issues.add);
      expect(media?.uri.host, 'rr1.googlevideo.com');
      expect(profileCalls, 4);
      expect(issues, isEmpty);
      resolver.close();
      client.close();
    },
  );

  test(
    'reports media rejection after every profile fails verification',
    () async {
      var posts = 0;
      final client = MockClient((request) async {
        if (request.method == 'GET') {
          return request.url.host.endsWith('.googlevideo.com')
              ? http.Response('not audio', 403)
              : http.Response('', 503);
        }
        posts++;
        return http.Response(jsonEncode(payload([aac])), 200);
      });
      final resolver = YouTubeMusicDirectResolver(client: client);
      StreamingPlaybackIssue? issue;
      expect(
        await resolver.resolve(
          'Z85lxckrtzg',
          onIssue: (value) => issue = value,
        ),
        isNull,
      );
      expect(posts, 4);
      expect(issue?.clientAttempts, hasLength(4));
      expect(issue?.clientAttempts, everyElement(contains('MEDIA_HTTP_403')));
      client.close();
    },
  );

  test('cools down media-refused clients for the same song only', () async {
    var posts = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return request.url.host.endsWith('.googlevideo.com')
            ? http.Response('refused', 403)
            : http.Response('', 503);
      }
      posts++;
      return http.Response(jsonEncode(payload([aac])), 200);
    });
    final resolver = YouTubeMusicDirectResolver(client: client);
    final firstIssues = <StreamingPlaybackIssue>[];
    expect(
      await resolver.resolve('Z85lxckrtzg', onIssue: firstIssues.add),
      isNull,
    );
    expect(posts, 4);
    final secondIssues = <StreamingPlaybackIssue>[];
    expect(
      await resolver.resolve('Z85lxckrtzg', onIssue: secondIssues.add),
      isNull,
    );
    expect(posts, 4);
    expect(
      secondIssues.single.clientAttempts,
      everyElement(contains('MEDIA_COOLDOWN')),
    );
    expect(await resolver.resolve('abcdefghijk'), isNull);
    expect(posts, 8);
    client.close();
  });
}
