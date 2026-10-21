import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/streaming_source.dart';
import 'package:mornye/services/streaming/track_matcher.dart';

void main() {
  const matcher = TrackMatcher();
  const catalog = CatalogTrack(
    provider: 'spotify',
    id: 'abc',
    title: 'Example Song',
    artist: 'Example Artist',
    duration: Duration(seconds: 220),
  );

  test('ranks matching recording ahead of unrelated recording', () {
    final results = matcher.rank(catalog, const [
      StreamingTrack(id: 'bad', title: 'Different', artist: 'Someone'),
      StreamingTrack(
        id: 'good',
        title: 'Example Song',
        artist: 'Example Artist',
        duration: Duration(seconds: 220),
      ),
    ]);
    expect(results.first.track.id, 'good');
  });

  test('does not automatically choose between ambiguous candidates', () {
    final candidates = List.generate(
      2,
      (index) => const StreamingTrack(
        id: 'same',
        title: 'Example Song',
        artist: 'Example Artist',
        duration: Duration(seconds: 220),
      ),
    );
    expect(matcher.confidentMatch(catalog, candidates), isNull);
  });

  test('catalog keys distinguish providers', () {
    expect(catalog.storageKey, isNot(const CatalogTrack(
      provider: 'deezer',
      id: 'abc',
      title: 'Example Song',
      artist: 'Example Artist',
    ).storageKey));
  });
}
