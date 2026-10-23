import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'streaming_playback_issue.dart';
import 'youtube_music_signed_session.dart';
import 'streaming_source.dart';

/// Public, unauthenticated YouTube client profiles for experimental playback.
/// Each response must independently provide a signed AAC URL; we deliberately
/// do not parse signature ciphers, obtain PO tokens, or use account cookies.
///
/// Profile fallback and visitor-context handling are adapted architecturally
/// from the user's Brassplay project, independently implemented in Dart.
/// These unofficial endpoints may stop working without warning.
class YouTubePlayerProfile {
  const YouTubePlayerProfile({
    required this.name,
    required this.version,
    required this.headerId,
    required this.userAgent,
    this.contextExtras = const {},
    this.host = 'www.youtube.com',
    this.embedUrl,
    this.mediaNeedsUserAgent = false,
  });

  final String name;
  final String version;
  final String headerId;
  final String userAgent;
  final Map<String, Object> contextExtras;
  final String host;

  /// Required by the anonymous embedded player client as thirdParty.embedUrl.
  final String? embedUrl;

  /// Googlevideo requires the same client identity on the media request.
  final bool mediaNeedsUserAgent;

  Map<String, Object> context({String? visitorData}) {
    final value = <String, Object>{
      'clientName': name,
      'clientVersion': version,
      'userAgent': userAgent,
      'hl': 'en',
      'gl': 'US',
      ...contextExtras,
    };
    if (visitorData != null) value['visitorData'] = visitorData;
    return value;
  }
}

