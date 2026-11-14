/// Thermal-aware quality: when the phone is hot, drop a heavy stream to a
/// lighter one, and come back when it cools.
///
/// The mechanism (user report 2026-11-15): 4K plays smooth in ZoroX
/// until the phone heats up, then it gets laggy and never recovers —
/// Nuvio does not do this. The likely cause is the VideoToolbox session
/// being invalidated under thermal pressure: without
/// `hwdec-software-fallback` (now set on iOS too, see
/// [mpv_ios_options.dart]) mpv fell to software decode for the rest of
/// the file, burning CPU and making more heat. This governor is the
/// second half: when the OS itself says the phone is serious or critical,
/// drop the 4K stream for the best lighter one, so the decoder has less
/// work and the phone can cool; restore the original when it stays
/// nominal for a minute.
///
/// The governor is pure: it decides, the player screen acts. It keeps
/// the drop episode's state — what it dropped from and to, the nominal
/// streak, and whether the viewer has taken over by hand. A hand pick
/// always stands: the governor never overrides a source the viewer chose
/// while the hot episode lasts.
library;

import 'package:flutter/foundation.dart';

import '../../../../core/providers/thermal_state.dart';

/// What the governor wants the player to do on this tick.
enum ThermalQualityKind {
  /// No change.
  none,

  /// Switch to [ThermalQualityDecision.targetIndex], a lighter stream.
  drop,

  /// Switch back to [ThermalQualityDecision.targetIndex], the stream the
  /// drop left.
  restore,

  /// No switch: tell the viewer the phone is hot and the Quality tab has
  /// lighter streams. Only for an adaptive (HLS) master, which has no
  /// ladder to switch down — mpv's ABR picks the rendition.
  hint,
}

/// One tick's decision: [kind] + the stream index to switch to.
/// [targetIndex] is -1 for [ThermalQualityKind.none] and
/// [ThermalQualityKind.hint], which switch nothing.
@immutable
class ThermalQualityDecision {
  const ThermalQualityDecision.none()
    : kind = ThermalQualityKind.none,
      targetIndex = -1;

  const ThermalQualityDecision.drop(this.targetIndex)
    : kind = ThermalQualityKind.drop;

  const ThermalQualityDecision.restore(this.targetIndex)
    : kind = ThermalQualityKind.restore;

  const ThermalQualityDecision.hint()
    : kind = ThermalQualityKind.hint,
      targetIndex = -1;

  final ThermalQualityKind kind;
  final int targetIndex;

  bool get isNone => kind == ThermalQualityKind.none;
}

/// Decides, per tick, whether the phone's heat wants a quality change.
///
/// Fed the OS thermal state, every stream's height (`null` or `0` for an
/// adaptive HLS master — see `StreamResult.quality`) and the stream now
/// playing. The screen calls [evaluate] on its thermal timer and acts on
/// the decision; it calls [noteManualPick] from the source/Quality pick
/// path, so a hand pick is never overridden.
class ThermalQualityGovernor {
  ThermalQualityGovernor({
    this.dropAboveHeight = 1080,
    this.restoreNominalTicks = 2,
  });

  /// A stream taller than this is heavy: dropped when the phone is hot.
  final int dropAboveHeight;

  /// Consecutive nominal ticks before the original stream is restored.
  final int restoreNominalTicks;

  int? _droppedFrom;
  int? _droppedTo;
  int? _manualPickIndex;
  int _nominalStreak = 0;
  bool _hintShown = false;

  /// True while a governor drop is in effect.
  bool get isDropped => _droppedFrom != null;

  /// The viewer picked a source by hand. A hand pick stands until the
  /// phone cools: the governor never overrides it while this hot episode
  /// lasts. A tap on the stream the governor itself dropped to is a
  /// no-op, not a pick.
  void noteManualPick(int index) {
    if (_droppedTo != null && index == _droppedTo) return;
    _manualPickIndex = index;
  }

  /// One tick's decision. Never throws: a bad index or an empty list is
  /// no change.
  ThermalQualityDecision evaluate({
    required ThermalState thermal,
    required List<int?> qualities,
    required int currentIndex,
  }) {
    if (currentIndex < 0 || currentIndex >= qualities.length) {
      return const ThermalQualityDecision.none();
    }
    final height = qualities[currentIndex];

    if (_droppedFrom != null) {
      if (currentIndex == _droppedFrom) {
        // Back on the original — the restore landed, or the viewer
        // re-picked it by hand. The episode is over, and the hand pick
        // stands if it was one.
        _manualPickIndex = currentIndex;
        _clearDrop();
        return const ThermalQualityDecision.none();
      }
      if (currentIndex != _droppedTo) {
        // The viewer picked a third source mid-episode: their choice
        // stands, the drop is over.
        _manualPickIndex = currentIndex;
        _clearDrop();
        return const ThermalQualityDecision.none();
      }
      // Still on the dropped-to stream: watch for cooling. Anything but
      // nominal — including an unreadable state — resets the streak, so
      // the restore only happens on a phone that is really cool.
      if (thermal == ThermalState.nominal) {
        _nominalStreak++;
        if (_nominalStreak >= restoreNominalTicks) {
          final from = _droppedFrom!;
          _clearDrop();
          return ThermalQualityDecision.restore(from);
        }
      } else {
        _nominalStreak = 0;
      }
      return const ThermalQualityDecision.none();
    }

    // Not dropped. A hand pick stands until the phone cools; a pick that
    // is no longer current (failover, a new episode's auto-open) is
    // forgotten.
    if (_manualPickIndex != null) {
      if (currentIndex == _manualPickIndex) {
        if (thermal == ThermalState.nominal) _manualPickIndex = null;
        return const ThermalQualityDecision.none();
      }
      _manualPickIndex = null;
    }
    if (thermal == ThermalState.nominal) {
      // Cool again: a fresh episode starts, the hint may show again.
      _hintShown = false;
      return const ThermalQualityDecision.none();
    }
    if (thermal != ThermalState.serious &&
        thermal != ThermalState.critical) {
      // Fair: warm but not throttling — watch, don't act.
      return const ThermalQualityDecision.none();
    }

    // Hot from here. An adaptive master has no ladder to switch down:
    // one hint per episode, and the viewer picks in the Quality tab.
    if (height == null || height == 0) {
      if (_hintShown) return const ThermalQualityDecision.none();
      _hintShown = true;
      return const ThermalQualityDecision.hint();
    }
    if (height <= dropAboveHeight) return const ThermalQualityDecision.none();
    final target = _bestLighterIndex(qualities, height);
    if (target == null) return const ThermalQualityDecision.none();
    _droppedFrom = currentIndex;
    _droppedTo = target;
    _nominalStreak = 0;
    return ThermalQualityDecision.drop(target);
  }

  /// The best lighter stream: the tallest one at or below the drop
  /// height, or — when no stream is that light — the tallest one below
  /// the current height. Null when nothing is lighter.
  int? _bestLighterIndex(List<int?> qualities, int currentHeight) {
    int? bestBelow;
    int? bestLight;
    for (var i = 0; i < qualities.length; i++) {
      final quality = qualities[i];
      if (quality == null || quality <= 0 || quality >= currentHeight) {
        continue;
      }
      if (bestBelow == null || quality > qualities[bestBelow]!) {
        bestBelow = i;
      }
      if (quality <= dropAboveHeight &&
          (bestLight == null || quality > qualities[bestLight]!)) {
        bestLight = i;
      }
    }
    return bestLight ?? bestBelow;
  }

  void _clearDrop() {
    _droppedFrom = null;
    _droppedTo = null;
    _nominalStreak = 0;
  }
}
