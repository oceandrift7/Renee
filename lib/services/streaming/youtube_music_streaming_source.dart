import 'dart:async';

import 'streaming_source.dart';
import 'youtube_music_search.dart';

/// Resolver supplied by a playback-capable extension or licensed backend.
/// This callback must return a real, playable full-track resource, not a
/// download job, a preview, or a YouTube webpage URL.
typedef YouTubeAudioResourceResolver = Future<StreamResource?> Function(
  String videoId,
);

/// YouTube Music catalog/search adapter for Renée's streaming architecture.
///
/// Metadata search works independently from playback authorization. A host
/// must explicitly supply [resolveAudio] backed by a provider that is
/// permitted to return audio resources. The Mornye download extension does
/// NOT currently expose such a streaming API.
class YouTubeMusicStreamingSource implements StreamingSource {
  YouTubeMusicStreamingSource({
    required YouTubeAudioResourceResolver resolveAudio,
    YouTubeMusicSearch? catalogSearch,
    this.lookupTimeout = const Duration(seconds: 8),
  }) : _resolveAudio = resolveAudio,
       _search = catalogSearch ?? YouTubeMusicSearch(),
       _ownsSearch = catalogSearch == null;

  final YouTubeAudioResourceResolver _resolveAudio;
  final YouTubeMusicSearch _search;
  final bool _ownsSearch;
  final Duration lookupTimeout;

  @override
  String get id => 'youtube_music';

  @override
  Future<List<StreamingTrack>> search(String query) {
    if (query.trim().isEmpty) return Future.value(const []);
    return _search.search(query).timeout(lookupTimeout);
  }

  @override
  Future<StreamResource?> resolve(StreamingTrack track) async {
    // YouTube video IDs are eleven characters. Reject catalog/album IDs,
    // arbitrary URLs, and invalid values before reaching the resolver.
    if (track.id.startsWith('MPREb_') ||
        !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(track.id)) {
      return null;
    }
    final resource = await _resolveAudio(track.id).timeout(lookupTimeout);
    if (resource == null) return null;
    if (resource.uri.scheme != 'https' ||
        resource.uri.host.isEmpty ||
        resource.uri.userInfo.isNotEmpty) {
      return null;
    }
    return resource;
  }

  void close() {
    if (_ownsSearch) _search.close();
  }
}
