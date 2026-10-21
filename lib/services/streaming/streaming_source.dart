/// Online listening is intentionally separate from Mornye's download extensions.
/// Catalog metadata does not imply that a playable audio URL is available.
class StreamingTrack {
  const StreamingTrack({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.artworkUrl,
    this.duration,
  });

  final String id;
  final String title;
  final String artist;
  final String? album;
  final Uri? artworkUrl;
  final Duration? duration;
}

/// A short-lived playable URL with optional request headers.
/// Providers should refresh expired URLs instead of persisting them.
class StreamResource {
  const StreamResource({required this.uri, this.headers = const {}});
  final Uri uri;
  final Map<String, String> headers;
}

abstract interface class StreamingSource {
  String get id;
  Future<List<StreamingTrack>> search(String query);
  Future<StreamResource?> resolve(StreamingTrack track);
}
