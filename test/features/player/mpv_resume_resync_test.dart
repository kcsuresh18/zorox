/// Resume decoder re-sync decision (+48): on return from Home (PiP OFF)
/// the VideoToolbox decoder's reference frames are stale from the
/// background suspension, so the player restarts mid-GOP — macroblocked
/// for a few seconds, sometimes frozen — until the next keyframe. The
/// seek to the playhead is only wanted when the player was actually
/// background-paused: PiP keeps decoding, an open landing re-syncs on
/// its own, and a film that never started has no position to seek to.
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
