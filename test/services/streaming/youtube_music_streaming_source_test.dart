import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/streaming_source.dart';
import 'package:mornye/services/streaming/youtube_music_streaming_source.dart';

void main() {
  const track = StreamingTrack(
    id: 'abcdefghijk',
    title: 'Example',
    artist: 'Example Artist',
  );

  test('resolves valid video IDs to playable HTTPS resources', () async {
    var calls = 0;
    final source = YouTubeMusicStreamingSource(
      resolveAudio: (id) async {
        calls++;
        expect(id, 'abcdefghijk');
        return StreamResource(
          uri: Uri.parse('https://cdn.example.com/audio.m4a'),
        );
      },
    );
    final result = await source.resolve(track);
    expect(result?.uri.scheme, 'https');
    expect(calls, 1);
    source.close();
  });

  test('does not resolve album IDs or malformed video IDs', () async {
    var calls = 0;
    final source = YouTubeMusicStreamingSource(
      resolveAudio: (_) async {
        calls++;
        return StreamResource(uri: Uri.parse('https://cdn.example.com/a.m4a'));
      },
    );
    final result = await source.resolve(
      const StreamingTrack(id: 'MPREb_album', title: 'Album', artist: 'Artist'),
    );
    expect(result, isNull);
    expect(calls, 0);
    source.close();
  });

  test('rejects insecure audio resources', () async {
    final source = YouTubeMusicStreamingSource(
      resolveAudio: (_) async =>
          StreamResource(uri: Uri.parse('http://cdn.example.com/audio.m4a')),
    );
    expect(await source.resolve(track), isNull);
    source.close();
  });

  test('times out a stalled provider', () async {
    final source = YouTubeMusicStreamingSource(
      lookupTimeout: const Duration(milliseconds: 10),
      resolveAudio: (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return StreamResource(uri: Uri.parse('https://cdn.example.com/a.m4a'));
      },
    );
    await expectLater(source.resolve(track), throwsA(isA<Exception>()));
    source.close();
  });
}
