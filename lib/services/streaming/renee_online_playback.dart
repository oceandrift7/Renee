import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';

import 'manual_match_store.dart';
import 'streaming_match_resolver.dart';
import 'streaming_playback_coordinator.dart';
import 'streaming_source.dart';
import 'track_matcher.dart';
import 'youtube_music_direct_resolver.dart';
import 'youtube_music_streaming_source.dart';

/// One-shot online playback: resolve a fresh URL for every Play request and
/// hand it to the native player. Never downloads the entire file first.
///
/// Experimental: YouTube's private resource endpoint may deny or change its
/// responses; a successful URL lookup is not proof the media plays on-device.
class ReneeOnlinePlayback {
  const ReneeOnlinePlayback();

  Future<bool> tryPlay(WidgetRef ref, Track track) async {
    final handler = await ref.read(musicPlayerControllerProvider)
        .ensureInitialized();
    if (handler == null) return false;

    final prefs = await SharedPreferences.getInstance();
    final provider = track.source ?? 'catalog';
    final requested = CatalogTrack(
      provider: provider,
      id: track.id,
      title: track.name,
      artist: track.artistName,
      duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
      isrc: track.isrc,
    );

    final directResolver = YouTubeMusicDirectResolver();
    final youtube = YouTubeMusicStreamingSource(
      resolveAudio: directResolver.resolve,
    );
    try {
      final coordinator = StreamingPlaybackCoordinator(player: handler);
      return await coordinator.playCatalog(
        catalog: requested,
        youtubeMusic: youtube,
        // SoundCloud is not wired up yet. Never claim a full/free match
        // without checking playback rights and actual resource availability.
        soundCloud: const _UnconfiguredSoundCloud(),
        matching: StreamingMatchResolver(
          manualMatches: ManualMatchStore(prefs),
        ),
      );
    } finally {
      youtube.close();
      directResolver.close();
    }
  }
}

/// No misleading SoundCloud preview/full-track substitution until we have
/// a verified freely playable provider adapter.
class _UnconfiguredSoundCloud implements StreamingSource {
  const _UnconfiguredSoundCloud();
  @override
  String get id => 'soundcloud';
  @override
  Future<List<StreamingTrack>> search(String query) async => const [];
  @override
  Future<StreamResource?> resolve(StreamingTrack track) async => null;
}
