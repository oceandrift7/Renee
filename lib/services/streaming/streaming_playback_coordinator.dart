import 'package:mornye/services/music_player_service.dart';

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
  }) async {
    final selected = await policy.select(
      requested: requested,
      youtubeMusic: youtubeMusic,
      soundCloud: soundCloud,
      findExactFreelyPlayableMatch: findExactFreelyPlayableMatch,
    );
    if (selected == null || (isCurrentRequest != null && !isCurrentRequest())) {
      return false;
    }

    final resource = selected.resource;
    // audioplayers currently cannot forward request headers to AVPlayer.
    // Reject these until a supported native transport is implemented.
    if (resource.headers.isNotEmpty) return false;
    if (resource.uri.scheme != 'https') return false;

    final track = selected.track;
    final item = PlayableMedia(
      id: 'stream:${selected.sourceId}:${track.id}',
      source: resource.uri.toString(),
      networkHeaders: resource.headers,
      title: track.title,
      artist: track.artist,
      album: track.album ?? '',
      networkArtworkSource: track.artworkUrl?.toString(),
      duration: track.duration,
    );
    // A later tap can supersede this request while a provider is resolving.
    if (isCurrentRequest != null && !isCurrentRequest()) return false;
    await player.setQueueAndPlay([item]);
    return player.isOnlineSourcePrepared(item.id);
  }
}
