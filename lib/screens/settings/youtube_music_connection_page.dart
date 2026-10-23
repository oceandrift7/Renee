import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mornye/services/streaming/youtube_music_signed_session.dart';

/// Opt-in iOS account connection diagnostic. A signed-in YouTube Music
/// browser is NOT the same as verified streaming access or an OAuth token.
/// The native WKWebView never impersonates another browser's user agent.
class YouTubeMusicConnectionPage extends StatefulWidget {
  const YouTubeMusicConnectionPage({super.key});

  @override
  State<YouTubeMusicConnectionPage> createState() =>
      _YouTubeMusicConnectionPageState();
}

class _YouTubeMusicConnectionPageState
    extends State<YouTubeMusicConnectionPage> {
  static const _browser =
      MethodChannel('com.renee/ytmusic_auth_browser');
  static const _sessions = YouTubeMusicSessionStore();

  bool _busy = false;
  bool _saved = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final saved = await _sessions.read();
    if (!mounted) return;
    setState(() => _saved = saved != null);
  }

  Future<void> _connect() async {
    if (_busy || !Platform.isIOS) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final details = await _browser.invokeMapMethod<String, dynamic>('open');
      // Closing the browser intentionally makes no change to saved secrets.
      if (details == null) return;
      final session = YouTubeMusicSignedSession.fromPrivateJson({
        'version': 1,
        ...details,
      });
      if (session == null) {
        throw const FormatException('Missing YouTube session context');
      }
      await _sessions.save(session);
      if (!mounted) return;
      setState(() {
        _saved = true;
        _message =
            'Session saved securely on this device. YouTube Music playback '
            'is still experimental and may require additional verification.';
      });
    } on MissingPluginException {
      if (mounted) {
        setState(() => _message = 'This browser is only available in the iOS build.');
      }
    } on PlatformException {
      if (mounted) {
        setState(() => _message =
            'The YouTube Music browser could not open. Try again.');
      }
    } catch (_) {
      // Never display session cookie values, credentials, or native exceptions.
      if (mounted) {
        setState(() => _message =
            'The browser did not provide a usable signed-in session. '
            'Google may be blocking embedded sign-in.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    if (_busy || !_saved) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect YouTube Music?'),
        content: const Text(
          'Renée will remove its saved YouTube Music session from this device. '
          'This does not sign your Google account out of Safari or other apps.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _sessions.clear();
      if (!mounted) return;
      setState(() {
        _saved = false;
        _message = 'Renée’s saved YouTube Music session was disconnected.';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'Could not remove the saved session. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('YouTube Music connection')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Icon(Icons.account_circle_outlined,
              size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            _saved ? 'Session saved on this iPhone' : 'Not connected',
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          const Text(
            'Renée can open YouTube Music in a private, in-app browser. '
            'After you finish signing in, tap “Use session” inside the '
            'browser and explicitly agree before anything is saved. '
            'Only YouTube-domain cookies are considered.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Google may refuse embedded browser sign-in. '
                'We do not bypass that restriction or read Safari cookies. '
                'Saving a session does not guarantee YouTube playback, '
                'and PO tokens may still be required.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy || !Platform.isIOS ? null : _connect,
            icon: const Icon(Icons.open_in_browser),
            label: Text(_saved ? 'Replace saved session' : 'Open YouTube Music browser'),
          ),
          if (_saved) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _disconnect,
              icon: const Icon(Icons.logout),
              label: const Text('Disconnect'),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_message != null) ...[
            const SizedBox(height: 16),
            Text(_message!, textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}
