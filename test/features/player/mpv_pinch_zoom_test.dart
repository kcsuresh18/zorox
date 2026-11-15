/// Two-finger pinch zoom on the mpv (Golden) player (+33).
///
/// The zoom plumbing has been in the v20 line since v18: a `Transform.scale`
/// over the `Video` widget driven by a `ValueNotifier<double>` the
/// controls' gesture layer writes (`_onScaleUpdate` in
/// `golden_player_controls.dart`, the screen's `_videoScale` in
/// `mpv_player_screen.dart`). The user phone report 2026-11-15 was "two
/// finger pinch video zoom in out nahi hein" — pinch out zooms in, pinch
/// in zooms out, 0.5x–3.0x, and the zoom sticks after the fingers lift.
///
/// The pinch math is pure ([videoScaleAfterPinch] / [clampVideoScale]),
/// so it is unit-tested here. A widget test driving the real gesture
/// layer with two fingers was written first and could NOT run on this VM:
/// pumping the full controls tree hangs the test isolate (the same hang
/// the drawer widget tests hit here — the swipe/drawer widget tests never
/// complete on this VM either), so the phone test is the proof that the
/// gesture reaches the notifier on a real device.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/mpv/golden_player_controls.dart';

void main() {
  group('pinch zoom on the Golden player', () {
    test('the range is half size to 3x', () {
      expect(kVideoScaleMin, 0.5);
      expect(kVideoScaleMax, 3.0);
    });

    test('a two-finger spread zooms in', () {
      // Fingers 144 px apart -> 244 px apart: the gesture scale is ~1.7.
      expect(videoScaleAfterPinch(1.0, 244 / 144), closeTo(1.69, 0.01));
      expect(videoScaleAfterPinch(1.0, 1.5), 1.5);
    });

    test('a two-finger pinch-in zooms out', () {
      // Fingers 344 px apart -> 144 px apart: the gesture scale is ~0.42.
      expect(videoScaleAfterPinch(1.0, 144 / 344), closeTo(0.5, 0.01));
      expect(videoScaleAfterPinch(1.0, 0.6), 0.6);
    });

    test('a pinch from an already-zoomed picture keeps going', () {
      expect(videoScaleAfterPinch(2.0, 1.25), 2.5);
      expect(videoScaleAfterPinch(2.0, 0.5), 1.0);
    });

    test('no finger movement is no zoom change', () {
      expect(videoScaleAfterPinch(1.0, 1.0), 1.0);
      expect(videoScaleAfterPinch(2.0, 1.0), 2.0);
    });

    test('the zoom clamps at 3x', () {
      expect(videoScaleAfterPinch(1.0, 5.0), 3.0);
      expect(videoScaleAfterPinch(2.0, 2.0), 3.0);
    });

    test('the zoom clamps at 0.5x', () {
      expect(videoScaleAfterPinch(1.0, 0.1), 0.5);
      expect(videoScaleAfterPinch(0.6, 0.5), 0.5);
    });

    test('the settle clamp holds the zoom inside the range', () {
      expect(clampVideoScale(0.4), 0.5);
      expect(clampVideoScale(3.5), 3.0);
      expect(clampVideoScale(1.7), 1.7);
    });
  });
}
