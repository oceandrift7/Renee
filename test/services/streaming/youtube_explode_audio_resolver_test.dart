import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mornye/services/streaming/youtube_explode_audio_resolver.dart';
import 'package:mornye/services/streaming/youtube_music_fallback_resolver.dart';
import 'package:mornye/services/streaming/youtube_music_direct_resolver.dart';
import 'package:mornye/services/streaming/streaming_playback_issue.dart';

void main() {
  ExtractedAacCandidate candidate({
    String host = 'rr1.googlevideo.com',
    int bitrate = 128000,
    int itag = 140,
    int expiry = 9999999999,
  }) => ExtractedAacCandidate(
    url: Uri.parse('https://$host/videoplayback?expire=$expiry'),
    bitrate: bitrate,
    itag: itag,
  );

  test('rejects low quality, untrusted and expired extracted streams', () {
    expect(
      YouTubeExplodeAudioResolver.isAcceptedCandidate(
        candidate(bitrate: 48000, itag: 139),
      ),
      isFalse,
    );
    expect(
      YouTubeExplodeAudioResolver.isAcceptedCandidate(
        candidate(host: 'rr1.googlevideo.com.evil.org'),
      ),
      isFalse,
    );
    expect(
      YouTubeExplodeAudioResolver.isAcceptedCandidate(candidate(expiry: 1000)),
      isFalse,
    );
    expect(
      YouTubeExplodeAudioResolver.isAcceptedCandidate(candidate()),
      isTrue,
    );
  });

  test('selects 128kbps AAC with deduplicated 96kbps alternatives', () {
    final options = YouTubeExplodeAudioResolver.candidateUrls([
      candidate(bitrate: 96000, host: 'rr3.googlevideo.com'),
      candidate(),
      candidate(),
      candidate(bitrate: 160000, host: 'rr2.googlevideo.com'),
      candidate(bitrate: 48000, itag: 139),
    ]);
    expect(options, hasLength(3));
    expect(options.first.host, 'rr1.googlevideo.com');
    expect(options.last.host, 'rr2.googlevideo.com');
  });

  test(
    'SDK-less extractor probes first 16 KiB without full download',
    () async {
      var probes = 0;
      final client = MockClient((request) async {
        probes++;
        expect(request.method, 'GET');
        expect(request.headers['range'], 'bytes=0-16383');
        return http.Response(
          'media bytes',
          206,
          headers: {'content-type': 'audio/mp4'},
        );
      });
      final names = <String>[];
      final resolver = YouTubeExplodeAudioResolver(
        probeClient: client,
        manifestLookup: (id, name) async {
          expect(id, 'Z85lxckrtzg');
          names.add(name);
          return [candidate()];
        },
      );
      final result = await resolver.resolve('Z85lxckrtzg');
      expect(result?.uri.host, 'rr1.googlevideo.com');
      expect(result?.headers, isEmpty);
      expect(probes, 1);
      expect(names, ['ANDROID_SDKLESS']);
      resolver.close();
      client.close();
    },
  );

  test(
    'rejects HTML challenges and tries the next independent client',
    () async {
      final visited = <String>[];
      final client = MockClient((request) async {
        return request.url.host == 'rr1.googlevideo.com'
            ? http.Response(
                '<html>blocked</html>',
                200,
                headers: {'content-type': 'text/html'},
              )
            : http.Response(
                'media bytes',
                206,
                headers: {'content-type': 'audio/mp4'},
              );
      });
      final resolver = YouTubeExplodeAudioResolver(
        probeClient: client,
        manifestLookup: (_, name) async {
          visited.add(name);
          if (name == 'ANDROID_SDKLESS') return [candidate()];
          return [candidate(host: 'rr2.googlevideo.com')];
        },
      );
      final result = await resolver.resolve('Z85lxckrtzg');
      expect(result?.uri.host, 'rr2.googlevideo.com');
      expect(visited, ['ANDROID_SDKLESS', 'IOS']);
      resolver.close();
      client.close();
    },
  );

  test(
    'all failed extractor profiles produce safe bounded diagnostics',
    () async {
      final client = MockClient((_) async => http.Response('no', 403));
      final resolver = YouTubeExplodeAudioResolver(
        probeClient: client,
        manifestLookup: (_, _) async => [candidate()],
      );
      List<String>? attempts;
      expect(
        await resolver.resolve(
          'Z85lxckrtzg',
          onFailure: (value) => attempts = value,
        ),
        isNull,
      );
      expect(attempts, hasLength(5));
      expect(attempts, everyElement(contains('MEDIA_REJECTED')));
      expect(attempts!.join(','), isNot(contains('videoplayback')));
      resolver.close();
      client.close();
    },
  );

  test(
    'fallback short-circuits the direct API after a verified stream',
    () async {
      final probe = MockClient(
        (_) async =>
            http.Response('media', 206, headers: {'content-type': 'audio/mp4'}),
      );
      final unused = MockClient((_) async {
        fail('Direct InnerTube should not run after successful extraction');
      });
      final enhanced = YouTubeExplodeAudioResolver(
        probeClient: probe,
        manifestLookup: (_, _) async => [candidate()],
      );
      final direct = YouTubeMusicDirectResolver(client: unused);
      final combined = YouTubeMusicFallbackResolver(
        explode: enhanced,
        direct: direct,
      );
      final issues = <StreamingPlaybackIssue>[];
      expect(
        await combined.resolve('Z85lxckrtzg', onIssue: issues.add),
        isNotNull,
      );
      expect(issues, isEmpty);
      enhanced.close();
      direct.close();
      probe.close();
      unused.close();
    },
  );

  test(
    'fallback preserves provider LOGIN_REQUIRED and extraction attempts',
    () async {
      final probe = MockClient((_) async => http.Response('', 403));
      final api = MockClient((request) async {
        if (request.method == 'GET') return http.Response('', 503);
        return http.Response(
          jsonEncode({
            'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
          }),
          200,
        );
      });
      final enhanced = YouTubeExplodeAudioResolver(
        probeClient: probe,
        manifestLookup: (_, _) async => const [],
      );
      final direct = YouTubeMusicDirectResolver(client: api);
      final combined = YouTubeMusicFallbackResolver(
        explode: enhanced,
        direct: direct,
      );
      StreamingPlaybackIssue? issue;
      expect(
        await combined.resolve(
          'Z85lxckrtzg',
          onIssue: (value) => issue = value,
        ),
        isNull,
      );
      expect(issue?.code, StreamingPlaybackIssueCode.youtubeRestricted);
      expect(issue?.clientAttempts.length, 9);
      expect(issue?.userMessage, contains('ANDROID_SDKLESS:NO_AAC'));
      expect(issue?.userMessage, contains('VISIONOS:LOGIN_REQUIRED'));
      enhanced.close();
      direct.close();
      probe.close();
      api.close();
    },
  );
}
