/// Structured playback failures that can be shown without exposing ephemeral
/// signed audio URLs, cookies, API response bodies, or authentication tokens.
enum StreamingPlaybackIssueCode {
  noConfidentMatch,
  matchSearchFailed,
  noAudioResource,
  invalidVideoId,
  youtubeHttpFailure,
  youtubeRestricted,
  youtubeUnsupportedAudio,
  youtubeTimeout,
  youtubeNetworkFailure,
  youtubeInvalidResponse,
  invalidResource,
  playerUnavailable,
  playerRejected,
  unexpectedFailure,
}

class StreamingPlaybackIssue {
  const StreamingPlaybackIssue(
    this.code, {
    this.httpStatus,
    this.youtubeStatus,
    this.clientAttempts = const [],
  });

  final StreamingPlaybackIssueCode code;
  final int? httpStatus;

  /// Only a short, sanitized status token such as LOGIN_REQUIRED, never the
  /// provider's free-form error message or a signed playback URL.
  final String? youtubeStatus;

  /// Sanitized client/status pairs only. Never include URLs or API reasons.
  final List<String> clientAttempts;

  String get diagnosticCode => switch (code) {
    StreamingPlaybackIssueCode.noConfidentMatch => 'MATCH-NONE',
    StreamingPlaybackIssueCode.matchSearchFailed => 'MATCH-SEARCH',
    StreamingPlaybackIssueCode.noAudioResource => 'YT-NO-AUDIO',
    StreamingPlaybackIssueCode.invalidVideoId => 'YT-BAD-ID',
    StreamingPlaybackIssueCode.youtubeHttpFailure => 'YT-HTTP',
    StreamingPlaybackIssueCode.youtubeRestricted => 'YT-RESTRICTED',
    StreamingPlaybackIssueCode.youtubeUnsupportedAudio => 'YT-FORMAT',
    StreamingPlaybackIssueCode.youtubeTimeout => 'YT-TIMEOUT',
    StreamingPlaybackIssueCode.youtubeNetworkFailure => 'YT-NETWORK',
    StreamingPlaybackIssueCode.youtubeInvalidResponse => 'YT-RESPONSE',
    StreamingPlaybackIssueCode.invalidResource => 'PLAYER-URL',
    StreamingPlaybackIssueCode.playerUnavailable => 'PLAYER-INIT',
    StreamingPlaybackIssueCode.playerRejected => 'PLAYER-OPEN',
    StreamingPlaybackIssueCode.unexpectedFailure => 'STREAM-ERROR',
  };

  String get userMessage {
    final explanation = switch (code) {
      StreamingPlaybackIssueCode.noConfidentMatch =>
        'No confident recording match. Select Match YouTube Music in the track menu.',
      StreamingPlaybackIssueCode.matchSearchFailed =>
        'YouTube Music matching failed. Check your connection and try again.',
      StreamingPlaybackIssueCode.noAudioResource =>
        'YouTube did not provide a directly playable audio stream for this recording.',
      StreamingPlaybackIssueCode.invalidVideoId =>
        'The selected YouTube Music match has an invalid video ID.',
      StreamingPlaybackIssueCode.youtubeHttpFailure =>
        'YouTube refused the audio request (HTTP ${httpStatus ?? 'unknown'}).',
      StreamingPlaybackIssueCode.youtubeRestricted =>
        'YouTube did not authorize playback of this recording'
        '${youtubeStatus == null ? '' : ' ($youtubeStatus)'}.',
      StreamingPlaybackIssueCode.youtubeUnsupportedAudio =>
        'YouTube returned no directly playable AAC audio at the required quality.',
      StreamingPlaybackIssueCode.youtubeTimeout =>
        'The YouTube audio request timed out. Check your connection.',
      StreamingPlaybackIssueCode.youtubeNetworkFailure =>
        'Could not reach YouTube to obtain audio. Check your connection.',
      StreamingPlaybackIssueCode.youtubeInvalidResponse =>
        'YouTube returned an unexpected audio response.',
      StreamingPlaybackIssueCode.invalidResource =>
        'The provider returned an invalid or unsupported audio URL.',
      StreamingPlaybackIssueCode.playerUnavailable =>
        'The iPhone audio player could not be initialized.',
      StreamingPlaybackIssueCode.playerRejected =>
        'The iPhone audio player could not open the stream.',
      StreamingPlaybackIssueCode.unexpectedFailure =>
        'An unexpected online playback failure occurred.',
    };
    final details = clientAttempts.isEmpty
        ? ''
        : ' Attempts: ${clientAttempts.join(', ')}.';
    return '$explanation$details [$diagnosticCode]';
  }
}
