/// Resume re-open decision (+48, +49): on return from Home (PiP OFF)
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
/// to re-open at.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_ios_options.dart';

void main() {
  group('shouldResyncDecoderOnResume', () {
    test('all gates pass => re-sync (the PiP-OFF Home → return case)', () {
      expect(
        shouldResyncDecoderOnResume(
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
          pipEnabled: false,
          inPip: false,
          awaitingPrebuffer: false,
          startedPlaying: true,
          hasStream: false,
        ),
        isFalse,
      );
    });
  });
}
