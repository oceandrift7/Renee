import 'dart:convert';

import 'package:http/http.dart' as http;

import 'streaming_source.dart';

/// Unofficial YouTube Music search endpoint. Its response format can change.
/// This adapter searches catalog entries only; it does not resolve audio URLs.
class YouTubeMusicSearch {
  YouTubeMusicSearch({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<List<StreamingTrack>> search(String query) async {
    if (query.trim().isEmpty) return const [];
    final response = await _client.post(
      Uri.parse('https://music.youtube.com/youtubei/v1/search?prettyPrint=false'),
      headers: const {
        'content-type': 'application/json',
        'origin': 'https://music.youtube.com',
        'user-agent': 'Mozilla/5.0',
      },
      body: jsonEncode({
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20250101.01.00',
            'hl': 'en',
            'gl': 'US',
          },
        },
        'query': query,
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('YouTube Music search failed (${response.statusCode})');
    }
    final decoded = jsonDecode(response.body);
    final tracks = <StreamingTrack>[];
    final seen = <String>{};

    void visit(dynamic value) {
      if (value is List) {
        for (final item in value) { visit(item); }
        return;
      }
      if (value is! Map) return;
      final renderer = value['musicResponsiveListItemRenderer'];
      if (renderer is Map) {
        final data = Map<String, dynamic>.from(renderer);
        final nav = data['playlistItemData'];
        final id = nav is Map ? nav['videoId'] : null;
        if (id is String && id.isNotEmpty && seen.add(id)) {
          final flex = data['flexColumns'];
          final columns = flex is List ? flex : const [];
          String column(int index) {
            if (index >= columns.length) return '';
            final item = columns[index];
            if (item is! Map) return '';
            final r = item['musicResponsiveListItemFlexColumnRenderer'];
            if (r is! Map) return '';
            final text = r['text'];
            if (text is! Map) return '';
            final runs = text['runs'];
            if (runs is! List) return '';
            return runs.whereType<Map>().map((run) => run['text']?.toString() ?? '').join('');
          }
          final title = column(0);
          final detail = column(1);
          if (title.isNotEmpty) {
            tracks.add(StreamingTrack(id: id, title: title, artist: detail));
          }
        }
      }
      for (final nested in value.values) { visit(nested); }
    }

    visit(decoded);
    return tracks;
  }

  void close() => _client.close();
}
