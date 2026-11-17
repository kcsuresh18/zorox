import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/features/addons/presentation/addons_screen.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// +58: Stremio Add-ons is Explore's only source, so its empty states
/// must offer the way to add an add-on instead of leaving a dead end.

class _NoAddons extends AddonRepository {
  @override
  AddonsState build() => const AddonsState(addons: [], isLoading: false);
}

/// One add-on installed, but it publishes no browsable catalog.
class _StreamOnly extends AddonRepository {
  @override
  AddonsState build() => AddonsState(
    addons: [
      ManagedAddon(
        manifestUrl: 'https://streams.test/manifest.json',
        addedAt: DateTime(2026),
        manifest: AddonManifest.fromJson({
          'id': 'com.streams',
          'name': 'Streams',
          'version': '1.0.0',
          'types': ['movie'],
          'idPrefixes': ['tt'],
          'resources': ['stream'],
          'catalogs': <Object>[],
        }),
      ),
    ],
    isLoading: false,
  );
}

Future<void> _pump(WidgetTester tester, AddonRepository Function() repo) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [addonRepositoryProvider.overrideWith(repo)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: AddonCatalogsTabView()),
      ),
    ),
  );
}

void main() {
  const addButton = ValueKey('explore-empty-add-addons');

  testWidgets('no add-on installed: honest message + add button', (
    tester,
  ) async {
    await _pump(tester, _NoAddons.new);
    await tester.pump();

    expect(find.text('No add-ons yet'), findsOneWidget);
    expect(find.byKey(addButton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(addButton),
        matching: find.text('Stremio add-ons'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('add-ons without catalogs: honest message + add button', (
    tester,
  ) async {
    await _pump(tester, _StreamOnly.new);
    await tester.pump();

    expect(find.text('No catalogs'), findsOneWidget);
    expect(find.byKey(addButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
