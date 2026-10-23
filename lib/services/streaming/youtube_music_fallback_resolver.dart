import 'dart:async';

import 'streaming_playback_issue.dart';
import 'streaming_source.dart';
import 'youtube_explode_audio_resolver.dart';
import 'youtube_music_direct_resolver.dart';

/// Two independent, public-media extraction strategies. LastWave's open
/// playback architecture illustrates why a bounded direct fast path should
/// run before escalating to expensive cipher/manifests. This is an independent
/// Dart implementation; no GPL source code is included here.
///
/// First try anonymous InnerTube, which can produce an immediately playable
/// AAC resource from one request when YouTube authorizes it. Only if that
/// fails, invoke the more expensive SDK-less/JavaScriptCore extractor.
class YouTubeMusicFallbackResolver {
  const YouTubeMusicFallbackResolver({
    required this.explode,
    required this.direct,
  });

  final YouTubeExplodeAudioResolver explode;
  final YouTubeMusicDirectResolver direct;

  Future<StreamResource?> resolve(
    String videoId, {
    void Function(StreamingPlaybackIssue)? onIssue,
  }) async {
    var extractorAttempts = <String>[];
    StreamingPlaybackIssue? directIssue;

    try {
      final fast = await direct.resolve(
        videoId,
        onIssue: (issue) => directIssue = issue,
      ).timeout(const Duration(seconds: 36));
      if (fast != null) return fast;
    } on TimeoutException {
      directIssue = const StreamingPlaybackIssue(
        StreamingPlaybackIssueCode.youtubeTimeout,
      );
    } catch (_) {
      directIssue = const StreamingPlaybackIssue(
        StreamingPlaybackIssueCode.youtubeInvalidResponse,
      );
    }

    try {
      final enhanced = await explode.resolve(
        videoId,
        onFailure: (attempts) => extractorAttempts = attempts,
      ).timeout(const Duration(seconds: 65));
      if (enhanced != null) return enhanced;
    } on TimeoutException {
      extractorAttempts = ['EXTRACT:TIMEOUT'];
    } catch (_) {
      extractorAttempts = ['EXTRACT:FAILED'];
    }

    final issue = directIssue ??
        const StreamingPlaybackIssue(
          StreamingPlaybackIssueCode.noAudioResource,
        );
    onIssue?.call(StreamingPlaybackIssue(
      issue.code,
      httpStatus: issue.httpStatus,
      youtubeStatus: issue.youtubeStatus,
      clientAttempts: [
        ...extractorAttempts,
        ...issue.clientAttempts,
      ],
    ));
    return null;
  }
}
