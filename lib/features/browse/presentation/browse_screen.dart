import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/explore/presentation/explore_screen.dart';
import '../../../features/settings/presentation/general_settings_provider.dart';

/// Browse: the fifth tab (replaces the Detail tab in ZoroX v4).
///
/// This tab is the Explore page. Since +58 Explore has ONE source —
/// Stremio Add-ons (catalogs from the user's installed add-ons); the
/// TMDB "Movies & Shows" and AniList "Anime" sources and the Explore
/// Source picker were removed at the user's request. It needs no TMDB
/// key to open. The page header reads "Explore"; the tab reads "Browse".
class BrowseScreen extends ConsumerWidget {
  const BrowseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched so a key added in Settings flips the Movies & Shows rows
    // to the TMDB page without relaunching: the setter mirrors it into
    // TmdbConfig first.
    ref.watch(generalSettingsProvider.select((s) => s.tmdbApiKey));
    return const ExploreScreen();
  }
}
