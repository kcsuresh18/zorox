/// Stall-fallback re-open decision (+48, +49, +50, +55): +55 removed the
/// +49 re-open as the default return path (it showed 00:00/LIVE + black
/// + spinner for ~3-4 s on every return) — return is a plain pause/resume
/// now, and the re-open survives only as the fallback when the plain
/// resume is verifiably dead (no position progress 8 s after
/// resume-play). The fallback is only wanted when the player was
/// actually background-paused: PiP keeps decoding, an open landing
/// re-syncs on its own, and a film that never started has no position
/// to re-open at. +50: only after a REAL backgrounding
/// (`paused`/`hidden` → `resumed`) — a transient `inactive` (Control
/// Center, Notification Center, a call) returns to `resumed` without
/// ever backgrounding, and re-opening for one restarts the film for
/// nothing (user proof 2026-11-16, The Odyssey). +55: the old
/// `pipEnabled` gate is gone — with automatic PiP removed, the setting
/// no longer implies a live window; only an actually-open window
/// (`inPip`) skips the fallback.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_ios_options.dart';

void main() {
  group('shouldResyncDecoderOnResume', () {
    test('all gates pass => re-sync (the PiP-OFF Home → return case)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: false,
          awaitingPrebuffer: false,
          startedPlaying: true,
          hasStream: true,
        ),
        isTrue,
      );
    });

    test('PiP setting ON but no window => re-sync (auto-PiP removed in +55: '
        'the setting no longer implies a live window)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: false,
          awaitingPrebuffer: false,
          startedPlaying: true,
          hasStream: true,
        ),
        isTrue,
      );
    });

    test('PiP window was up => no re-sync (it kept decoding)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: true,
          awaitingPrebuffer: false,
          startedPlaying: true,
          hasStream: true,
        ),
        isFalse,
      );
    });

    test('open landing => no re-sync (it re-syncs on its own)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: false,
          awaitingPrebuffer: true,
          startedPlaying: true,
          hasStream: true,
        ),
        isFalse,
      );
    });

    test('film never started => no re-sync (no position to seek to)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: false,
          awaitingPrebuffer: false,
          startedPlaying: false,
          hasStream: true,
        ),
        isFalse,
      );
    });

    test('no stream open => no re-sync', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          inPip: false,
          awaitingPrebuffer: false,
          startedPlaying: true,
          hasStream: false,
        ),
        isFalse,
      );
    });

    test(
      'never backgrounded (Control Center / Notification Center) => '
      'no re-open (+50)',
      () {
        expect(
          shouldResyncDecoderOnResume(
            wasBackgrounded: false,
            inPip: false,
            awaitingPrebuffer: false,
            startedPlaying: true,
            hasStream: true,
          ),
          isFalse,
        );
      },
    );

    test(
      'backgrounded then resumed, all gates pass => re-open '
      '(+50 keeps the +49 Home → return fix)',
      () {
        expect(
          shouldResyncDecoderOnResume(
            wasBackgrounded: true,
            inPip: false,
            awaitingPrebuffer: false,
            startedPlaying: true,
            hasStream: true,
          ),
          isTrue,
        );
      },
    );
  });
}
