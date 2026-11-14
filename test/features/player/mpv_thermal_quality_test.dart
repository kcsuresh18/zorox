/// The 4K thermal lag fix (+27).
///
/// Two halves: the iOS mpv options (the VideoToolbox fallback Nuvio sets,
/// so a session invalidated under heat is recreated instead of dropping to
/// software decode for the rest of the file) and the thermal-aware quality
/// governor (drop a heavy stream for a lighter one while the phone is
/// serious or critical, restore it when it cools).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/thermal_state.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_ios_options.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_thermal_quality.dart';

void main() {
  group('thermalStateFromRaw', () {
    test('maps the iOS raw values', () {
      expect(thermalStateFromRaw(0), ThermalState.nominal);
      expect(thermalStateFromRaw(1), ThermalState.fair);
      expect(thermalStateFromRaw(2), ThermalState.serious);
      expect(thermalStateFromRaw(3), ThermalState.critical);
    });

    test('anything outside 0–3 is unknown, never a guess', () {
      expect(thermalStateFromRaw(4), ThermalState.unknown);
      expect(thermalStateFromRaw(-1), ThermalState.unknown);
      expect(thermalStateFromRaw(null), ThermalState.unknown);
      expect(thermalStateFromRaw('serious'), ThermalState.unknown);
    });

    test('a non-iOS read is unknown without touching the channel', () async {
      // These tests run on the host (Linux), so the platform guard
      // answers before any channel call.
      expect(await readThermalState(), ThermalState.unknown);
    });
  });

  group('kMpvIosOptions', () {
    test('keeps the VideoToolbox session alive under heat', () {
      // Nuvio's value: 300 frames of hardware decode while FFmpeg
      // recreates an invalidated session.
      expect(kMpvIosOptions['hwdec-software-fallback'], '300');
    });

    test('drops frames instead of falling behind, like Android', () {
      expect(kMpvIosOptions['framedrop'], 'decoder+vo');
    });

    test('never carries the options that blank the video', () {
      expect(kMpvIosOptions.containsKey('hdr-compute-peak'), isFalse);
      expect(kMpvIosOptions.containsKey('tone-mapping'), isFalse);
      expect(kMpvIosOptions.containsKey('video-sync'), isFalse);
      expect(kMpvIosOptions.containsKey('vo'), isFalse);
    });
  });

  group('ThermalQualityGovernor — the drop', () {
    const qualities = <int?>[2160, 1080, 720];

    test('a serious phone drops 4K to the best lighter stream', () {
      final governor = ThermalQualityGovernor();
      final decision = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 0,
      );
      expect(decision.kind, ThermalQualityKind.drop);
      expect(decision.targetIndex, 1);
    });

    test('a critical phone drops too', () {
      final governor = ThermalQualityGovernor();
      final decision = governor.evaluate(
        thermal: ThermalState.critical,
        qualities: qualities,
        currentIndex: 0,
      );
      expect(decision.kind, ThermalQualityKind.drop);
      expect(decision.targetIndex, 1);
    });

    test('prefers the tallest stream at or below 1080p', () {
      final governor = ThermalQualityGovernor();
      final decision = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[2160, 720, 1080],
        currentIndex: 0,
      );
      expect(decision.targetIndex, 2);
    });

    test('falls to the next-lower stream when nothing is at 1080p', () {
      final governor = ThermalQualityGovernor();
      final decision = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[2160, 1440],
        currentIndex: 0,
      );
      expect(decision.kind, ThermalQualityKind.drop);
      expect(decision.targetIndex, 1);
    });

    test('no drop when the stream is already light', () {
      final governor = ThermalQualityGovernor();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: qualities,
              currentIndex: 1,
            )
            .isNone,
        isTrue,
      );
    });

    test('no drop when the phone is only fair, nominal or unreadable', () {
      for (final thermal in <ThermalState>[
        ThermalState.nominal,
        ThermalState.fair,
        ThermalState.unknown,
      ]) {
        final governor = ThermalQualityGovernor();
        expect(
          governor
              .evaluate(
                thermal: thermal,
                qualities: qualities,
                currentIndex: 0,
              )
              .isNone,
          isTrue,
          reason: '$thermal',
        );
      }
    });

    test('no drop when nothing is lighter', () {
      final governor = ThermalQualityGovernor();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[2160],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
    });

    test('an adaptive master gets one hint, not a switch', () {
      final governor = ThermalQualityGovernor();
      // quality 0 is an HLS master (see StreamResult.quality).
      final hint = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: const <int?>[0],
        currentIndex: 0,
      );
      expect(hint.kind, ThermalQualityKind.hint);
      expect(hint.targetIndex, -1);
      // The next hot tick does not hint again.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.critical,
              qualities: const <int?>[0],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      // A cool tick re-arms the hint for the next episode.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: const <int?>[0],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[null],
              currentIndex: 0,
            )
            .kind,
        ThermalQualityKind.hint,
      );
    });
  });

  group('ThermalQualityGovernor — the restore', () {
    const qualities = <int?>[2160, 1080, 720];

    ThermalQualityGovernor dropped() {
      final governor = ThermalQualityGovernor();
      final decision = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 0,
      );
      expect(decision.kind, ThermalQualityKind.drop);
      return governor;
    }

    test('restores the original after two consecutive nominal ticks', () {
      final governor = dropped();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 1,
            )
            .isNone,
        isTrue,
        reason: 'one nominal tick is not enough',
      );
      final restore = governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      expect(restore.kind, ThermalQualityKind.restore);
      expect(restore.targetIndex, 0);
    });

    test('a hot tick resets the nominal streak', () {
      final governor = dropped();
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 1,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 1,
            )
            .isNone,
        isTrue,
        reason: 'the streak restarted, one tick is not enough',
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 1,
            )
            .kind,
        ThermalQualityKind.restore,
      );
    });

    test('an unreadable state does not count as cool', () {
      final governor = dropped();
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.unknown,
              qualities: qualities,
              currentIndex: 1,
            )
            .isNone,
        isTrue,
      );
      // The unknown tick reset the streak: one nominal tick is not
      // enough anymore.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 1,
            )
            .isNone,
        isTrue,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 1,
            )
            .kind,
        ThermalQualityKind.restore,
      );
    });

    test('once the restore lands, the episode is over', () {
      final governor = dropped();
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 1,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.nominal,
              qualities: qualities,
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
    });
  });

  group('ThermalQualityGovernor — a hand pick stands', () {
    const qualities = <int?>[2160, 1080, 1440];

    test('a manual 4K pick is never dropped while the episode lasts', () {
      final governor = ThermalQualityGovernor();
      governor.noteManualPick(0);
      expect(
        governor
            .evaluate(
              thermal: ThermalState.critical,
              qualities: qualities,
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      // The phone cools: the latch clears, and the next hot episode
      // drops it like any other stream.
      governor.evaluate(
        thermal: ThermalState.nominal,
        qualities: qualities,
        currentIndex: 0,
      );
      final decision = governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 0,
      );
      expect(decision.kind, ThermalQualityKind.drop);
      expect(decision.targetIndex, 1);
    });

    test('re-picking the original mid-drop ends the episode by hand', () {
      final governor = ThermalQualityGovernor();
      governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 0,
      );
      governor.noteManualPick(0);
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: qualities,
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
      // And the governor does not drop it again on the next hot tick:
      // the viewer chose 4K.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.critical,
              qualities: qualities,
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
    });

    test('picking a third source mid-drop ends the drop, not the pick', () {
      final governor = ThermalQualityGovernor();
      governor.evaluate(
        thermal: ThermalState.serious,
        qualities: qualities,
        currentIndex: 0,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: qualities,
              currentIndex: 2,
            )
            .isNone,
        isTrue,
      );
      // The third pick (1440p) stands while hot.
      expect(
        governor
            .evaluate(
              thermal: ThermalState.critical,
              qualities: qualities,
              currentIndex: 2,
            )
            .isNone,
        isTrue,
      );
    });

    test('a bad index or an empty list is no change, never a throw', () {
      final governor = ThermalQualityGovernor();
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: qualities,
              currentIndex: 9,
            )
            .isNone,
        isTrue,
      );
      expect(
        governor
            .evaluate(
              thermal: ThermalState.serious,
              qualities: const <int?>[],
              currentIndex: 0,
            )
            .isNone,
        isTrue,
      );
    });
  });
}
