import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/playable_media.dart';

void main() {
  test('network stream headers stay in memory and are never persisted', () {
    const item = PlayableMedia(
      id: 'stream:yt:video',
      source: 'https://cdn.example.org/audio.m4a',
      title: 'Test',
      artist: 'Artist',
      networkHeaders: {
        'Authorization': 'Bearer session-secret',
        'Referer': 'https://music.example.org/',
      },
    );
    expect(item.isNetwork, isTrue);
    expect(item.networkHeaders['Authorization'], 'Bearer session-secret');

    final json = item.toJson();
    expect(json.containsKey('networkHeaders'), isFalse);
    expect(json.toString(), isNot(contains('session-secret')));
    expect(json.toString(), isNot(contains('cdn.example.org')));

    final restored = PlayableMedia.fromJson(json);
    expect(restored, isNull, reason: 'Expired signed stream URLs must be re-resolved');
  });
}
