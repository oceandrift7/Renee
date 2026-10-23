import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'streaming_source.dart';
import 'youtube_ios_ejs_solver.dart';

/// A single progressive AAC candidate returned by an independent extractor.
/// URLs remain ephemeral; never persist or log them.
class ExtractedAacCandidate {
  const ExtractedAacCandidate({
    required this.url,
    required this.bitrate,
    required this.itag,
  });

  final Uri url;
  final int bitrate;
  final int itag;
}

typedef ReneeManifestLookup = Future<List<ExtractedAacCandidate>> Function(
  String videoId,
  String clientName,
);

/// Independent BSD-licensed youtube_explode_dart extraction path. Unlike the
/// direct InnerTube probe, this supports the upstream library's SDK-less
/// client and (on iOS) the EJS player-cipher solver via JavaScriptCore.
///
/// This deliberately returns only independently fetchable AAC/MP4 URLs.
/// Signed media does not grant access to restricted, DRM, or paid recordings.
class YouTubeExplodeAudioResolver {
  YouTubeExplodeAudioResolver({
    http.Client? probeClient,
    ReneeManifestLookup? manifestLookup,
    this.manifestTimeout = const Duration(seconds: 9),
    this.jsStartupTimeout = const Duration(seconds: 14),
    this.probeTimeout = const Duration(seconds: 5),
  }) : _client = probeClient ?? http.Client(),
       _ownsClient = probeClient == null,
       _lookupOverride = manifestLookup;

  final http.Client _client;
  final bool _ownsClient;
  final ReneeManifestLookup? _lookupOverride;
  final Duration manifestTimeout;
  final Duration jsStartupTimeout;
  final Duration probeTimeout;

  static const minBitrate = 96000;
  static const preferredBitrate = 128000;
  static const profileNames = [
    'ANDROID_SDKLESS',
    'IOS',
    'ANDROID_MUSIC',
    'SAFARI_CIPHER',
    'TV_CIPHER',
  ];

  yt.YoutubeExplode? _plainEngine;
  yt.YoutubeExplode? _cipherEngine;

  Future<List<ExtractedAacCandidate>> _loadManifest(
    String videoId,
    String profile,
  ) async {
    if (_lookupOverride != null) {
      return _lookupOverride(videoId, profile);
    }
    final cipher = profile.endsWith('_CIPHER');
    yt.YoutubeExplode engine;
    if (cipher) {
      // JSCore is available inside the actual iOS app, not on Dart VM tests.
      if (!Platform.isIOS) return const [];
      if (_cipherEngine == null) {
        final solver = await ReneeIosEjsSolver.initialize()
            .timeout(jsStartupTimeout);
        _cipherEngine = yt.YoutubeExplode(jsSolver: solver);
      }
      engine = _cipherEngine!;
    } else {
      engine = _plainEngine ??= yt.YoutubeExplode();
    }
    final yt.YoutubeApiClient apiClient = switch (profile) {
      'ANDROID_SDKLESS' => yt.YoutubeApiClient.androidSdkless,
      'IOS' => yt.YoutubeApiClient.ios,
      'ANDROID_MUSIC' => yt.YoutubeApiClient.androidMusic,
      'SAFARI_CIPHER' => yt.YoutubeApiClient.safari,
      'TV_CIPHER' => yt.YoutubeApiClient.tv,
      _ => throw ArgumentError.value(profile, 'profile'),
    };
    final manifest = await engine.videos.streams.getManifest(
      videoId,
      ytClients: [apiClient],
      requireWatchPage: cipher,
    );
    return [
      for (final info in manifest.audioOnly)
        if (info.container == yt.StreamContainer.mp4 &&
            info.audioCodec.toLowerCase().contains('mp4a'))
          ExtractedAacCandidate(
            url: info.url,
            bitrate: info.bitrate.bitsPerSecond,
            itag: info.tag,
          ),
    ];
  }

