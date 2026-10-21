import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/streaming/youtube_music_search.dart';
import 'package:mornye/services/streaming/streaming_source.dart';
import 'package:mornye/services/streaming/manual_match_store.dart';
import 'package:mornye/services/streaming/track_matcher.dart';

/// Temporary manual override editor. Search results will be added when a
/// YouTube Music catalog adapter is connected. No playback is implied here.
class ManualMatchSheet extends StatefulWidget {
  const ManualMatchSheet({super.key, required this.track});
  final Track track;

  static Future<void> show(BuildContext context, Track track) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (_) => ManualMatchSheet(track: track),
    );
  }

  @override
  State<ManualMatchSheet> createState() => _ManualMatchSheetState();
}

class _ManualMatchSheetState extends State<ManualMatchSheet> {
  final controller = TextEditingController();
  ManualMatchStore? store;
  late final CatalogTrack catalog;
  bool busy = true;
  bool searching = false;
  String? searchError;
  List<StreamingTrack> results = const [];
  final queryController = TextEditingController();
  final searchClient = YouTubeMusicSearch();

  @override
  void initState() {
    super.initState();
    catalog = CatalogTrack(
      provider: widget.track.source ?? 'catalog',
      id: widget.track.id,
      title: widget.track.name,
      artist: widget.track.artistName,
      duration: widget.track.duration > 0
          ? Duration(seconds: widget.track.duration)
          : null,
      isrc: widget.track.isrc,
    );
    queryController.text = '${widget.track.name} ${widget.track.artistName}';
    _load();
  }

  Future<void> _load() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    store = ManualMatchStore(preferences);
    controller.text = store!.getOverride(catalog) ?? '';
    setState(() => busy = false);
  }

  @override
  void dispose() {
    controller.dispose();
    queryController.dispose();
    searchClient.close();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      searching = true;
      searchError = null;
      results = const [];
    });
    try {
      final found = await searchClient.search(queryController.text);
      if (!mounted) return;
      setState(() => results = found);
    } catch (error) {
      if (!mounted) return;
      setState(() => searchError = error.toString());
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  Future<void> _save() async {
    final id = controller.text.trim();
    if (id.isEmpty || store == null) return;
    final ok = await store!.setOverride(catalog, id);
    if (!mounted) return;
    if (ok) Navigator.pop(context);
  }

  Future<void> _clear() async {
    if (store == null) return;
    final ok = await store!.clearOverride(catalog);
    if (!mounted) return;
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Match YouTube Music Track',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text('${catalog.title} — ${catalog.artist}'),
          const SizedBox(height: 16),
          TextField(
            controller: queryController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: 'Search YouTube Music',
              suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                onPressed: searching ? null : _search,
              ),
            ),
          ),
          if (searching) const LinearProgressIndicator(),
          if (searchError != null) Text('Search unavailable: $searchError'),
          if (results.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: results.length,
                itemBuilder: (context, index) {
                  final result = results[index];
                  return ListTile(
                    title: Text(result.title),
                    subtitle: Text(result.artist),
                    selected: controller.text == result.id,
                    onTap: () => setState(() => controller.text = result.id),
                    trailing: controller.text == result.id
                        ? const Icon(Icons.check_circle)
                        : null,
                  );
                },
              ),
            ),
          const Text(
            'Select a search result, then save. Search uses an unofficial '
            'YouTube Music endpoint and may stop working. This does not enable playback.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Selected video ID (or enter manually)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (busy)
            const Center(child: CircularProgressIndicator())
          else
            Row(
              children: [
                TextButton(onPressed: _clear, child: const Text('Reset match')),
                const Spacer(),
                FilledButton(onPressed: _save, child: const Text('Save match')),
              ],
            ),
        ],
      ),
    );
  }
}
