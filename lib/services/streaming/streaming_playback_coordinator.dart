import 'package:mornye/services/music_player_service.dart';

import 'streaming_playback_issue.dart';
import 'streaming_provider_policy.dart';
import 'streaming_match_resolver.dart';
import 'track_matcher.dart';
import 'streaming_source.dart';

/// Connects a resolved, *progressively playable* network resource to the
/// existing background-capable Mornye playback queue.
///
/// A URL is never downloaded here. The native audio player is responsible
/// for requesting media as it plays. This does not implement an audio
/// resolver; source adapters must provide permitted playback URLs.
class StreamingPlaybackCoordinator {
  const StreamingPlaybackCoordinator({
    required this.player,
    this.policy = const StreamingProviderPolicy(),
  });

  final MusicPlayerHandler player;
  final StreamingProviderPolicy policy;

  /// Catalog-level entry point shared by search results, albums and playlists.
  /// Uses a saved manual YouTube Music choice or conservative auto-matching
  /// instead of assuming another provider's catalog ID is a video ID.
  Future<bool> playCatalog({
    required CatalogTrack catalog,
    required StreamingSource youtubeMusic,
    required StreamingSource soundCloud,
    required StreamingMatchResolver matching,
    bool Function()? isCurrentRequest,
    void Function(StreamingPlaybackIssue)? onIssue,
  }) {
    return play(
      requested: StreamingTrack(
        id: catalog.id,
        title: catalog.title,
        artist: catalog.artist,
        duration: catalog.duration,
      ),
      youtubeMusic: youtubeMusic,
      soundCloud: soundCloud,
      findExactFreelyPlayableMatch: (source, _) =>
          matching.find(source, catalog),
      isCurrentRequest: isCurrentRequest,
      onIssue: onIssue,
    );
  }

  /// Returns false without altering the current queue when nothing playable
  /// can be resolved. In particular, never queue a preview as a full track.
  Future<bool> play({
    required StreamingTrack requested,
    required StreamingSource youtubeMusic,
    required StreamingSource soundCloud,
    required Future<StreamingTrack?> Function(
      StreamingSource source,
      StreamingTrack requested,
    )
    findExactFreelyPlayableMatch,
    bool Function()? isCurrentRequest,
    void Function(StreamingPlaybackIssue)? onIssue,
  }) async {
    final selected = await policy.select(
      requested: requested,
      youtubeMusic: youtubeMusic,
      soundCloud: soundCloud,
      findExactFreelyPlayableMatch: findExactFreelyPlayableMatch,
      onIssue: onIssue,
    );
    if (selected == null || (isCurrentRequest != null && !isCurrentRequest())) {
      return false;
    }

    final resource = selected.resource;
    // audioplayers cannot currently forward custom headers to iOS AVPlayer.
    if (resource.headers.isNotEmpty) {
      onIssue?.call(
        const StreamingPlaybackIssue(StreamingPlaybackIssueCode.invalidResource),
      );
      return false;
    }

    // The catalog owns display metadata; the online provider only supplies
    // a recording ID and playable resource. Never replace catalog titles,
    // artists or durations with inconsistent YouTube search-result metadata.
    final track = requested;
    final urls = [resource.uri, ...resource.fallbackUris.take(1)];
    for (final url in urls) {
      if (isCurrentRequest != null && !isCurrentRequest()) return false;
      if (url.scheme != 'https' ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty) {
        onIssue?.call(
          const StreamingPlaybackIssue(
            StreamingPlaybackIssueCode.invalidResource,
          ),
        );
        continue;
      }

      final item = PlayableMedia(
        id: 'stream:${selected.sourceId}:${selected.track.id}',
        source: url.toString(),
        title: track.title,
        artist: track.artist,
        album: track.album ?? '',
        networkArtworkSource: track.artworkUrl?.toString(),
        duration: track.duration,
      );
      try {
        // Native source preparation may fail even when the resolver returned
        // a URL. Try at most one already-resolved, lower-bitrate alternative.
        await player.setQueueAndPlay([item]);
        if (player.isOnlineSourcePrepared(item.id)) return true;
      } catch (_) {
        // The player can throw while preparing a remote source. Do not show
        // exception text: native HTTP errors may include signed audio URLs.
      }
      onIssue?.call(
        const StreamingPlaybackIssue(StreamingPlaybackIssueCode.playerRejected),
      );
    }
    return false;
  }
}
