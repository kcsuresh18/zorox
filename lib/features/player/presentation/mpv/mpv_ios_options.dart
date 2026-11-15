/// The mpv options iOS gets, on top of the stock `hwdec: videotoolbox`.
///
/// Evidence: Nuvio (public source, `NuvioMedia/NuvioMobile`,
/// `iosApp/iosApp/Player/MPVPlayerBridge.swift`, `setupMpv()`) sets
/// `hwdec-software-fallback: 300` on iOS, with the comment that iOS can
/// invalidate the VideoToolbox session — e.g. Notification Center during
/// PiP — and FFmpeg recreates it at the next frames; keep hardware
/// decoding meanwhile. ZoroX set the fallback on Android only, so on iOS
/// a lost VideoToolbox session dropped to software decode for the rest
/// of the file: the CPU burned, the phone got hotter, and 4K stayed
/// laggy once hot (user report 2026-11-15). The fallback is the fix for
/// that spiral: a lost session is recreated and hardware decode resumes,
/// instead of the file playing in software until it ends.
///
/// `framedrop: vo` is mpv's recommended mode (+34, was `decoder+vo`):
/// when a frame cannot be presented in time it is dropped instead of
/// stalling the clock, so a hot phone stutters briefly rather than
/// falling behind and never catching up. mpv's manual calls `vo` "the
/// recommended mode, and the default" and says `decoder+vo` is "Not
/// recommended" — the decoder side also skips frames, which costs
/// decode work for nothing when the bottleneck is the render.
///
/// `demuxer-max-bytes: 256MiB` (+34): the network cache's byte cap
/// (default 150 MiB). The 20.96 GB file is only ~15 Mbps, but a bigger
/// headroom rides out throughput dips without a cache stall. Costs only
/// RAM. `demuxer-readahead-secs` is NOT set: under the cache it is
/// mostly ignored (`cache-secs` overrides it), so it would be a no-op.
///
/// The scaler options (+34, the cheap GPU render layer): `scale` /
/// `cscale` / `dscale: bilinear` is the fastest scaler (the defaults
/// are lanczos / hermite), `deband: no` and `dither-depth: no` skip
/// two GPU passes, `correct-downscaling: no` skips the extra downscale
/// pass, and `tone-mapping: clip` is the cheapest HDR mapping. These
/// are gl_video options, so they apply only in the OpenGL render path
/// (normal playback, PiP OFF) — in the software render path (PiP ON)
/// they are no-ops, and the equivalent cheap knob there would be
/// `sws-scaler` / `sws-fast`. The cost is a little picture quality:
/// bilinear is visibly softer than lanczos on a 4K downscale, and
/// hard-clipped highlights lose rolloff.
///
/// Deliberately NOT here: `video-sync` (heat-irrelevant),
/// `hdr-compute-peak` (blacks the video with `vo=libmpv`, proven in
/// v20+1 — media_kit forces peak compute off), and Nuvio's `vo=gpu-next`
/// + MoltenVK native path (a redesign: ZoroX renders through media_kit's
/// Flutter texture). `tone-mapping` itself is NOT peak compute: it only
/// picks the mapping curve, and `clip` is the cheapest one; peak compute
/// stays off.
library;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// The iOS-only mpv options, as `option → value`.
const Map<String, String> kMpvIosOptions = <String, String>{
  'hwdec-software-fallback': '300',
  'framedrop': 'vo',
  'demuxer-max-bytes': '256MiB',
  'scale': 'bilinear',
  'cscale': 'bilinear',
  'dscale': 'bilinear',
  'deband': 'no',
  'dither-depth': 'no',
  'correct-downscaling': 'no',
  'tone-mapping': 'clip',
};

