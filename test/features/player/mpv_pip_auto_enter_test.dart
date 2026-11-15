/// Auto-PiP decision (+41): a Home swipe opens the PiP window by
/// itself only when the PiP setting is ON (and supported), the film
/// is actually playing, and no window is already up.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_pip_quality.dart';

void main() {
  group('shouldAutoEnterPip', () {
    test('setting ON + playing + no window => auto-PiP', () {
      expect(
        shouldAutoEnterPip(
          pipAvailable: true,
          playing: true,
          inPip: false,
        ),
        isTrue,
      );
    });

    test('setting OFF (not available) => no auto-PiP', () {
      expect(
        shouldAutoEnterPip(
          pipAvailable: false,
          playing: true,
          inPip: false,
        ),
        isFalse,
      );
    });

    test('paused => no auto-PiP', () {
      expect(
        shouldAutoEnterPip(
          pipAvailable: true,
          playing: false,
          inPip: false,
        ),
        isFalse,
      );
    });

    test('window already up => no second enter', () {
      expect(
        shouldAutoEnterPip(
          pipAvailable: true,
          playing: true,
          inPip: true,
        ),
        isFalse,
      );
    });

    test('all gates off => no auto-PiP', () {
      expect(
        shouldAutoEnterPip(
          pipAvailable: false,
          playing: false,
          inPip: true,
        ),
        isFalse,
      );
    });
  });
}
