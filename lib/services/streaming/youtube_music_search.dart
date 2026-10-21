import 'dart:convert';

import 'package:http/http.dart' as http;

import 'streaming_source.dart';

/// Experimental catalog search, not an audio-playback API.
class YouTubeMusicSearch {
  YouTubeMusicSearch({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;
  final http.Client _client;
  final bool _ownsClient;

  Future<List<StreamingTrack>> search(String query) async {
    if (query.trim().isEmpty) return const [];
    final response = await _client
        .post(
          Uri.parse(
            'https://music.youtube.com/youtubei/v1/search?prettyPrint=false',
          ),
          headers: const {
            'content-type': 'application/json',
            'origin': 'https://music.youtube.com',
            'user-agent': 'Mozilla/5.0',
          },
          body: jsonEncode({
            'context': {
              'client': {
                'clientName': 'WEB_REMIX',
                'clientVersion': '1.20240801.01.00',
                'hl': 'en',
                'gl': 'US',
              },
            },
            'query': query,
          }),
        )
        .timeout(const Duration(seconds: 6));
    if (response.statusCode != 200) {
      throw StateError('YouTube Music search failed (${response.statusCode})');
    }
    final payload = jsonDecode(response.body);
    return parseResults(payload);
  }

  /// Parses only song/video rows carrying a videoId, not album/playlist rows.
  /// Keeps artist distinct from album/year/duration for reliable matching.
  static List<StreamingTrack> parseResults(dynamic payload) {
    final tracks = <StreamingTrack>[];
    final seen = <String>{};

    void visit(dynamic node) {
      if (node is List) {
        for (final child in node) {
          visit(child);
        }
        return;
      }
      if (node is! Map) return;
      final renderer = node['musicResponsiveListItemRenderer'];
      if (renderer is Map) {
        final data = renderer;
        final nav = data['playlistItemData'];
        final id = nav is Map ? nav['videoId']?.toString() : null;
        if (id != null &&
            RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) &&
            seen.add(id)) {
          List<dynamic> runsAt(int index) {
            final columns = data['flexColumns'];
            if (columns is! List || index >= columns.length) return const [];
            final column = columns[index];
            if (column is! Map) return const [];
            final text = column['musicResponsiveListItemFlexColumnRenderer'];
            if (text is! Map) return const [];
            final body = text['text'];
            return body is Map && body['runs'] is List
                ? body['runs'] as List
                : const [];
          }

          final titleRuns = runsAt(0);
          final metaRuns = runsAt(1);
          final title = titleRuns.isNotEmpty && titleRuns.first is Map
              ? (titleRuns.first as Map)['text']?.toString().trim() ?? ''
              : '';
          final artistParts = <String>[];
          Duration? duration;
          for (final item in metaRuns) {
            if (item is! Map) continue;
            final text = item['text']?.toString().trim() ?? '';
            if (text.isEmpty) continue;
            final parts = text.split(':');
            if (parts.length >= 2 &&
                parts.length <= 3 &&
                parts.every((part) => int.tryParse(part) != null)) {
              var seconds = 0;
              for (final part in parts) {
                seconds = seconds * 60 + int.parse(part);
              }
              duration = Duration(seconds: seconds);
              continue;
            }
            if (text.contains('•')) {
              // The first unlabelled run is usually the artist. Later runs
              // represent album, media type or year, not additional artists.
              continue;
            }
            if (const {
              'Song',
              'Album',
              'Video',
              'Single',
              'EP',
              'Playlist',
            }.contains(text)) {
              continue;
            }
            if (RegExp(r'^\d{4}$').hasMatch(text)) continue;
            final nav = item['navigationEndpoint'];
            final browse = nav is Map ? nav['browseEndpoint'] : null;
            final browseId = browse is Map
                ? browse['browseId']?.toString()
                : null;
            if (browseId != null && browseId.startsWith('UC')) {
              artistParts.add(text);
            } else if (artistParts.isEmpty) {
              artistParts.add(text);
            }
          }
          final artwork = data['thumbnail'];
          final musicThumb = artwork is Map
              ? artwork['musicThumbnailRenderer']
              : null;
          final thumb = musicThumb is Map ? musicThumb['thumbnail'] : null;
          final imgs = thumb is Map ? thumb['thumbnails'] : null;
          final coverUrl = imgs is List && imgs.isNotEmpty && imgs.last is Map
              ? Uri.tryParse((imgs.last as Map)['url']?.toString() ?? '')
              : null;
          if (title.isNotEmpty && artistParts.isNotEmpty) {
            tracks.add(
              StreamingTrack(
                id: id,
                title: title,
                artist: artistParts.join(', '),
                duration: duration,
                artworkUrl: coverUrl,
              ),
            );
          }
        }
      }
      for (final child in node.values) {
        visit(child);
      }
    }

    visit(payload);
    return tracks;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