/// Attempts full-track progressive AAC from a small collection of public
/// YouTube client profiles. Search and catalog metadata remain independent.
///
/// A returned resource is not proof of successful AVPlayer preparation.
/// Only HTTPS signed googlevideo.com URLs are returned to the native player.
class YouTubeMusicDirectResolver {
  YouTubeMusicDirectResolver({
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 5),
    this.visitorTimeout = const Duration(seconds: 3),
    this.probeTimeout = const Duration(seconds: 4),
    List<YouTubePlayerProfile>? profiles,
    this.signedInSession,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _profiles = profiles ?? defaultProfiles;

  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;
  final Duration visitorTimeout;
  final Duration probeTimeout;
  final List<YouTubePlayerProfile> _profiles;
  final YouTubeMusicSignedSession? signedInSession;
  // Only verified media refusals are cached, not LOGIN_REQUIRED or timeouts.
  final Map<String, DateTime> _mediaRefusals = {};
  static const mediaRefusalCooldown = Duration(minutes: 10);

  static const int minimumAudioBitrate = 96000;
  static const int preferredAudioBitrate = 128000;
  static const _key = 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w';

  /// Anonymous client fallbacks. VisionOS is first; Android VR can return
  /// LOGIN_REQUIRED or HTTP 403. The final embedded profile is useful only
  /// for embeddable recordings and may still require cipher/PO-token work.
  /// Never mistake an 'OK' playability status for verified media access.
  static const List<YouTubePlayerProfile> defaultProfiles = [
    YouTubePlayerProfile(
      name: 'VISIONOS',
      version: '1.02',
      headerId: '101',
      userAgent:
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) '
          'Version/26.0 Safari/605.1.15',
      contextExtras: {
        'deviceMake': 'Apple',
        'deviceModel': 'RealityDevice17,1',
        'osName': 'visionOS',
        'osVersion': '26.5.23O471',
      },
    ),
    YouTubePlayerProfile(
      name: 'ANDROID_VR',
      version: '1.65.10',
      headerId: '28',
      mediaNeedsUserAgent: true,
      userAgent:
          'com.google.android.apps.youtube.vr.oculus/1.65.10 '
          '(Linux; U; Android 12L; eureka-user '
          'Build/SQ3A.220605.009.A1) gzip',
      contextExtras: {
        'deviceMake': 'Oculus',
        'deviceModel': 'Quest 3',
        'osName': 'Android',
        'osVersion': '12L',
        'androidSdkVersion': 32,
        'platform': 'MOBILE',
      },
    ),
    YouTubePlayerProfile(
      name: 'ANDROID_VR',
      version: '1.60.19',
      headerId: '28',
      mediaNeedsUserAgent: true,
      userAgent:
          'com.google.android.apps.youtube.vr.oculus/1.60.19 '
          '(Linux; U; Android 12L; eureka-user '
          'Build/SQ3A.220605.009.A1) gzip',
      contextExtras: {
        'deviceMake': 'Oculus',
        'deviceModel': 'Quest 3',
        'osName': 'Android',
        'osVersion': '12L',
        'androidSdkVersion': 32,
        'platform': 'MOBILE',
      },
    ),
    YouTubePlayerProfile(
      name: 'WEB_EMBEDDED_PLAYER',
      version: '2.20260708.00.00',
      headerId: '56',
      userAgent:
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) '
          'Version/15.5 Safari/605.1.15,gzip(gfe)',
      embedUrl: 'https://www.youtube.com/',
    ),
  ];

  // Anonymous visitor IDs are reused across new resolver instances (one is
  // created per Play tap). Refetching for every song triggers needless
  // requests; missing visitor data causes many player profiles to reject
  // otherwise publicly playable tracks with LOGIN_REQUIRED.
  static String? _sharedVisitor;
  static DateTime? _sharedVisitorExpiresAt;
  static DateTime? _retryVisitorAfter;
  static Future<String?>? _visitorRequest;

  /// Anonymous homepage visitor ID, not an account cookie or login token.
  /// Mock clients stay isolated from production's static session cache.
  Future<String?> _visitorData() async {
    if (!_ownsClient) return _fetchVisitorData();
    final now = DateTime.now();
    if (_sharedVisitor != null &&
        _sharedVisitorExpiresAt != null &&
        now.isBefore(_sharedVisitorExpiresAt!)) {
      return _sharedVisitor;
    }
    final inFlight = _visitorRequest;
    if (inFlight != null) return inFlight;
    if (_retryVisitorAfter != null && now.isBefore(_retryVisitorAfter!)) {
      return null;
    }
    final request = _fetchVisitorData();
    _visitorRequest = request;
    try {
      final visitor = await request;
      if (visitor != null) {
        _sharedVisitor = visitor;
        _sharedVisitorExpiresAt = DateTime.now().add(
          const Duration(minutes: 45),
        );
        _retryVisitorAfter = null;
      } else {
        _retryVisitorAfter = DateTime.now().add(const Duration(seconds: 30));
      }
      return visitor;
    } finally {
      if (identical(_visitorRequest, request)) _visitorRequest = null;
    }
  }

  /// Real YouTube visitor values can exceed 256 characters and include
  /// JavaScript-escaped '=' or '/' characters. Never log the raw visitor.
  static String? visitorFromHomepage(String body) {
    final match = RegExp(
      r'"(?:visitorData|VISITOR_DATA|EOM_VISITOR_DATA)"\s*:\s*"((?:\\.|[^"\\]){8,4096})"',
    ).firstMatch(body);
    if (match == null) return null;
    final jsEscaped = match.group(1)!;
    // \xNN is valid JavaScript string syntax, not a JSON escape. Convert
    // before letting the JSON decoder handle \u003d and escaped slashes.
    final normalized = jsEscaped.replaceAllMapped(
      RegExp(r'\\x([0-9a-fA-F]{2})'),
      (match) => r'\u00' + match.group(1)!,
    );
    try {
      final decoded = jsonDecode('"$normalized"');
      if (decoded is String &&
          RegExp(r'^[A-Za-z0-9+/_=%-]{8,4096}$').hasMatch(decoded)) {
        return decoded;
      }
    } catch (_) {
      // Consent pages or non-JSON JavaScript strings are not visitor IDs.
    }
    return null;
  }

  /// Music homepage uses the same anonymous visitor session as its player
  /// API. Try the regular YouTube homepage only if the music page is blocked
  /// or returns no visitor. Every request is individually time-bounded.
  Future<String?> _fetchVisitorData() async {
    for (final origin in [
      'https://music.youtube.com/',
      'https://www.youtube.com/',
    ]) {
      try {
        final response = await _client
            .get(
              Uri.parse(origin),
              headers: {'User-Agent': _profiles.first.userAgent},
            )
            .timeout(visitorTimeout);
        if (response.statusCode != 200) continue;
        final visitor = visitorFromHomepage(response.body);
        if (visitor != null) return visitor;
      } catch (_) {
        // Keep progressing through profiles without returning a bogus ID.
      }
    }
    return null;
  }

  /// Check a small byte range before handing any signed URL to AVPlayer.
  /// No complete song is downloaded, and signed URLs never enter diagnostics.
  Future<String?> _probeMedia(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    try {
      final request = http.Request('GET', url)
        ..followRedirects = false
        ..headers.addAll(headers)
        ..headers['Range'] = 'bytes=0-16383';
      final response = await _client.send(request).timeout(probeTimeout);
      if (response.statusCode != 200 && response.statusCode != 206) {
        return 'MEDIA_HTTP_${response.statusCode}';
      }
      final contentType = (response.headers['content-type'] ?? '')
          .split(';')
          .first
          .trim()
          .toLowerCase();
      if (contentType.isNotEmpty &&
          !contentType.startsWith('audio/') &&
          !contentType.startsWith('video/') &&
          contentType != 'application/octet-stream') {
        return 'MEDIA_TYPE';
      }
      final chunk = await response.stream.first.timeout(probeTimeout);
      if (chunk.isEmpty) return 'MEDIA_EMPTY';
      final prefix = ascii
          .decode(chunk.take(96).toList(), allowInvalid: true)
          .trimLeft()
          .toLowerCase();
      if (prefix.startsWith('<!doctype html') ||
          prefix.startsWith('<html') ||
          prefix.startsWith('<?xml')) {
        return 'MEDIA_CHALLENGE';
      }
      return null;
    } on TimeoutException {
      return 'MEDIA_TIMEOUT';
    } on SocketException {
      return 'MEDIA_NETWORK';
    } on http.ClientException {
      return 'MEDIA_NETWORK';
    } on StateError {
      return 'MEDIA_EMPTY';
    } catch (_) {
      return 'MEDIA_ERROR';
    }
  }

  /// First ask the browser-authenticated YouTube Music player, using only an
  /// explicitly provided, signed-in session. A session's cookies and hash
  /// MUST go only to music.youtube.com, never to any alternate host.
  /// A LOGIN_REQUIRED response still denotes a provider refusal, not proof
  /// the session is invalid or a prompt to retry indefinitely.
  Future<StreamResource?> _resolveSignedIn(String videoId) async {
    final session = signedInSession;
    if (session == null) return null;
    final headers = session.headers();
    if (headers == null) return null;
    try {
      final response = await _client
          .post(
            Uri.https('music.youtube.com', '/youtubei/v1/player', {
              'key': session.apiKey ?? _key,
              'prettyPrint': 'false',
            }),
            headers: headers,
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB_REMIX',
                  'clientVersion': session.clientVersion,
                  'hl': 'en',
                  'gl': 'US',
                  if (session.visitorData != null)
                    'visitorData': session.visitorData,
                },
                if (session.delegatedSessionId != null)
                  'user': {'onBehalfOfUser': session.delegatedSessionId},
              },
              'videoId': videoId,
              'contentCheckOk': true,
              'racyCheckOk': true,
            }),
          )
          .timeout(requestTimeout);
      if (response.statusCode != 200) return null;
      final parsed = jsonDecode(response.body);
      if (parsed is! Map<String, dynamic>) return null;
      final picked = resourceFromPlayerResponse(parsed);
      if (picked == null) return null;
      // Browser web-player streams may require matching browser User-Agent
      // and Origin/Referer headers on subsequent byte-range media requests.
      // Never forward signing cookies or Authorization to Googlevideo.
      final mediaHeaders = <String, String>{
        'User-Agent': headers['User-Agent']!,
        'Referer': '${YouTubeMusicSignedSession.origin}/',
      };
      for (final uri in [picked.uri, ...picked.fallbackUris]) {
        if (await _probeMedia(uri, headers: mediaHeaders) == null) {
          return StreamResource(uri: uri, headers: mediaHeaders);
        }
      }
    } catch (_) {
      // Do not print headers, tokens, cookies or signed URLs.
    }
    return null;
  }

  /// onIssue fires only if ALL configured clients fail; a successful fallback
  /// must not leave a stale LOGIN_REQUIRED issue in the UI.
  Future<StreamResource?> resolve(
    String videoId, {
    void Function(StreamingPlaybackIssue)? onIssue,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) {
      onIssue?.call(
        const StreamingPlaybackIssue(StreamingPlaybackIssueCode.invalidVideoId),
      );
      return null;
    }
    if (_profiles.isEmpty) {
      onIssue?.call(
        const StreamingPlaybackIssue(
          StreamingPlaybackIssueCode.noAudioResource,
        ),
      );
      return null;
    }

    final signed = await _resolveSignedIn(videoId);
    if (signed != null) return signed;

    final visitor = await _visitorData();
    final attempts = <String>[];
    StreamingPlaybackIssue? mostUsefulIssue;
    void record(
      YouTubePlayerProfile profile,
      StreamingPlaybackIssue issue,
      String outcome,
    ) {
      // Profile and outcome come only from predefined names and sanitized
      // status tokens. Never record exception text, JSON reasons, or URLs.
      final safeProfile = profile.name.replaceAll(RegExp(r'[^A-Z_]'), '');
      attempts.add('$safeProfile:$outcome');
      final priority = switch (issue.code) {
        StreamingPlaybackIssueCode.youtubeUnsupportedAudio => 5,
        StreamingPlaybackIssueCode.youtubeRestricted => 4,
        StreamingPlaybackIssueCode.noAudioResource => 3,
        StreamingPlaybackIssueCode.youtubeHttpFailure => 2,
        _ => 1,
      };
      final previousPriority = switch (mostUsefulIssue?.code) {
        StreamingPlaybackIssueCode.youtubeUnsupportedAudio => 5,
        StreamingPlaybackIssueCode.youtubeRestricted => 4,
        StreamingPlaybackIssueCode.noAudioResource => 3,
        StreamingPlaybackIssueCode.youtubeHttpFailure => 2,
        _ => 0,
      };
      if (priority > previousPriority) mostUsefulIssue = issue;
    }

    for (
      var profileIndex = 0;
      profileIndex < _profiles.length;
      profileIndex++
    ) {
      final profile = _profiles[profileIndex];
      final refusalKey = '$videoId:$profileIndex';
      final refusedAt = _mediaRefusals[refusalKey];
      if (refusedAt != null) {
        if (DateTime.now().difference(refusedAt) < mediaRefusalCooldown) {
          attempts.add('${profile.name}:MEDIA_COOLDOWN');
          continue;
        }
        _mediaRefusals.remove(refusalKey);
      }
      final endpoint = Uri.https(profile.host, '/youtubei/v1/player', {
        'key': _key,
        'prettyPrint': 'false',
      });
      try {
        final headers = <String, String>{
          'Content-Type': 'application/json',
          'User-Agent': profile.userAgent,
          'Origin': 'https://${profile.host}',
          'X-YouTube-Client-Name': profile.headerId,
          'X-YouTube-Client-Version': profile.version,
        };
        if (visitor != null) headers['X-Goog-Visitor-Id'] = visitor;
        if (profile.embedUrl != null) {
          headers['Referer'] = profile.embedUrl!;
        }
        final response = await _client
            .post(
              endpoint,
              headers: headers,
              body: jsonEncode({
                'context': {
                  'client': profile.context(visitorData: visitor),
                  if (profile.embedUrl != null)
                    'thirdParty': {'embedUrl': profile.embedUrl},
                },
                'videoId': videoId,
              }),
            )
            .timeout(requestTimeout);

        if (response.statusCode != 200) {
          record(
            profile,
            StreamingPlaybackIssue(
              StreamingPlaybackIssueCode.youtubeHttpFailure,
              httpStatus: response.statusCode,
            ),
            'HTTP_${response.statusCode}',
          );
          continue;
        }
        final dynamic decoded;
        try {
          decoded = jsonDecode(response.body);
        } on FormatException {
          record(
            profile,
            const StreamingPlaybackIssue(
              StreamingPlaybackIssueCode.youtubeInvalidResponse,
            ),
            'INVALID_JSON',
          );
          continue;
        }
        if (decoded is! Map<String, dynamic>) {
          record(
            profile,
            const StreamingPlaybackIssue(
              StreamingPlaybackIssueCode.youtubeInvalidResponse,
            ),
            'INVALID_JSON',
          );
          continue;
        }
        final playability = decoded['playabilityStatus'];
        if (playability is! Map || playability['status'] != 'OK') {
          final raw = playability is Map ? playability['status'] : null;
          final status =
              raw is String && RegExp(r'^[A-Z_]{1,40}$').hasMatch(raw)
              ? raw
              : 'UNKNOWN';
          record(
            profile,
            StreamingPlaybackIssue(
              StreamingPlaybackIssueCode.youtubeRestricted,
              youtubeStatus: status,
            ),
            status,
          );
          continue;
        }
        final resource = resourceFromPlayerResponse(decoded);
        if (resource != null) {
          // If Googlevideo refuses one client, try its AAC backup and then
          // a different player-client profile rather than failing playback.
          final urls = [resource.uri, ...resource.fallbackUris];
          final mediaHeaders = profile.mediaNeedsUserAgent
              ? <String, String>{'User-Agent': profile.userAgent}
              : const <String, String>{};
          String? lastFailure;
          for (final url in urls) {
            final refusal = await _probeMedia(url, headers: mediaHeaders);
            if (refusal != null) {
              lastFailure = refusal;
              continue;
            }
            _mediaRefusals.remove(refusalKey);
            return StreamResource(uri: url, headers: mediaHeaders);
          }
          if (lastFailure != 'MEDIA_TIMEOUT' &&
              lastFailure != 'MEDIA_NETWORK' &&
              lastFailure != 'MEDIA_ERROR') {
            _mediaRefusals[refusalKey] = DateTime.now();
          }
          record(
            profile,
            const StreamingPlaybackIssue(
              StreamingPlaybackIssueCode.noAudioResource,
            ),
            lastFailure ?? 'MEDIA_REJECTED',
          );
          continue;
        }
        final data = decoded['streamingData'];
        final hasFormats =
            data is Map &&
            ((data['adaptiveFormats'] is List &&
                    (data['adaptiveFormats'] as List).isNotEmpty) ||
                (data['formats'] is List &&
                    (data['formats'] as List).isNotEmpty));
        final issue = StreamingPlaybackIssue(
          hasFormats
              ? StreamingPlaybackIssueCode.youtubeUnsupportedAudio
              : StreamingPlaybackIssueCode.noAudioResource,
        );
        record(profile, issue, hasFormats ? 'NO_AAC' : 'NO_AUDIO');
      } on TimeoutException {
        record(
          profile,
          const StreamingPlaybackIssue(
            StreamingPlaybackIssueCode.youtubeTimeout,
          ),
          'TIMEOUT',
        );
      } on SocketException {
        record(
          profile,
          const StreamingPlaybackIssue(
            StreamingPlaybackIssueCode.youtubeNetworkFailure,
          ),
          'NETWORK',
        );
      } on http.ClientException {
        record(
          profile,
          const StreamingPlaybackIssue(
            StreamingPlaybackIssueCode.youtubeNetworkFailure,
          ),
          'NETWORK',
        );
      } catch (_) {
        record(
          profile,
          const StreamingPlaybackIssue(
            StreamingPlaybackIssueCode.youtubeInvalidResponse,
          ),
          'ERROR',
        );
      }
    }

    final issue =
        mostUsefulIssue ??
        const StreamingPlaybackIssue(
          StreamingPlaybackIssueCode.noAudioResource,
        );
    onIssue?.call(
      StreamingPlaybackIssue(
        issue.code,
        httpStatus: issue.httpStatus,
        youtubeStatus: issue.youtubeStatus,
        clientAttempts: attempts,
      ),
    );
    return null;
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
      final effectiveBitrate = bitrate > 0
          ? bitrate
          : (itag == 140 ? preferredAudioBitrate : 0);
      if (itag == 139 || effectiveBitrate < minimumAudioBitrate) {
        continue;
      }
      candidates.add((url: url, bitrate: effectiveBitrate, itag: itag));
    }
    if (candidates.isEmpty) return null;

    // Target approximately 128 kbps AAC for balanced startup and quality.
    // A faster source with higher bitrate can be selected if 128 is absent.
    candidates.sort((a, b) {
      final aDiff = (a.bitrate - preferredAudioBitrate).abs();
      final bDiff = (b.bitrate - preferredAudioBitrate).abs();
      final byPreference = aDiff.compareTo(bDiff);
      return byPreference != 0 ? byPreference : a.bitrate.compareTo(b.bitrate);
    });

    // If the primary URL fails to prepare, allow one alternate AAC URL,
    // but NEVER drop below 96 kbps. Prefer the best lower bitrate; if none
    // exists, try an equal-bitrate alternative, not a more demanding format.
    // This is a startup fallback, not mid-song adaptive bitrate switching.
    final primary = candidates.first;
    final alternatives = candidates.where((c) => c.url != primary.url).toList();
    final lowerBitrate =
        alternatives.where((c) => c.bitrate < primary.bitrate).toList()
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
    _mediaRefusals.clear();
    if (_ownsClient) _client.close();
  }
}
