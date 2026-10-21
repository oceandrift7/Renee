import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/streaming/renee_online_playback.dart';

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
    var played = false;
    try {
      played = await const ReneeOnlinePlayback().tryPlay(ref, widget.track);
    } catch (_) {
      played = false;
    } finally {
      if (mounted) setState(() => _starting = false);
    }
    if (!mounted || played) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'Online playback is unavailable for this recording. '
          'Try Match YouTube Music from the track menu or download it.',
        ),
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
