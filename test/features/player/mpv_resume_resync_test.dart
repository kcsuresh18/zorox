/// Resume re-open decision (+48, +49, +50): on return from Home (PiP OFF)
/// the VideoToolbox decoder's reference frames are stale from the
/// background suspension, so the player restarts mid-GOP — macroblocked
/// for a few seconds, sometimes frozen — until the next keyframe. +48
/// fixed that with a seek to the playhead, but the video stayed laggy
/// and choppy (the HTTP socket is killed too, and the seek throws away
/// the buffered cushion), so +49 re-opens the stream at the playhead
/// instead — same gates, fresh connection + fresh decoder + pre-buffer
/// while still paused. The re-open is only wanted when the player was
/// actually background-paused: PiP keeps decoding, an open landing
/// re-syncs on its own, and a film that never started has no position
/// to re-open at. +50: only after a REAL backgrounding
/// (`paused`/`hidden` → `resumed`) — a transient `inactive` (Control
/// Center, Notification Center, a call) returns to `resumed` without
/// ever backgrounding, and re-opening for one restarts the film for
/// nothing (user proof 2026-11-16, The Odyssey).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_ios_options.dart';

void main() {
  group('shouldResyncDecoderOnResume', () {
    test('all gates pass => re-sync (the PiP-OFF Home → return case)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          pipEnabled: false,
          inPip: false,
          awaitingPrebuffer: false,
          startedPlaying: true,
          hasStream: true,
        ),
        isTrue,
      );
    });

    test('PiP enabled => no re-sync (the player never paused)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          pipEnabled: true,
          inPip: false,
          awaitingPrebuffer: false,
          startedPlaying: true,
          hasStream: true,
        ),
        isFalse,
      );
    });

    test('PiP window was up => no re-sync (it kept decoding)', () {
      expect(
        shouldResyncDecoderOnResume(
          wasBackgrounded: true,
          pipEnabled: false,
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
          pipEnabled: false,
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
          pipEnabled: false,
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
          pipEnabled: false,
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
            pipEnabled: false,
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
            pipEnabled: false,
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
