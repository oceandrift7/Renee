import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/streaming/renee_online_playback.dart';

void main() {
  test('new Play tap supersedes older asynchronous lookup', () {
    final first = ReneeOnlinePlayback.beginRequest();
    expect(ReneeOnlinePlayback.isCurrentRequest(first), isTrue);
    final second = ReneeOnlinePlayback.beginRequest();
    expect(ReneeOnlinePlayback.isCurrentRequest(first), isFalse);
    expect(ReneeOnlinePlayback.isCurrentRequest(second), isTrue);
  });

  test('local playback action invalidates in-flight online request', () {
    final pending = ReneeOnlinePlayback.beginRequest();
    ReneeOnlinePlayback.cancelPending();
    expect(ReneeOnlinePlayback.isCurrentRequest(pending), isFalse);
  });
}
