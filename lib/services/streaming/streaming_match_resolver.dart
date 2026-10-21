import 'manual_match_store.dart';
import 'streaming_source.dart';
import 'track_matcher.dart';

/// Connects a Mornye catalog track and its saved manual YouTube Music match
/// to the live streaming source search. Never invents playable URLs.
class StreamingMatchResolver {
  const StreamingMatchResolver({
    this.matcher = const TrackMatcher(),
    this.manualMatches,
  });

  final TrackMatcher matcher;
  final ManualMatchStore? manualMatches;

  Future<StreamingTrack?> find(
    StreamingSource source,
    CatalogTrack catalog,
  ) async {
    final override = source.id == 'youtube_music'
        ? manualMatches?.getOverride(catalog)
        : null;
    if (override != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(override)) {
      // Only a user explicitly choosing a YouTube video can bypass automatic
      // ranking. Use catalog metadata while the provider resolves the ID.
      return StreamingTrack(
        id: override,
        title: catalog.title,
        artist: catalog.artist,
        duration: catalog.duration,
      );
    }

    final query = '${catalog.title} ${catalog.artist}'.trim();
    if (query.isEmpty) return null;
    final candidates = await source.search(query);
    final filtered = candidates.where((candidate) {
      // Never silently substitute a live performance, cover, remix or
      // instrumental for a different recording.
      final wanted = _editionTags(catalog.title);
      final found = _editionTags(candidate.title);
      if (!wanted.containsAll(found) || !found.containsAll(wanted)) {
        return false;
      }
      if (catalog.duration != null && candidate.duration != null) {
        final delta =
            (catalog.duration!.inSeconds - candidate.duration!.inSeconds).abs();
        if (delta > 12) return false;
      }
      return true;
    });
    return matcher.confidentMatch(catalog, filtered)?.track;
  }

  Set<String> _editionTags(String title) {
    final normalized = title.toLowerCase();
    return {
      for (final word in const [
        'live',
        'remix',
        'cover',
        'instrumental',
        'acoustic',
        'karaoke',
        'sped up',
        'slowed',
        'nightcore',
      ])
        if (RegExp(
          r'(^|[^a-z])' + RegExp.escape(word) + r'([^a-z]|$)',
        ).hasMatch(normalized))
          word,
    };
  }
}
