
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/streaming/youtube_music_direct_resolver.dart';
import 'package:mornye/services/streaming/streaming_playback_issue.dart';

/// An explicit, real-provider check: requires a publicly playable YouTube
/// video ID for which the tester has permission to access playback.
/// No audio is captured or redistributed. YouTube may reject these unofficial
/// requests; that is a service-access failure, not a successful playback test.
///
/// Example:
/// flutter test integration_test/renee_youtube_music_live_test.dart \\
///   -d `ios-device-id` \\
///   --dart-define=RENEE_YTM_TEST_VIDEO_ID=`11-character-video-id`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const videoId = String.fromEnvironment('RENEE_YTM_TEST_VIDEO_ID');
  testWidgets(
    'Real YouTube Music resource starts in native iOS AVPlayer',
    (tester) async {
      final resolver = YouTubeMusicDirectResolver(
        requestTimeout: const Duration(seconds: 15),
      );
      final deck = MusicPlaybackDeck(playerId: 'renee-live-ytm-test');
      final started = Stopwatch()..start();
      try {
        StreamingPlaybackIssue? failure;
        final resource = await resolver.resolve(
          videoId,
          onIssue: (issue) => failure = issue,
        );
        expect(
          resource,
          isNotNull,
          reason: 'Provider did not supply a public, directly playable '
              'iOS-compatible resource. Playback was NOT validated. '
              '${failure?.userMessage ?? 'No resolver details.'}',
        );
        expect(resource!.uri.scheme, 'https');
        expect(resource.headers, isEmpty);
        await deck.setNetworkSource(resource.uri.toString())
            .timeout(const Duration(seconds: 30));
        await deck.resume();
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        var advanced = false;
        while (DateTime.now().isBefore(deadline)) {
          final position = await deck.getCurrentPosition() ?? Duration.zero;
          if (position >= const Duration(milliseconds: 900)) {
            advanced = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        started.stop();
        // Report only timings and the test source ID, never signed URLs.
        // ignore: avoid_print
        print('RENEE_LIVE_YTM_TEST '
            'videoId=$videoId startupMs=${started.elapsedMilliseconds} '
            'nativePlaybackAdvanced=$advanced');
        expect(advanced, isTrue,
            reason: 'A resolved URL alone does not prove audible playback.');
      } finally {
        await deck.dispose();
        resolver.close();
      }
    },
    skip: videoId.isEmpty,
  );
}
