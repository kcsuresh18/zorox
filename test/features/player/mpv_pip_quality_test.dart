/// The iOS mpv PiP quality drop (+31): while the PiP window is up, the
/// stream drops to the tallest one at or below 480p (or the tallest
/// lighter one), and restores on stop — because the backgrounded
/// software renderer cannot keep up with a full-res stream (~1 frame
/// per 5 s, voice stuttering too, on the +30 phone test).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_pip_quality.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_thermal_quality.dart';

void main() {
  group('pipQualityDropTarget', () {
    test('1080p drops to the tallest stream at or below 480p', () {
      expect(
        pipQualityDropTarget(
          qualities: const <int?>[2160, 1080, 720, 480, 360],
          currentIndex: 1,
        ),
        3,
      );
    });

    test('4K drops to 480p, not 720p', () {
      expect(
        pipQualityDropTarget(
          qualities: const <int?>[2160, 1080, 720, 480],
          currentIndex: 0,
        ),
        3,
      );
    });

    test('no 480p: falls back to the tallest stream below the current', () {
      expect(
        pipQualityDropTarget(
          qualities: const <int?>[2160, 1080, 720],
          currentIndex: 1,
        ),
        2,
      );
    });

    test('already 480p or lighter: no drop', () {
      expect(
        pipQualityDropTarget(
          qualities: const <int?>[2160, 1080, 720, 480, 360],
          currentIndex: 3,
        ),
        isNull,
      );
      expect(
        pipQualityDropTarget(
          qualities: const <int?>[2160, 1080, 720, 480, 360],
          currentIndex: 4,
        ),
        isNull,
      );
    });

    test('an HLS master (null quality) has no ladder: no drop', () {
      expect(
        pipQualityDropTarget(
          qualities: const <int?>[null],
          currentIndex: 0,
        ),
        isNull,
      );
    });

    test('a single stream with nothing lighter: no drop', () {
      expect(
        pipQualityDropTarget(
          qualities: const <int?>[1080],
          currentIndex: 0,
        ),
        isNull,
      );
    });

    test('a bad index is no drop, never a crash', () {
      expect(
        pipQualityDropTarget(
          qualities: const <int?>[2160, 1080],
          currentIndex: 5,
        ),
        isNull,
      );
      expect(
        pipQualityDropTarget(
          qualities: const <int?>[2160, 1080],
          currentIndex: -1,
        ),
        isNull,
      );
    });

    test('the ceiling is a parameter: 720p drops to 720p when asked', () {
      expect(
        pipQualityDropTarget(
          qualities: const <int?>[2160, 1080, 720, 480],
          currentIndex: 1,
          maxHeight: 720,
        ),
        2,
      );
    });
  });

  group('bestLighterStreamIndex (the shared ladder)', () {
    test('picks the tallest at or below the ceiling', () {
      expect(
        bestLighterStreamIndex(
          const <int?>[2160, 1080, 720, 480],
          2160,
          1080,
        ),
        1,
      );
    });

    test('falls back to the tallest below when nothing is that light', () {
      expect(
        bestLighterStreamIndex(const <int?>[2160, 1080, 720], 1080, 480),
        2,
      );
    });

    test('null when nothing is lighter', () {
      expect(
        bestLighterStreamIndex(const <int?>[1080], 1080, 480),
        isNull,
      );
    });

    test('skips null and zero qualities (HLS masters)', () {
      expect(
        bestLighterStreamIndex(
          const <int?>[null, 1080, 0, 480],
          1080,
          480,
        ),
        3,
      );
    });
  });
}
