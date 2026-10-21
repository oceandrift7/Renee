import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/playable_media.dart';

import 'streaming_provider_policy.dart';
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

  /// Returns false without altering the current queue when nothing playable
  /// can be resolved. In particular, never queue a preview as a full track.
  Future<bool> play({
    required StreamingTrack requested,
    required StreamingSource youtubeMusic,
    required StreamingSource soundCloud,
    required Future<StreamingTrack?> Function(
      StreamingSource source,
      StreamingTrack requested,
    ) findExactFreelyPlayableMatch,
  }) async {
    final selected = await policy.select(
      requested: requested,
      youtubeMusic: youtubeMusic,
      soundCloud: soundCloud,
      findExactFreelyPlayableMatch: findExactFreelyPlayableMatch,
    );
    if (selected == null) return false;

    final resource = selected.resource;
    // The existing player accepts URL audio but does not yet forward HTTP
    // headers. Refuse resources requiring them rather than fail mysteriously.
    if (resource.headers.isNotEmpty) return false;
    if (resource.uri.scheme != 'https') return false;

    final track = selected.track;
    final item = PlayableMedia(
      id: 'stream:${selected.sourceId}:${track.id}',
      source: resource.uri.toString(),
      title: track.title,
      artist: track.artist,
      album: track.album ?? '',
      networkArtworkSource: track.artworkUrl?.toString(),
      duration: track.duration,
    );
    await player.setQueueAndPlay([item]);
    return true;
  }
}
