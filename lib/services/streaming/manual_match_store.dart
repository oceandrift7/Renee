import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'track_matcher.dart';

/// Persist only stable recording IDs, never expiring playback URLs.
class ManualMatchStore {
  const ManualMatchStore(this.preferences);

  final SharedPreferences preferences;
  static const _key = 'renee.manual_matches.v1';

  Map<String, String> _read() {
    final raw = preferences.getString(_key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((key, value) => MapEntry(key.toString(), value.toString()));
    } on FormatException {
      return {};
    }
  }

  /// The returned ID is the user's explicit override for this catalog track.
  String? getOverride(CatalogTrack track) => _read()[track.storageKey];

  Future<bool> setOverride(CatalogTrack track, String youtubeMusicId) async {
    if (youtubeMusicId.trim().isEmpty) {
      throw ArgumentError.value(youtubeMusicId, 'youtubeMusicId', 'Cannot be empty');
    }
    final values = _read()..[track.storageKey] = youtubeMusicId;
    return preferences.setString(_key, jsonEncode(values));
  }

  Future<bool> clearOverride(CatalogTrack track) async {
    final values = _read()..remove(track.storageKey);
    return preferences.setString(_key, jsonEncode(values));
  }
}
