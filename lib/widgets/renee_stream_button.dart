import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/services/streaming/renee_online_playback.dart';
import 'package:mornye/services/streaming/streaming_playback_issue.dart';

/// Opt-in online Play button while the experimental resolver is being
/// validated. Existing local and download actions remain untouched.
class ReneeStreamButton extends ConsumerStatefulWidget {
  const ReneeStreamButton({super.key, required this.track});
  final Track track;

  @override
  ConsumerState<ReneeStreamButton> createState() => _ReneeStreamButtonState();
}

class _ReneeStreamButtonState extends ConsumerState<ReneeStreamButton> {
  bool _starting = false;

  Future<void> _play() async {
    if (_starting) return;
    setState(() => _starting = true);
    final generation = ReneeOnlinePlayback.beginRequest();
    var result = ReneeOnlinePlaybackResult.unavailable;
    StreamingPlaybackIssue? issue;
    try {
      // Prefer an existing local file. No internet lookup is necessary.
      final playedLocally = await playLocalIfAvailable(
        context,
        ref,
        widget.track,
        shouldPlay: () => ReneeOnlinePlayback.isCurrentRequest(generation),
      );
      if (playedLocally ||
          !mounted ||
          !ReneeOnlinePlayback.isCurrentRequest(generation)) {
        return;
      }
      final attempt = await const ReneeOnlinePlayback().tryPlayDiagnosed(
        ref,
        widget.track,
        requestGeneration: generation,
      );
      result = attempt.result;
      issue = attempt.issue;
    } catch (_) {
      result = ReneeOnlinePlaybackResult.unavailable;
    } finally {
      if (mounted) setState(() => _starting = false);
    }
    if (!mounted ||
        !ReneeOnlinePlayback.isCurrentRequest(generation) ||
        result != ReneeOnlinePlaybackResult.unavailable) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          issue?.userMessage ??
              'Online playback failed unexpectedly [STREAM-ERROR].',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Stream song online (experimental)',
      onPressed: _starting ? null : _play,
      icon: _starting
          ? const SizedBox(
              width: 19,
              height: 19,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.play_circle_outline),
    );
  }
}
