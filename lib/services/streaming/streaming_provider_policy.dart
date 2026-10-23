import 'dart:async';

import 'streaming_playback_issue.dart';
import 'streaming_source.dart';

/// The default online provider is YouTube Music. SoundCloud may win only when
/// it quickly confirms a full, freely playable match to the requested recording.
///
/// This is a selection policy, not a source implementation: callers must supply
/// working, authorized StreamingSource adapters.
class StreamingProviderPolicy {
  const StreamingProviderPolicy({
    this.soundCloudProbeBudget = const Duration(milliseconds: 900),
    this.minimumMatchConfidence = 0.88,
  });

  final Duration soundCloudProbeBudget;
  final double minimumMatchConfidence;

  /// The callback must verify recording identity (not merely a similar title).
  /// It must not mark previews, subscription-gated tracks, remixes, or covers
  /// as freely playable matches.
  Future<SelectedStream?> select({
    required StreamingTrack requested,
    required StreamingSource youtubeMusic,
    required StreamingSource soundCloud,
    required Future<StreamingTrack?> Function(
      StreamingSource source,
      StreamingTrack requested,
    )
    findExactFreelyPlayableMatch,
    void Function(StreamingPlaybackIssue)? onIssue,
  }) async {
    // Start both lookups immediately; do not block YouTube Music on SoundCloud.
    final ytTask = _candidate(
      youtubeMusic,
      requested,
      findExactFreelyPlayableMatch,
      onIssue,
    );
    final scTask = _candidate(
      soundCloud,
      requested,
      findExactFreelyPlayableMatch,
      onIssue,
    );

    // SoundCloud gets a short opportunity to win, never an unlimited wait.
    final sc = await scTask.timeout(
      soundCloudProbeBudget,
      onTimeout: () => null,
    );
    if (sc != null) return sc;

    // If SoundCloud is unavailable or slow, use YouTube Music.
    return ytTask;
  }

  Future<SelectedStream?> _candidate(
    StreamingSource source,
    StreamingTrack requested,
    Future<StreamingTrack?> Function(StreamingSource, StreamingTrack) match,
    void Function(StreamingPlaybackIssue)? onIssue,
  ) async {
    // SoundCloud is optional and currently unconfigured in Renée. Never let
    // its failed probe hide a real YouTube Music playback diagnosis.
    void report(StreamingPlaybackIssueCode code) {
      if (source.id == 'youtube_music') {
        onIssue?.call(StreamingPlaybackIssue(code));
      }
    }

    try {
      final StreamingTrack? track;
      try {
        track = await match(source, requested);
      } catch (_) {
        report(StreamingPlaybackIssueCode.matchSearchFailed);
        return null;
      }
      if (track == null) {
        report(StreamingPlaybackIssueCode.noConfidentMatch);
        return null;
      }
      final StreamResource? resource;
      try {
        resource = await source.resolve(track);
      } catch (_) {
        report(StreamingPlaybackIssueCode.noAudioResource);
        return null;
      }
      if (resource == null || !resource.uri.hasScheme) {
        report(StreamingPlaybackIssueCode.noAudioResource);
        return null;
      }
      if (resource.uri.scheme != 'https' && resource.uri.scheme != 'http') {
        report(StreamingPlaybackIssueCode.invalidResource);
        return null;
      }
      return SelectedStream(
        sourceId: source.id,
        track: track,
        resource: resource,
      );
    } catch (_) {
      report(StreamingPlaybackIssueCode.unexpectedFailure);
      return null;
    }
  }
}

class SelectedStream {
  const SelectedStream({
    required this.sourceId,
    required this.track,
    required this.resource,
  });

  final String sourceId;
  final StreamingTrack track;
  final StreamResource resource;
}
