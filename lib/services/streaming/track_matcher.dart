import 'dart:math' as math;

import 'streaming_source.dart';

/// Metadata from the user's selected Mornye catalog extension.
class CatalogTrack {
  const CatalogTrack({
    required this.provider,
    required this.id,
    required this.title,
    required this.artist,
    this.duration,
    this.isrc,
  });

  final String provider;
  final String id;
  final String title;
  final String artist;
  final Duration? duration;
  final String? isrc;

  String get storageKey => '${Uri.encodeComponent(provider)}:${Uri.encodeComponent(id)}';
}

class RankedMatch {
  const RankedMatch(this.track, this.score);
  final StreamingTrack track;
  final double score;
}

/// Deterministic metadata-based ranking; does not resolve playable audio.
class TrackMatcher {
  const TrackMatcher();

  List<RankedMatch> rank(CatalogTrack catalog, Iterable<StreamingTrack> candidates) {
    final ranked = candidates.map((candidate) {
      final title = _similarity(catalog.title, candidate.title);
      final artist = _similarity(catalog.artist, candidate.artist);
      final duration = _durationScore(catalog.duration, candidate.duration);
      final score = 0.55 * title + 0.35 * artist + 0.10 * duration;
      return RankedMatch(candidate, score.clamp(0.0, 1.0).toDouble());
    }).toList();
    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked;
  }

  /// Deliberately conservative: uncertain matches should be shown to the user.
  RankedMatch? confidentMatch(CatalogTrack catalog, Iterable<StreamingTrack> candidates) {
    final results = rank(catalog, candidates);
    if (results.isEmpty || results.first.score < 0.88) return null;
    if (results.length > 1 && results.first.score - results[1].score < 0.08) return null;
    return results.first;
  }

  static double _durationScore(Duration? a, Duration? b) {
    if (a == null || b == null) return 0.5;
    final seconds = (a.inSeconds - b.inSeconds).abs();
    return (1.0 - seconds / 30.0).clamp(0.0, 1.0).toDouble();
  }

  static String _normalize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  static double _similarity(String a, String b) {
    final left = _normalize(a), right = _normalize(b);
    if (left == right && left.isNotEmpty) return 1;
    if (left.isEmpty || right.isEmpty) return 0;
    final l = left.split(' ').toSet(), r = right.split(' ').toSet();
    return l.intersection(r).length / math.max(l.union(r).length, 1);
  }
}
