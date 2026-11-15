/// The mpv options iOS gets, on top of the stock `hwdec: videotoolbox`.
///
/// Evidence: Nuvio (public source, `NuvioMedia/NuvioMobile`,
/// `iosApp/iosApp/Player/MPVPlayerBridge.swift`, `setupMpv()`) sets
/// `hwdec-software-fallback: 300` on iOS, with the comment that iOS can
/// invalidate the VideoToolbox session — e.g. Notification Center during
/// PiP — and FFmpeg recreates it at the next frames; keep hardware
/// decoding meanwhile. ZoroX copied the 300 (+40), but mpv's manual
/// says the default is 3 and a higher number is harmful: the fallback
/// only triggers after N consecutive failed frames, so 300 tolerates
/// ~12 s of failed decoding before falling back to software — and when
/// it finally falls back, the failed packets are SKIPPED ("parts of the
/// file will be skipped, approximately by to the number of packets that
/// could not be decoded"). That matches the user's +48 symptom exactly
/// (timestamp frozen ~5 s, then a ~10 s jump). +49 returns to mpv's
/// default of 3: a dead session falls back to software after 3 failed
/// frames (~125 ms), and mpv retains the packets, so there is no skip.
/// The resume re-open (see [shouldResyncDecoderOnResume]) recreates
/// the hardware decoder anyway, so a software fallback is only ever a
/// brief bridge, never the rest of the file.
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
/// The reconnect options (+49): iOS kills the HTTP socket while the app
/// is suspended, so on return mpv sits in a read timeout before it can
/// serve data again — the 5 s freeze + ~10 s catch-up jump the user
/// reported on +48 (Other Mommy 1080p, PiP OFF, Home → return, timestamp
/// frozen at 07:13 then jumping to 07:23). The source is a direct HTTP
/// file link, not HLS, and these are FFmpeg http-protocol options, so
/// they apply to it: `reconnect=1` re-establishes a dead socket
/// automatically, `reconnect_streamed=1` covers streamed variants, and
/// `reconnect_delay_max=2` caps the retry delay at 2 s. `network-timeout:
/// 5` caps a single read at 5 s so a dead socket fails fast instead of
/// hanging on the OS TCP timeout. They ride along with the resume
/// re-open (see [shouldResyncDecoderOnResume]): the re-open is the
/// fresh connection, these are the safety net if a socket dies
/// mid-stream.
const Map<String, String> kMpvIosOptions = <String, String>{
  'hwdec-software-fallback': '3',
  'framedrop': 'vo',
  'demuxer-max-bytes': '256MiB',
  'scale': 'bilinear',
  'cscale': 'bilinear',
  'dscale': 'bilinear',
  'deband': 'no',
  'dither-depth': 'no',
  'correct-downscaling': 'no',
  'tone-mapping': 'clip',
  'stream-lavf-o': 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2',
  'network-timeout': '5',
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

/// Whether the stream needs a re-open on app resume (+48, +49).
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
/// in-sync. +48 fixed the macroblocking with a seek to the playhead
/// (flush the decoder, restart from the nearest keyframe), and the
/// picture came back clean — but the video stayed laggy and choppy
/// (user proof 2026-11-16, +48 installed: timestamp frozen at 07:13
/// for ~5 s, then a ~10 s jump). The seek fixes the decoder but not
/// the second problem: iOS also kills the HTTP socket while suspended,
/// so mpv sits in a read timeout before it can serve data again, and
/// the seek itself throws away the buffered cushion. +49 re-opens the
/// stream at the playhead instead (same gates): a fresh connection, a
/// fresh decoder, and the pre-buffer refilled while still paused, so
/// the first frame after play is clean and the cache is full.
///
/// Only when the player was actually background-paused: PiP keeps
/// decoding (no pause, nothing stale), an open landing re-syncs on its
/// own, and a film that never started has no position to re-open at.
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
