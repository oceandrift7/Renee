import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mornye/services/streaming/youtube_music_direct_resolver.dart';

void main() {
  final aac = {
    'itag': 140,
    'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
    'bitrate': 128000,
    'url': 'https://rr1.googlevideo.com/videoplayback?expire=99999999',
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

  test('declines gated and unavailable videos', () {
    expect(
      YouTubeMusicDirectResolver.resourceFromPlayerResponse({
        'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
        'streamingData': {'adaptiveFormats': [aac]},
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
      YouTubeMusicDirectResolver.resourceFromPlayerResponse(payload([
        {'itag': 140, 'mimeType': 'audio/mp4', 'signatureCipher': 's=abc'},
      ])),
      isNull,
    );
  });

  test('rejects untrusted URL hosts', () {
    expect(
      YouTubeMusicDirectResolver.resourceFromPlayerResponse(payload([
        {
          ...aac,
          'url': 'https://not-googlevideo.example.org/song.m4a',
        },
      ])),
      isNull,
    );
  });

  test('resolver makes one player API request, not a full media download', () async {
    var calls = 0;
    final client = MockClient((request) async {
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
  });
}