  /// Requires a self-contained, fresh Googlevideo HTTPS URL. AVPlayer does not
  /// currently supply headers from StreamResource, so header-gated resources
  /// must not be handed to it.
  static bool isAcceptedCandidate(ExtractedAacCandidate candidate) {
    final uri = candidate.url;
    if (candidate.itag == 139 || candidate.bitrate < minBitrate) {
      return false;
    }
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        !uri.host.endsWith('.googlevideo.com')) {
      return false;
    }
    final expires = int.tryParse(uri.queryParameters['expire'] ?? '');
    if (expires != null &&
        expires <= DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30) {
      return false;
    }
    return true;
  }

  /// Prefer AAC close to 128kbps, then up to two authorized alternatives.
  static List<Uri> candidateUrls(Iterable<ExtractedAacCandidate> candidates) {
    final usable = candidates.where(isAcceptedCandidate).toList()
      ..sort((a, b) {
        final aDiff = (a.bitrate - preferredBitrate).abs();
        final bDiff = (b.bitrate - preferredBitrate).abs();
        final byDistance = aDiff.compareTo(bDiff);
        return byDistance != 0
            ? byDistance
            : b.bitrate.compareTo(a.bitrate);
      });
    final seen = <Uri>{};
    return [
      for (final candidate in usable)
        if (seen.add(candidate.url)) candidate.url,
    ];
  }

  /// Fetch a bounded byte range. A manifest alone is not a playable resource.
  Future<bool> _probe(Uri uri) async {
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['Range'] = 'bytes=0-16383';
      final response = await _client.send(request).timeout(probeTimeout);
      if (response.statusCode != 200 && response.statusCode != 206) {
        return false;
      }
      final mime =
          (response.headers['content-type'] ?? '').split(';').first.trim().toLowerCase();
      if (mime.isNotEmpty &&
          !mime.startsWith('audio/') &&
          !mime.startsWith('video/') &&
          mime != 'application/octet-stream') {
        return false;
      }
      final bytes = await response.stream.first.timeout(probeTimeout);
      if (bytes.isEmpty) return false;
      final prefix = String.fromCharCodes(bytes.take(32)).trimLeft().toLowerCase();
      return !prefix.startsWith('<html') &&
          !prefix.startsWith('<!doctype') &&
          !prefix.startsWith('<?xml');
    } catch (_) {
      return false;
    }
  }

  /// Attempts an SDK-less direct extraction first, then other clients and
  /// optionally iOS EJS deciphering. No account cookies, PO tokens, proxies,
  /// external extraction servers, or full-track downloads are involved.
  Future<StreamResource?> resolve(
    String videoId, {
    void Function(List<String>)? onFailure,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) {
      onFailure?.call(const ['EXTRACT:BAD_ID']);
      return null;
    }
    final attempts = <String>[];
    for (final profile in profileNames) {
      if (profile.endsWith('_CIPHER') &&
          !Platform.isIOS &&
          _lookupOverride == null) {
        attempts.add('$profile:IOS_ONLY');
        continue;
      }
      List<ExtractedAacCandidate> found;
      try {
        found = await _loadManifest(videoId, profile)
            .timeout(manifestTimeout);
      } on TimeoutException {
        attempts.add('$profile:TIMEOUT');
        continue;
      } catch (_) {
        // Never expose extractor error text: it can contain signed URLs or
        // provider response bodies. Continue with another independent client.
        attempts.add('$profile:EXTRACT_FAILED');
        continue;
      }
      final urls = candidateUrls(found);
      if (urls.isEmpty) {
        attempts.add('$profile:NO_AAC');
        continue;
      }
      var valid = false;
      for (final url in urls.take(3)) {
        if (await _probe(url)) {
          valid = true;
          return StreamResource(uri: url);
        }
      }
      if (!valid) attempts.add('$profile:MEDIA_REJECTED');
    }
    onFailure?.call(attempts);
    return null;
  }

  void close() {
    _plainEngine?.close();
    _cipherEngine?.close();
    if (_ownsClient) _client.close();
  }
}
