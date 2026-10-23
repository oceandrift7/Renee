import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/network_storage_service.dart';

/// Native iOS transport smoke test, not a YouTube Music entitlement test.
///
/// A real AVPlayer instance reads a WAV file through a throttled HTTP range
/// server. The fixture is intentionally silent; no copyrighted music or
/// provider credentials are needed to test streaming/seek/pause/resume.
/// Run on an iOS simulator or physical test device (not the host Dart VM).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Renée iOS native stream survives constrained HTTP playback',
      (tester) async {
    // 60 seconds of silent, uncompressed mono audio at 128 kbit/s.
    // Larger than initial buffers so we can check playback before full transfer.
    const sampleRate = 8000;
    const durationSeconds = 60;
    final wav = Uint8List(44 + sampleRate * 2 * durationSeconds);
    final header = ByteData.sublistView(wav);
    wav.setRange(0, 4, 'RIFF'.codeUnits);
    header.setUint32(4, wav.length - 8, Endian.little);
    wav.setRange(8, 16, 'WAVEfmt '.codeUnits);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    wav.setRange(36, 40, 'data'.codeUnits);
    header.setUint32(40, wav.length - 44, Endian.little);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var servedBytes = 0;
    var requests = 0;
    server.listen((request) async {
      requests++;
      final headerValue = request.headers.value('range');
      final range = networkByteRange(headerValue, wav.length);
      final response = request.response;
      response.statusCode = headerValue == null
          ? HttpStatus.ok
          : HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentTypeHeader, 'audio/wav');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (headerValue != null) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/${wav.length}',
        );
      }
      response.contentLength = range.end - range.start + 1;
      try {
        if (request.method != 'HEAD') {
          for (var offset = range.start; offset <= range.end; offset += 2048) {
            final end = offset + 2048 < range.end + 1
                ? offset + 2048
                : range.end + 1;
            final bytes = wav.sublist(offset, end);
            response.add(bytes);
            await response.flush();
            servedBytes += bytes.length;
            // About 234 kbit/s per connection: constrained, but enough for
            // this 128 kbit/s transport fixture with some buffer headroom.
            await Future<void>.delayed(const Duration(milliseconds: 70));
          }
        }
        await response.close();
      } catch (_) {
        // AVPlayer may close a range request and open another while seeking.
      }
    });

    final deck = MusicPlaybackDeck(playerId: 'renee-slow-stream-smoke');
    try {
      final url = 'http://127.0.0.1:${server.port}/slow.wav';
      final startup = Stopwatch()..start();
      await deck.setNetworkSource(url).timeout(const Duration(seconds: 25));
      await deck.resume();
      // Observe actual native position advancement, not only successful URL
      // resolution or the Dart player state.
      Future<Duration> awaitPositionAbove(Duration target) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline)) {
          final position = await deck.getCurrentPosition() ?? Duration.zero;
          if (position > target) return position;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        fail('Native playback never advanced beyond ${target.inMilliseconds} ms');
      }

      final advanced = await awaitPositionAbove(
        const Duration(milliseconds: 700),
      );
      startup.stop();
      // Diagnostic data for the GitHub Actions job and physical tests.
      // This is not a strict latency SLA across simulator host machines.
      // ignore: avoid_print
      print('RENEE_STREAM_SMOKE startupMs=${startup.elapsedMilliseconds} '
          'positionMs=${advanced.inMilliseconds} '
          'bytesServed=$servedBytes requests=$requests');
      expect(requests, greaterThan(0));
      expect(servedBytes, greaterThan(0));
      expect(servedBytes, lessThan(wav.length),
          reason: 'Playback must begin without fetching the entire file');

      await deck.pause();
      final pausedAt = await deck.getCurrentPosition() ?? Duration.zero;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final stillPaused = await deck.getCurrentPosition() ?? Duration.zero;
      expect((stillPaused - pausedAt).inMilliseconds.abs(), lessThan(700));

      await deck.resume();
      await awaitPositionAbove(pausedAt + const Duration(milliseconds: 300));

      await deck.seek(const Duration(seconds: 12));
      final sought = await deck.getCurrentPosition() ?? Duration.zero;
      expect(sought.inSeconds, greaterThanOrEqualTo(11));
    } finally {
      await deck.dispose();
      await server.close(force: true);
    }
  });
}
