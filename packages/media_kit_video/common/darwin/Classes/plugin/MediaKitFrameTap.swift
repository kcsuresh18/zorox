import CoreVideo
import Foundation

/// Frame-export tap for ZoroX's iOS mpv Picture-in-Picture.
///
/// ZoroX fork addition (see FORK.md): the software renderer ([TextureSW])
/// posts every completed frame on this notification. The ZoroX PiP plugin
/// (`zorox_mpv_pip`) observes it and copies the frame into its own pool —
/// it must copy synchronously on receipt, because [TextureSW] reuses a
/// 3-buffer pool and the next render may overwrite this buffer.
///
/// Deliberately `NotificationCenter`, not a direct call: the PiP plugin is
/// a separate module and must not import `media_kit_video`. The post costs
/// one no-op dispatch while nobody observes it, so normal playback — and
/// every platform the PiP plugin does not run on — is unaffected.
///
/// The notification is posted on the media_kit worker thread that ran the
/// render, while the buffer is still locked by the renderer, so the memory
/// is stable for the observer's synchronous copy.
public extension Notification.Name {
  static let zoroxMpvRenderedFrame = Notification.Name(
    "ZoroXMpvRenderedFrame",
  )
}