/// The `hwdec` value for the iOS VideoController.
///
/// PiP mode (+28) uses `'videotoolbox-copy'`: hardware decode with the
/// frames copied to system memory, so the software renderer — the only
/// renderer that can feed a PiP window, because GPU work is not allowed
/// in the background — can read them. Normal mode keeps `'videotoolbox'`.
/// Pure, so it is unit-tested (see `mpv_ios_pip_test.dart`).
String mpvIosHwdec({required bool pipEnabled}) =>
    pipEnabled ? 'videotoolbox-copy' : 'videotoolbox';

/// Whether the VideoToolbox session is lost, from the live
/// `hwdec-current` read-back (+40 P4).
///
/// `hwdec-current` is the decoder actually in use: `'videotoolbox'`
/// (or `'videotoolbox-copy'` in PiP mode) while the session is alive,
/// empty (or `'no'`) once iOS has invalidated it while the app was
/// backgrounded — the overlay then reads `hwdec:` with nothing after
/// it, and 4K falls back to software decode for the rest of the file
/// (user proof 2026-11-15: Home → return, `vo-drop: 18 (+18)`,
/// `vf-fps: 12`). Either VideoToolbox flavour counts as alive: a
/// `'videotoolbox'` session under a PiP-mode expectation is hardware
/// decode, just without the copy the SW renderer wants, and a
/// `'videotoolbox-copy'` session under a normal expectation is the same
/// hardware decoder. Pure, so it is unit-tested (see
/// `mpv_hwdec_resume_test.dart`).
bool hwdecSessionLost({required String current}) {
  const alive = <String>{'videotoolbox', 'videotoolbox-copy'};
  return !alive.contains(current.trim());
}

/// Whether the decoder needs a re-sync seek on app resume (+48).
///
/// iOS suspends the VideoToolbox decoder while the app is backgrounded,
/// and its reference frames go stale — on resume the player restarts
/// mid-GOP without a valid I-frame reference, so the picture is
/// macroblocked (and sometimes frozen) until the next keyframe, ~2-4 s
/// later (user proof 2026-11-16, Other Mommy 1080p, PiP OFF: full-frame
/// macroblocking + wrong colours at 06:33-06:35, clean by 06:36). The
/// +40 P4 restore cannot see it: it stands down while the player is
/// paused (`!_playing` — media_kit does not auto-play on resume,
/// `resumeUponEnteringForegroundMode` defaults to false), and even when
/// it runs it stands down while the session is alive
/// (`hwdec-current == videotoolbox`) — alive is not the same as
/// in-sync. A seek to the current position forces mpv to flush the
/// decoder and restart from the nearest keyframe (the stall watchdog's
/// nudge, same move), so the first frame after play is clean.
///
/// Only when the player was actually background-paused: PiP keeps
/// decoding (no pause, nothing stale), an open landing re-syncs on its
/// own, and a film that never started has no position to seek to.
/// Pure, so it is unit-tested (see `mpv_resume_resync_test.dart`).
bool shouldResyncDecoderOnResume({
  required bool pipEnabled,
  required bool inPip,
  required bool awaitingPrebuffer,
  required bool startedPlaying,
  required bool hasStream,
}) =>
    !pipEnabled &&
    !inPip &&
    !awaitingPrebuffer &&
    startedPlaying &&
    hasStream;

/// Applies [kMpvIosOptions] to a player's mpv instance, then reads the
/// fallback back so the log shows what was set. Same best-effort shape
/// as [applyMpvAndroidOptions] in `mpv_android_options.dart`: a single
/// option failing must not break the open.
Future<void> applyMpvIosOptions(NativePlayer platform) async {
  for (final entry in kMpvIosOptions.entries) {
    try {
      await platform.setProperty(entry.key, entry.value);
    } catch (e) {
      debugPrint('[mpv] iOS option ${entry.key} not applied: $e');
    }
  }
  try {
    final fallback = await platform.getProperty('hwdec-software-fallback');
    debugPrint('[mpv] hwdec-software-fallback: $fallback (iOS options '
        'applied)');
  } catch (e) {
    debugPrint('[mpv] hwdec-software-fallback read-back failed: $e');
  }
}
