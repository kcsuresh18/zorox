# media_kit_video fork (ZoroX)

Fork of `media_kit_video` 2.0.1 (pub.dev), vendored under
`packages/media_kit_video` and wired through `dependency_overrides` in the
app's `pubspec.yaml`. Everything is byte-identical to 2.0.1 except the one
change below.

## The change — frame-export tap for iOS mpv Picture-in-Picture (+28)

iOS PiP needs an `AVPlayerLayer` or an `AVSampleBufferDisplayLayer`; mpv
has neither, and libmpv allows only one render context per core, so a
second renderer for PiP is not possible. The PiP plugin therefore taps the
frames the software renderer already produces.

- `ios/Classes/plugin/common/MediaKitFrameTap.swift` (new; same file also
  copied to `macos/Classes/plugin/common/` and `common/darwin/Classes/plugin/`
  to keep the three copies of this renderer in sync): defines the
  `Notification.Name.zoroxMpvRenderedFrame` notification.
- `TextureSW.render(_:)` (same three copies): after
  `mpv_render_context_render` completes and the buffer is marked ready,
  posts the completed `CVPixelBuffer` on that notification.

The post is a no-op while nobody observes it, so normal playback is
unaffected. The hook fires only on the software-render path
(`enableHardwareAcceleration: false`), which is what the iOS mpv PiP
setting selects; the hardware (OpenGL ES) path is untouched. The buffer is
one of a 3-buffer pool, so the observer must copy it synchronously — the
PiP plugin (`packages/zorox_mpv_pip`) does exactly that into its own
IOSurface-backed BGRA pool.

## Updating

To rebase onto a newer media_kit_video: copy the new version over this
directory, re-apply the two files above (the hook is 8 lines at the end of
`TextureSW.render(_:)` plus the `MediaKitFrameTap.swift` file), and keep
this note current.
