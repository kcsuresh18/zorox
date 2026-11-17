import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/config/tmdb_config.dart';
import 'package:skystream/features/explore/data/explore_mode_provider.dart';

/// +58: Explore has ONE source, Stremio Add-ons. The TMDB "Movies &
/// Shows" and AniList "Anime" sources are gone, so whatever an older
/// build saved, with or without a TMDB key, Explore opens on Stremio
/// Add-ons and the saved preference is migrated.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TmdbConfig.setUserApiKey('');
    TmdbConfig.setNuvioApiKey('');
  });

  tearDown(() {
    TmdbConfig.setUserApiKey('');
    TmdbConfig.setNuvioApiKey('');
  });

  ProviderContainer containerWith({Map<String, Object>? prefs}) {
    SharedPreferences.setMockInitialValues(prefs ?? <String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  /// Lets the provider's async migration finish. It goes through a
  /// platform-channel call, so it needs a real (short) delay.
  Future<void> settleLoad() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  test('no key and no saved mode opens on Stremio Add-ons', () async {
    final container = containerWith();
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    await settleLoad();
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
  });

  test('a saved anime mode is migrated to Stremio Add-ons', () async {
    final container = containerWith(
      prefs: {'explore_mode_type': 'anime'},
    );
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    await settleLoad();
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('explore_mode_type'), 'stremio');
  });

  test('a saved movies mode is migrated, with no TMDB key', () async {
    final container = containerWith(
      prefs: {'explore_mode_type': 'movies'},
    );
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    await settleLoad();
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('explore_mode_type'), 'stremio');
  });

  test('a saved movies mode is migrated even WITH a TMDB key', () async {
    TmdbConfig.setUserApiKey('0123456789abcdef0123456789abcdef');
    final container = containerWith(
      prefs: {'explore_mode_type': 'movies'},
    );
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    await settleLoad();
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('explore_mode_type'), 'stremio');
  });

  test('the legacy anime boolean is cleared and does not select anime',
      () async {
    final container = containerWith(
      prefs: {'explore_mode_is_anime': true},
    );
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    await settleLoad();
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('explore_mode_is_anime'), isFalse);
  });

  test('setMode can no longer select a removed source', () async {
    final container = containerWith();
    final notifier = container.read(exploreModeProvider.notifier);
    notifier.setMode(ExploreModeType.movies);
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    notifier.setMode(ExploreModeType.anime);
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
    await settleLoad();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('explore_mode_type'), 'stremio');
  });

  test('the Explore Source picker dialog no longer exists', () {
    // Guard against the picker coming back: its file was deleted in +58.
    expect(
      File(
        'lib/features/explore/presentation/widgets/'
        'explore_mode_selector_dialog.dart',
      ).existsSync(),
      isFalse,
    );
  });
}
