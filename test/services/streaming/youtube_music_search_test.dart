import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/youtube_music_search.dart';

void main() {
  test('parses artist and duration without mixing in album or year', () {
    final payload = {
      'contents': [
        {
          'musicResponsiveListItemRenderer': {
            'playlistItemData': {'videoId': 'abcdefghijk'},
            'flexColumns': [
              {
                'musicResponsiveListItemFlexColumnRenderer': {
                  'text': {
                    'runs': [
                      {'text': 'A Song'},
                    ],
                  },
                },
              },
              {
                'musicResponsiveListItemFlexColumnRenderer': {
                  'text': {
                    'runs': [
                      {'text': 'Song'},
                      {'text': ' • '},
                      {'text': 'An Artist'},
                      {'text': ' • '},
                      {'text': 'Greatest Hits'},
                      {'text': ' • '},
                      {'text': '3:30'},
                    ],
                  },
                },
              },
            ],
          },
        },
      ],
    };
    final found = YouTubeMusicSearch.parseResults(payload);
    expect(found, hasLength(1));
    expect(found.single.id, 'abcdefghijk');
    expect(found.single.title, 'A Song');
    expect(found.single.artist, 'An Artist');
    expect(found.single.duration, const Duration(seconds: 210));
  });

  test('ignores collections without playable video IDs', () {
    final result = YouTubeMusicSearch.parseResults({
      'musicResponsiveListItemRenderer': {
        'playlistItemData': {'videoId': 'MPREb12345'},
        'flexColumns': <Object>[],
      },
    });
    expect(result, isEmpty);
  });
}
