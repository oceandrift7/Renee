import 'dart:convert';

import 'package:http/http.dart' as http;

import 'streaming_source.dart';

/// Experimental direct-resource resolver for publicly playable YouTube videos.
///
/// This deliberately does not decode signature ciphers, obtain PO tokens,
/// bypass login/DRM, or download an entire track. YouTube can change or
/// restrict its private player API at any time. A null result means that no
/// directly playable resource was available through this limited path.
class YouTubeMusicDirectResolver {
  YouTubeMusicDirectResolver({
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 6),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;

  /// Do not use extremely compressed AAC tracks, even when buffering fails.
  /// Spotify-like smoothness should not come at the cost of 48 kbps playback.
  static const int minimumAudioBitrate = 96000;
  static const int preferredAudioBitrate = 128000;

  // Adapted from the public client declaration in Mornye-Extension.
  // Android VR does not normally require an external GVS PO token.
  static const _clientName = 'ANDROID_VR';
  static const _clientVersion = '1.65.10';
  static const _clientHeaderName = '28';
  static const _userAgent =
      'com.google.android.apps.youtube.vr.oculus/1.65.10 '
      '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';
  static const _key = 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w';

  Future<StreamResource?> resolve(String videoId) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) return null;
    final endpoint = Uri.https('www.youtube.com', '/youtubei/v1/player', {
      'key': _key,
      'prettyPrint': 'false',
    });
    final response = await _client
        .post(
          endpoint,
          headers: const {
            'Content-Type': 'application/json',
            'User-Agent': _userAgent,
            'Origin': 'https://www.youtube.com',
            'X-YouTube-Client-Name': _clientHeaderName,
            'X-YouTube-Client-Version': _clientVersion,
          },
          body: jsonEncode({
            'context': {
              'client': {
                'clientName': _clientName,
                'clientVersion': _clientVersion,
                'androidSdkVersion': 32,
                'hl': 'en',
                'gl': 'US',
                'osName': 'Android',
                'osVersion': '12L',
                'platform': 'MOBILE',
                'deviceMake': 'Oculus',
                'deviceModel': 'Quest 3',
              },
            },
            'videoId': videoId,
          }),
        )
        .timeout(requestTimeout);
    if (response.statusCode != 200) return null;
    final payload = jsonDecode(response.body);
    if (payload is! Map<String, dynamic>) return null;
    return resourceFromPlayerResponse(payload);
  }

  /// Pure parser: keeps media selection testable without live YouTube traffic.
  /// iOS AVPlayer reliably handles AAC in MP4/M4A, unlike WebM/Opus.
  static StreamResource? resourceFromPlayerResponse(
    Map<String, dynamic> playerResponse,
  ) {
    final status = playerResponse['playabilityStatus'];
    if (status is! Map || status['status'] != 'OK') return null;
    final data = playerResponse['streamingData'];
    if (data is! Map) return null;

    final formats = [
      if (data['adaptiveFormats'] is List) ...data['adaptiveFormats'] as List,
      if (data['formats'] is List) ...data['formats'] as List,
    ];
    final candidates = <({Uri url, int bitrate, int itag})>[];
    for (final item in formats) {
      if (item is! Map) continue;
      final mime = item['mimeType']?.toString().toLowerCase() ?? '';
      // Reject video, preview playlists and formats unsupported on iOS.
      if (!mime.startsWith('audio/mp4')) continue;
      final url = Uri.tryParse(item['url']?.toString() ?? '');
      if (url == null ||
          url.scheme != 'https' ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty ||
          !url.host.endsWith('.googlevideo.com')) {
        continue;
      }
      // Do not hand the player a signed URL that has already expired or
      // will expire before the initial buffer can be established.
      final expiresAt = int.tryParse(url.queryParameters['expire'] ?? '');
      if (expiresAt != null &&
          expiresAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30) {
        continue;
      }
      // A signatureCipher/cipher value without a direct URL isn't playable
      // unless a separate sanctioned resolver handles it.
      final bitrate =
          (item['averageBitrate'] as num?)?.toInt() ??
          (item['bitrate'] as num?)?.toInt() ??
          0;
      final itag = (item['itag'] as num?)?.toInt() ?? 0;
      // Itag 139 is typically 48 kbps AAC. Exclude it as both a primary
      // stream and a fallback; the user prefers quality over this extreme
      // compression. Missing bitrate metadata is treated as unknown, except
      // for well-known AAC itag 140 (typically 128 kbps).
      final effectiveBitrate =
          bitrate > 0 ? bitrate : (itag == 140 ? preferredAudioBitrate : 0);
      if (itag == 139 || effectiveBitrate < minimumAudioBitrate) continue;
      candidates.add((url: url, bitrate: effectiveBitrate, itag: itag));
    }
    if (candidates.isEmpty) return null;

    // Target approximately 128 kbps AAC for balanced startup and quality.
    // A faster source with higher bitrate can be selected if 128 is absent.
    candidates.sort((a, b) {
      final aDiff = (a.bitrate - preferredAudioBitrate).abs();
      final bDiff = (b.bitrate - preferredAudioBitrate).abs();
      final byPreference = aDiff.compareTo(bDiff);
      return byPreference != 0
          ? byPreference
          : a.bitrate.compareTo(b.bitrate);
    });

    // If the primary URL fails to prepare, allow one alternate AAC URL,
    // but NEVER drop below 96 kbps. Prefer the best lower bitrate; if none
    // exists, try an equal-bitrate alternative, not a more demanding format.
    // This is a startup fallback, not mid-song adaptive bitrate switching.
    final primary = candidates.first;
    final alternatives = candidates.where((c) => c.url != primary.url).toList();
    final lowerBitrate = alternatives
        .where((c) => c.bitrate < primary.bitrate)
        .toList()
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    final sameBitrate = alternatives
        .where((c) => c.bitrate == primary.bitrate)
        .toList();
    final backup = lowerBitrate.isNotEmpty
        ? lowerBitrate.first
        : (sameBitrate.isNotEmpty ? sameBitrate.first : null);

    // audioplayers_darwin currently ignores custom URL request headers.
    // Select only self-contained signed URLs; never rely on a header to make
    // the resource playable on iOS.
    return StreamResource(
      uri: primary.url,
      fallbackUris: backup == null ? const [] : [backup.url],
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
