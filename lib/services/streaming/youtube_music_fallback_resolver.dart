import 'streaming_playback_issue.dart';
import 'streaming_source.dart';
import 'youtube_explode_audio_resolver.dart';
import 'youtube_music_direct_resolver.dart';

/// Two independent, public-media extraction strategies. Try the SDK-less
/// extractor with optional iOS cipher support, then preserve the existing
/// InnerTube implementation as a final fallback.
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

    final enhanced = await explode.resolve(
      videoId,
      onFailure: (attempts) => extractorAttempts = attempts,
    );
    if (enhanced != null) return enhanced;

    final fallback = await direct.resolve(
      videoId,
      onIssue: (issue) => directIssue = issue,
    );
    if (fallback != null) return fallback;

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
