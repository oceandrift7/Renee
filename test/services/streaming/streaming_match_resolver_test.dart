import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/streaming_match_resolver.dart';
import 'package:mornye/services/streaming/streaming_source.dart';
import 'package:mornye/services/streaming/track_matcher.dart';

class _CatalogSource implements StreamingSource {
  _CatalogSource(this.id, this.entries);
  @override
  final String id;
  final List<StreamingTrack> entries;
  @override
  Future<List<StreamingTrack>> search(String query) async => entries;
  @override
  Future<StreamResource?> resolve(StreamingTrack track) async => null;
}

void main() {
  const target = CatalogTrack(
    provider: 'spotify-web',
    id: 'catalog-id',
    title: 'A Song',
    artist: 'An Artist',
    duration: Duration(seconds: 210),
  );
  final match = const StreamingMatchResolver();

  test('skips search for a known YouTube Music video ID', () async {
    const alreadyIdentified = CatalogTrack(
      provider: 'ytmusic-spotiflac',
      id: 'abcdefghijk',
      title: 'A Song',
      artist: 'An Artist',
    );
    final resolved = await match.find(
      _CatalogSource('youtube_music', const []),
      alreadyIdentified,
    );
    expect(resolved?.id, 'abcdefghijk');
  });

  test('matches the exact recording', () async {
    final result = await match.find(
      _CatalogSource('youtube_music', const [
        StreamingTrack(
          id: 'abcdefghijk',
          title: 'A Song',
          artist: 'An Artist',
          duration: Duration(seconds: 211),
        ),
      ]),
      target,
    );
    expect(result?.id, 'abcdefghijk');
  });

  test('rejects live versions and duration mismatches', () async {
    final result = await match.find(
      _CatalogSource('youtube_music', const [
        StreamingTrack(
          id: 'abcdefghijk',
          title: 'A Song (Live)',
          artist: 'An Artist',
          duration: Duration(seconds: 210),
        ),
        StreamingTrack(
          id: 'abcdefghijl',
          title: 'A Song',
          artist: 'An Artist',
          duration: Duration(seconds: 265),
        ),
      ]),
      target,
    );
    expect(result, isNull);
  });

  test(
    'does not silently accept competing equally strong recordings',
    () async {
      final result = await match.find(
        _CatalogSource('soundcloud', const [
          StreamingTrack(
            id: 'sc-one',
            title: 'A Song',
            artist: 'An Artist',
            duration: Duration(seconds: 210),
          ),
          StreamingTrack(
            id: 'sc-two',
            title: 'A Song',
            artist: 'An Artist',
            duration: Duration(seconds: 210),
          ),
        ]),
        target,
      );
      expect(result, isNull);
    },
  );
}
