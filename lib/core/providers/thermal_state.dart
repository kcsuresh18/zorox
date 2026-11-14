/// The phone's thermal state (iOS `ProcessInfo.thermalState`): how hot the
/// device is running, so the player can lighten its load before the OS
/// throttles it.
///
/// Read on the `dev.akash.skystream/device_memory` channel, the same
/// channel the memory reading comes on (see [deviceMemoryChannel]): its
/// `thermalState` method answers the raw `ProcessInfo.thermalState`
/// value — 0 nominal, 1 fair, 2 serious, 3 critical. iOS only; every
/// other platform answers unknown, never a guess.
library;

import 'package:flutter/foundation.dart';

import 'device_memory.dart';

/// The phone's heat, in the OS's own words.
enum ThermalState {
  /// Cool: full speed.
  nominal,

  /// Warm: no throttling yet.
  fair,

  /// Hot: the OS is throttling; a 4K hardware decode is the first thing
  /// to suffer (see `mpv_thermal_quality.dart`).
  serious,

  /// Very hot: throttling hard.
  critical,

  /// The platform didn't say (not iOS, or the read failed).
  unknown,
}

/// The raw channel value as a [ThermalState]. Anything outside 0–3 is
/// unknown, never a guess.
ThermalState thermalStateFromRaw(Object? value) {
  return switch (value) {
    0 => ThermalState.nominal,
    1 => ThermalState.fair,
    2 => ThermalState.serious,
    3 => ThermalState.critical,
    _ => ThermalState.unknown,
  };
}

/// Reads the phone's thermal state now. Never throws: what can't be read
/// is unknown.
Future<ThermalState> readThermalState() async {
  try {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return ThermalState.unknown;
    }
    return thermalStateFromRaw(
      await deviceMemoryChannel.invokeMethod<Object?>('thermalState'),
    );
  } on Object {
    return ThermalState.unknown;
  }
}
