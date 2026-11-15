/// iOS mpv PiP quality (+31): while the PiP window is up, the app is
/// backgrounded and iOS throttles its CPU hard — the software renderer
/// writing full-res frames plus the tap's downscale cannot keep up, so
/// the window runs at ~1 frame per 5 s and the voice stutters too (the
/// same throttling starves mpv's audio decoder). The fix is to cut the
/// work at the source: drop to a light stream while PiP is up and
/// restore the original when it stops. The PiP window is small (the
/// feed is downscaled to ~640 px wide anyway), so 480p is plenty.
///
/// The decision is pure: given the stream ladder, the stream now
/// playing, and the ceiling, it returns the stream to drop to, or
/// null when no drop is wanted. The screen acts on it (see
/// `_dropQualityForPip` / `_restoreQualityAfterPip` in
/// `mpv_player_screen.dart`).
library;

import 'mpv_thermal_quality.dart';

/// The tallest stream PiP plays: 480p. A 1080p render+downscale is
/// ~5x the work of a 480p one; 720p would be ~2.25x. The window is
/// small, so the extra softness over 720p is invisible.
const int kPipMaxHeight = 480;

/// The stream to drop to while PiP is up, or null when no drop is
/// wanted: already at or below the ceiling, an adaptive (HLS) master
/// with no ladder (quality null/0 — mpv's ABR owns it), no lighter
/// stream, or a bad index. The target is the tallest stream at or
/// below the ceiling, else the tallest one below the current stream
/// (the same ladder the thermal governor walks, see
/// `bestLighterStreamIndex`).
int? pipQualityDropTarget({
  required List<int?> qualities,
  required int currentIndex,
  int maxHeight = kPipMaxHeight,
}) {
  if (currentIndex < 0 || currentIndex >= qualities.length) return null;
  final currentHeight = qualities[currentIndex];
  if (currentHeight == null || currentHeight <= 0) return null;
  if (currentHeight <= maxHeight) return null;
  final target = bestLighterStreamIndex(qualities, currentHeight, maxHeight);
  if (target == null || target == currentIndex) return null;
  return target;
}
