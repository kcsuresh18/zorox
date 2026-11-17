import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'explore_mode_provider.g.dart';

const String _kExploreModeKey = 'explore_mode_type';
const String _kLegacyAnimeBoolKey = 'explore_mode_is_anime';

/// Explore has ONE source since +58: Stremio Add-ons.
///
/// `movies` (TMDB) and `anime` (AniList) are no longer selectable and
/// the provider never returns them. The values stay in the enum only so
/// the code that still branches on them keeps compiling, and so a
/// preference saved by an older build can be recognised and migrated.
enum ExploreModeType { movies, anime, stremio }

// App-wide state. keepAlive so the one-time migration of an old saved
// preference runs once per launch, not on every Explore visit.
@Riverpod(keepAlive: true)
class ExploreMode extends _$ExploreMode {
  @override
  ExploreModeType build() {
    _migratePersistedMode();
    return ExploreModeType.stremio;
  }

  /// A build before +58 could have saved Movies & Shows or Anime (or the
  /// even older anime boolean). Those sources are gone, so the saved
  /// value is rewritten to Stremio Add-ons: nobody lands on a removed
  /// source, on this build or after a later update.
  Future<void> _migratePersistedMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString(_kExploreModeKey);
      if (savedMode != null && savedMode != ExploreModeType.stremio.name) {
        await prefs.setString(_kExploreModeKey, ExploreModeType.stremio.name);
      }
      if (prefs.containsKey(_kLegacyAnimeBoolKey)) {
        await prefs.remove(_kLegacyAnimeBoolKey);
      }
    } catch (_) {}
  }

  /// Kept for callers; every mode resolves to Stremio Add-ons.
  void setMode(ExploreModeType mode) {
    state = ExploreModeType.stremio;
    unawaited(_persistStremio());
  }

  Future<void> _persistStremio() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kExploreModeKey, ExploreModeType.stremio.name);
    } catch (_) {}
  }
}
