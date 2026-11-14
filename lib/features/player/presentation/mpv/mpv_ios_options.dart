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
/// `framedrop: decoder+vo` is the same drop policy Android already has
/// (+16): when a frame cannot be decoded in time it is dropped instead
/// of stalling the clock, so a hot phone stutters briefly rather than
/// falling behind and never catching up.
///
/// Deliberately NOT here: `video-sync` (heat-irrelevant), any
/// tone-mapping or `hdr-compute-peak` (blacks the video with
/// `vo=libmpv`, proven in v20+1 — media_kit forces peak compute off),
/// and Nuvio's `vo=gpu-next` + MoltenVK native path (a redesign: ZoroX
/// renders through media_kit's Flutter texture, and Nuvio has no
/// thermal-state handling at all — it doesn't need it, because its
/// rendering path is efficient and the fallback prevents the spiral).
library;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// The iOS-only mpv options, as `option → value`.
const Map<String, String> kMpvIosOptions = <String, String>{
  'hwdec-software-fallback': '300',
  'framedrop': 'decoder+vo',
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
