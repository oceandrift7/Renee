import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';

import 'manual_match_store.dart';
import 'streaming_playback_issue.dart';
import 'streaming_match_resolver.dart';
import 'streaming_playback_coordinator.dart';
import 'streaming_source.dart';
import 'track_matcher.dart';
import 'youtube_music_direct_resolver.dart';
import 'youtube_music_signed_session.dart';
import 'youtube_explode_audio_resolver.dart';
import 'youtube_music_fallback_resolver.dart';
import 'youtube_music_streaming_source.dart';

/// One-shot online playback: resolve a fresh URL for every Play request and
/// hand it to the native player. Never downloads the entire file first.
///
/// Experimental: YouTube's private resource endpoint may deny or change its
/// responses; a successful URL lookup is not proof the media plays on-device.
enum ReneeOnlinePlaybackResult { prepared, unavailable, superseded }

class ReneeOnlinePlaybackAttempt {
  const ReneeOnlinePlaybackAttempt(this.result, {this.issue});
  final ReneeOnlinePlaybackResult result;
  final StreamingPlaybackIssue? issue;
}

class ReneeOnlinePlayback {
  const ReneeOnlinePlayback();

  // Shared across track buttons. A later Play tap supersedes an older network
  // lookup, preventing a slow response from replacing the new song.
  static int _requestGeneration = 0;

  /// Capture the tap before any asynchronous local-library search begins.
  static int beginRequest() => ++_requestGeneration;

  static bool isCurrentRequest(int generation) =>
      _requestGeneration == generation;

  /// Any other transport action can invalidate a pending online lookup so it
  /// cannot replace a local track selected while the lookup was in flight.
  static void cancelPending() {
    beginRequest();
  }

  Future<bool> tryPlay(WidgetRef ref, Track track) async =>
      await tryPlayWithStatus(ref, track) == ReneeOnlinePlaybackResult.prepared;

  Future<ReneeOnlinePlaybackResult> tryPlayWithStatus(
    WidgetRef ref,
    Track track, {
    int? requestGeneration,
  }) async =>
      (await tryPlayDiagnosed(
        ref,
        track,
        requestGeneration: requestGeneration,
      )).result;

  Future<ReneeOnlinePlaybackAttempt> tryPlayDiagnosed(
    WidgetRef ref,
    Track track, {
    int? requestGeneration,
  }) async {
    final generation = requestGeneration ?? beginRequest();
    bool isCurrent() => isCurrentRequest(generation);
    const superseded = ReneeOnlinePlaybackAttempt(
      ReneeOnlinePlaybackResult.superseded,
    );
    if (!isCurrent()) return superseded;

    try {
      final handler = await ref
          .read(musicPlayerControllerProvider)
          .ensureInitialized();
      if (!isCurrent()) return superseded;
      if (handler == null) {
        return const ReneeOnlinePlaybackAttempt(
          ReneeOnlinePlaybackResult.unavailable,
          issue: StreamingPlaybackIssue(
            StreamingPlaybackIssueCode.playerUnavailable,
          ),
        );
      }

      final prefs = await SharedPreferences.getInstance();
      if (!isCurrent()) return superseded;
      final catalogArtwork = Uri.tryParse(track.coverUrl ?? '');
      final requested = CatalogTrack(
        provider: track.source ?? 'catalog',
        id: track.id,
        title: track.name,
        artist: track.artistName,
        duration: track.duration > 0
            ? Duration(seconds: track.duration)
            : null,
        isrc: track.isrc,
        album: track.albumName,
        artworkUrl: catalogArtwork != null &&
                catalogArtwork.scheme == 'https' &&
                catalogArtwork.host.isNotEmpty
            ? catalogArtwork
            : null,
      );

      StreamingPlaybackIssue? providerIssue;
      StreamingPlaybackIssue? pipelineIssue;
      // A future, user-consented sign-in flow may provide an encrypted
      // on-device Music session. Never attempt to read Google credentials from
      // Safari, the Keychain, or another app without explicit authorization.
      final signedInSession = await const YouTubeMusicSessionStore().read();
      if (!isCurrent()) return superseded;
      final directResolver = YouTubeMusicDirectResolver(
        signedInSession: signedInSession,
      );
      final extractedResolver = YouTubeExplodeAudioResolver();
      final fallbackResolver = YouTubeMusicFallbackResolver(
        explode: extractedResolver,
        direct: directResolver,
      );
      final youtube = YouTubeMusicStreamingSource(
        resolveAudio: (id) => fallbackResolver.resolve(
          id,
          onIssue: (issue) => providerIssue = issue,
        ),
      );
      try {
        final coordinator = StreamingPlaybackCoordinator(player: handler);
        final prepared = await coordinator.playCatalog(
          catalog: requested,
          youtubeMusic: youtube,
          // SoundCloud is not wired up yet. Never claim a full/free match
          // without checking playback rights and actual resource availability.
          soundCloud: const _UnconfiguredSoundCloud(),
          matching: StreamingMatchResolver(
            manualMatches: ManualMatchStore(prefs),
          ),
          isCurrentRequest: isCurrent,
          onIssue: (issue) => pipelineIssue = issue,
        );
        if (!isCurrent()) return superseded;
        return ReneeOnlinePlaybackAttempt(
          prepared
              ? ReneeOnlinePlaybackResult.prepared
              : ReneeOnlinePlaybackResult.unavailable,
          issue: prepared
              ? null
              : (providerIssue ??
                    pipelineIssue ??
                    const StreamingPlaybackIssue(
                      StreamingPlaybackIssueCode.unexpectedFailure,
                    )),
        );
      } finally {
        youtube.close();
        directResolver.close();
        extractedResolver.close();
      }
    } catch (_) {
      if (!isCurrent()) return superseded;
      return const ReneeOnlinePlaybackAttempt(
        ReneeOnlinePlaybackResult.unavailable,
        issue: StreamingPlaybackIssue(
          StreamingPlaybackIssueCode.unexpectedFailure,
        ),
      );
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
