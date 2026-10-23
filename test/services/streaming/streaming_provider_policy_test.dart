import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/streaming_provider_policy.dart';
import 'package:mornye/services/streaming/streaming_source.dart';
import 'package:mornye/services/streaming/streaming_playback_issue.dart';

class _FakeSource implements StreamingSource {
  _FakeSource(this.id, this.resource, {this.delay = Duration.zero});

  @override
  final String id;
  final StreamResource? resource;
  final Duration delay;

  @override
  Future<List<StreamingTrack>> search(String query) async => const [];

  @override
  Future<StreamResource?> resolve(StreamingTrack track) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return resource;
  }
}

void main() {
  const requested = StreamingTrack(
    id: 'catalog-1',
    title: 'Test Track',
    artist: 'Test Artist',
  );
  final playable = StreamResource(
    uri: Uri.parse('https://example.org/test.m4a'),
  );

  test('prefers promptly playable SoundCloud track', () async {
    final result = await const StreamingProviderPolicy().select(
      requested: requested,
      youtubeMusic: _FakeSource('youtube', playable),
      soundCloud: _FakeSource('soundcloud', playable),
      findExactFreelyPlayableMatch: (source, track) async => track,
    );
    expect(result?.sourceId, 'soundcloud');
  });

  test('does not wait indefinitely for unavailable SoundCloud', () async {
    final result =
        await const StreamingProviderPolicy(
          soundCloudProbeBudget: Duration(milliseconds: 10),
        ).select(
          requested: requested,
          youtubeMusic: _FakeSource('youtube', playable),
          soundCloud: _FakeSource(
            'soundcloud',
            playable,
            delay: const Duration(milliseconds: 200),
          ),
          findExactFreelyPlayableMatch: (source, track) async => track,
        );
    expect(result?.sourceId, 'youtube');
  });

  test(
    'does not accept a SoundCloud recording without verified match',
    () async {
      final result = await const StreamingProviderPolicy().select(
        requested: requested,
        youtubeMusic: _FakeSource('youtube', playable),
        soundCloud: _FakeSource('soundcloud', playable),
        findExactFreelyPlayableMatch: (source, track) async =>
            source.id == 'soundcloud' ? null : track,
      );
      expect(result?.sourceId, 'youtube');
    },
  );

  test('reports matching failure for YouTube without SoundCloud noise', () async {
    final issues = <StreamingPlaybackIssue>[];
    final selected = await const StreamingProviderPolicy().select(
      requested: requested,
      youtubeMusic: _FakeSource('youtube_music', playable),
      soundCloud: _FakeSource('soundcloud', null),
      findExactFreelyPlayableMatch: (source, track) async => null,
      onIssue: issues.add,
    );
    expect(selected, isNull);
    expect(
      issues.map((issue) => issue.code),
      [StreamingPlaybackIssueCode.noConfidentMatch],
    );
  });

  test('reports missing audio after a successful match', () async {
    final issues = <StreamingPlaybackIssue>[];
    final selected = await const StreamingProviderPolicy().select(
      requested: requested,
      youtubeMusic: _FakeSource('youtube_music', null),
      soundCloud: _FakeSource('soundcloud', null),
      findExactFreelyPlayableMatch: (source, track) async =>
          source.id == 'youtube_music' ? track : null,
      onIssue: issues.add,
    );
    expect(selected, isNull);
    expect(
      issues.single.code,
      StreamingPlaybackIssueCode.noAudioResource,
    );
  });
}
