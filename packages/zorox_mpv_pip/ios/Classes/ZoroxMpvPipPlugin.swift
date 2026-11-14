import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Flutter
import Foundation
import UIKit

/// iOS Picture-in-Picture for the mpv (Golden) player.
///
/// iOS PiP needs an `AVPlayerLayer` or an `AVSampleBufferDisplayLayer`;
/// mpv has neither, and libmpv allows only one render context per core, so
/// a second renderer for PiP is impossible. This plugin therefore taps the
/// frames the forked `media_kit_video` software renderer already produces:
/// `TextureSW` posts every completed frame on the
/// `ZoroXMpvRenderedFrame` notification (see `packages/media_kit_video/
/// FORK.md`), this plugin copies the frame synchronously into its own pool
/// — the renderer's pool has only 3 buffers — wraps it as a
/// `CMSampleBuffer`, and enqueues it into an `AVSampleBufferDisplayLayer`
/// that drives an `AVPictureInPictureController`.
///
/// Only the software renderer can feed it: GPU work is not allowed while
/// the app is in the background, and PiP runs while backgrounded. The
/// player therefore runs with `enableHardwareAcceleration: false` plus
/// `hwdec: videotoolbox-copy` (hardware decode, software render) whenever
/// the iOS mpv PiP setting is on. Cost: no shaders, HDR looks washed out,
/// 4K is heavy — which is why PiP is behind a setting, off by default.
///
/// Public APIs only, no entitlement; the app already declares the `audio`
/// background mode. Flutter subtitles never appear in the PiP window — the
/// overlay is a Flutter widget. mpv's own subtitles do: the Dart side
/// switches `sub-visibility` on when PiP actually starts and restores it
/// when PiP stops, so they burn into the frame.
///
/// Own channel `dev.akash.skystream.player/pip_mpv_ios` — deliberately NOT
/// `dev.akash.skystream.player/pip`, which the libVLC side already uses;
/// reusing that name would replace its handler.
public class ZoroxMpvPipPlugin: NSObject, FlutterPlugin,
  AVPictureInPictureControllerDelegate,
  AVPictureInPictureSampleBufferPlaybackDelegate
{
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dev.akash.skystream.player/pip_mpv_ios",
      binaryMessenger: registrar.messenger()
    )
    let instance = ZoroxMpvPipPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  /// The notification the forked media_kit_video software renderer posts
  /// with each completed frame (`CVPixelBuffer` as the object).
  private static let frameNotification = Notification.Name(
    "ZoroXMpvRenderedFrame"
  )

  private let channel: FlutterMethodChannel

  private var pip: AVPictureInPictureController?
  private var timebase: CMTimebase?
  private var layer: AVSampleBufferDisplayLayer?
  private var hostView: UIView?
  private var frameObserver: NSObjectProtocol?

  private var pipActive = false
  private var armed = false
  private var prepared = false
  private var playing = false
  private var duration: Double = 0
  private var lastPosition: Double = 0
  private var rate: Double = 1

  private let lock = NSLock()
  private var pool: CVPixelBufferPool?
  private var poolW = 0
  private var poolH = 0
  private let frameQueue = DispatchQueue(
    label: "dev.akash.skystream.pip.frame"
  )
  private var frameCount = 0
  private var lastFrameTime: CFAbsoluteTime = 0

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  deinit {
    if let observer = frameObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  // MARK: - MethodChannel

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "isSupported":
      result(AVPictureInPictureController.isPictureInPictureSupported())
    case "prepare":
      guard let args = call.arguments as? [String: Any] else {
        result(
          FlutterError(
            code: "bad_args",
            message: "prepare needs position/duration/playing",
            details: nil
          )
        )
        return
      }
      result(prepare(args))
    case "updateState":
      if let args = call.arguments as? [String: Any] {
        apply(args)
      }
      result(nil)
    case "enterPip":
      enter(result)
    case "exitPip":
      pip?.stopPictureInPicture()
      result(nil)
    case "release":
      release()
      result(nil)
    case "diag":
      result(diag())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Session

  private func prepare(_ args: [String: Any]) -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      return false
    }
    guard let rootView = hostRootView() else {
      return false
    }
    if pip == nil {
      let displayLayer = AVSampleBufferDisplayLayer()
      displayLayer.videoGravity = .resizeAspect

      // Full-window host behind Flutter's view, NOT hidden: PiP refuses
      // to start for a layer that is hidden or outside the window
      // hierarchy. Flutter's own view sits on top of it, so the layer
      // never shows inline — it only feeds the PiP window.
      let host = UIView(frame: rootView.bounds)
      host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      host.isHidden = false
      displayLayer.frame = host.bounds
      host.layer.addSublayer(displayLayer)
      rootView.insertSubview(host, at: 0)

      // CMTimebase(masterClock:) throws in this SDK; a failed timebase
      // means PiP cannot be prepared.
      guard let tb = try? CMTimebase(masterClock: CMClockGetHostTimeClock())
      else { return false }
      displayLayer.controlTimebase = tb

      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayLayer,
        playbackDelegate: self
      )
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self
      // Armed per playback state in apply(): auto-PiP only while playing.
      controller.canStartPictureInPictureAutomaticallyFromInline = false

      self.layer = displayLayer
      self.hostView = host
      self.timebase = tb
      self.pip = controller
    }

    apply(args)

    lock.lock()
    armed = true
    lock.unlock()

    // queue: nil delivers synchronously on the posting thread — the
    // media_kit worker thread that just rendered the frame — so the
    // copy in ingest() reads the buffer before the renderer reuses it.
    if frameObserver == nil {
      frameObserver = NotificationCenter.default.addObserver(
        forName: Self.frameNotification,
        object: nil,
        queue: nil
      ) { [weak self] note in
        // Swift 6 flags a conditional downcast from Any to the CF type
        // CVPixelBuffer as always succeeding, so check the
        // CoreFoundation type ID first, then force-cast.
        guard let obj = note.object,
              CFGetTypeID(obj as CFTypeRef) == CVPixelBufferGetTypeID()
        else { return }
        self?.ingest(obj as! CVPixelBuffer)
      }
    }

    prepared = true
    return true
  }

  private func apply(_ args: [String: Any]) {
    lastPosition = num(args, "position")
    duration = num(args, "duration")
    playing = (args["playing"] as? Bool) ?? false
    rate = args["rate"] != nil ? num(args, "rate") : 1.0

    if let tb = timebase {
      CMTimebaseSetTime(
        tb,
        time: CMTime(seconds: max(lastPosition, 0), preferredTimescale: 1000)
      )
      CMTimebaseSetRate(tb, rate: playing ? rate : 0)
    }
    // Auto-PiP when the app goes to background, only while actually
    // playing: a paused film never auto-opens.
    pip?.canStartPictureInPictureAutomaticallyFromInline = playing
    pip?.invalidatePlaybackState()
  }

  private func enter(_ result: @escaping FlutterResult) {
    guard let pip = pip else {
      result(
        FlutterError(
          code: "not_prepared",
          message: "call prepare first",
          details: nil
        )
      )
      return
    }
    if pip.isPictureInPictureActive {
      result(true)
      return
    }
    if pip.isPictureInPicturePossible {
      pip.startPictureInPicture()
      result(true)
      return
    }
    result(
      FlutterError(code: "not_possible", message: diag(), details: nil)
    )
  }

  private func release() {
    pip?.stopPictureInPicture()
    pip = nil
    timebase = nil
    if let l = layer {
      l.flushAndRemoveImage()
      l.removeFromSuperlayer()
    }
    layer = nil
    hostView?.removeFromSuperview()
    hostView = nil
    if let observer = frameObserver {
      NotificationCenter.default.removeObserver(observer)
      frameObserver = nil
    }
    pool = nil
    lock.lock()
    armed = false
    prepared = false
    lock.unlock()
  }

  private func hostRootView() -> UIView? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
    return window?.rootViewController?.view
  }

  private func num(_ args: [String: Any], _ key: String) -> Double {
    if let n = args[key] as? NSNumber { return n.doubleValue }
    if let d = args[key] as? Double { return d }
    return 0
  }

  /// Layer status, whether the layer is in a window, whether PiP can
  /// start, the audio category, and how many frames the tap delivered —
  /// the first thing to check when PiP fails on a phone.
  private func diag() -> String {
    "layer=\(layer?.status.rawValue ?? -1) "
      + "inWindow=\(hostView?.window != nil) "
      + "possible=\(pip?.isPictureInPicturePossible ?? false) "
      + "audio=\(AVAudioSession.sharedInstance().category.rawValue) "
      + "frames=\(frameCount)"
  }

  // MARK: - Frame ingest

  private func ingest(_ pb: CVPixelBuffer) {
    lock.lock()
    let isArmed = armed
    let targetLayer = layer
    lock.unlock()
    guard isArmed, let layer = targetLayer else { return }

    // Before PiP starts the frames only prove the tap works: ~5 fps is
    // enough and saves the CPU. Once the window is up, full rate.
    let now = CFAbsoluteTimeGetCurrent()
    if !pipActive && now - lastFrameTime < 0.2 { return }
    lastFrameTime = now

    guard
      let dst = makeBuffer(
        CVPixelBufferGetWidth(pb),
        CVPixelBufferGetHeight(pb)
      )
    else { return }
    copyFrame(src: pb, dst: dst)
    frameQueue.async { [weak self] in
      self?.enqueue(dst, on: layer)
    }
  }

  /// Synchronous copy into our own IOSurface-backed BGRA pool: the
  /// renderer reuses its buffer on the next render, so the tap's buffer
  /// must not be handed to the display layer as-is.
  private func copyFrame(src: CVPixelBuffer, dst: CVPixelBuffer) {
    let w = CVPixelBufferGetWidth(src)
    let h = CVPixelBufferGetHeight(src)
    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(dst, [])
    defer {
      CVPixelBufferUnlockBaseAddress(src, .readOnly)
      CVPixelBufferUnlockBaseAddress(dst, [])
    }
    guard
      let s = CVPixelBufferGetBaseAddress(src),
      let d = CVPixelBufferGetBaseAddress(dst)
    else { return }
    let sb = CVPixelBufferGetBytesPerRow(src)
    let db = CVPixelBufferGetBytesPerRow(dst)
    if sb == db {
      memcpy(d, s, sb * h)
    } else {
      for y in 0..<h {
        memcpy(d + y * db, s + y * sb, min(sb, db))
      }
    }
  }

  private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
    lock.lock()
    defer { lock.unlock() }
    if pool == nil || poolW != w || poolH != h {
      let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w,
        kCVPixelBufferHeightKey as String: h,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      ]
      var p: CVPixelBufferPool?
      CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
        attrs as CFDictionary,
        &p
      )
      pool = p
      poolW = w
      poolH = h
    }
    guard let pool = pool else { return nil }
    var out: CVPixelBuffer?
    return CVPixelBufferPoolCreatePixelBuffer(
      kCFAllocatorDefault,
      pool,
      &out
    ) == kCVReturnSuccess ? out : nil
  }

  private func enqueue(_ pb: CVPixelBuffer, on layer: AVSampleBufferDisplayLayer) {
    if layer.status == .failed { layer.flush() }
    // Drop rather than queue up: a backlog would show stale frames and
    // grow without bound while the renderer is not ready.
    guard layer.isReadyForMoreMediaData else { return }
    var fmt: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pb,
      formatDescriptionOut: &fmt
    )
    guard let fd = fmt else { return }
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(
        seconds: CFAbsoluteTimeGetCurrent(),
        preferredTimescale: 1000
      ),
      decodeTimeStamp: .invalid
    )
    var sb: CMSampleBuffer?
    let st = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pb,
      formatDescription: fd,
      sampleTiming: &timing,
      sampleBufferOut: &sb
    )
    guard st == noErr, let s = sb else { return }
    // mpv already timed the display; without this, frames judged late
    // are dropped silently — the classic black or frozen PiP.
    // The dictionaries returned by CMSampleBufferGetSampleAttachmentsArray
    // are the sample buffer's live attachments, so mutating the first
    // one in place is enough — no setter call needed.
    // (CMSampleBufferSetSampleAttachmentsArray is not visible to Swift
    // in this SDK, and the old code also subscripted the array itself
    // with a String key instead of its first dictionary.)
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      s,
      createIfNecessary: true
    ) as? [NSMutableDictionary],
      let dict = attachments.first
    {
      dict.setObject(
        true,
        forKey: kCMSampleAttachmentKey_DisplayImmediately as NSString
      )
    }
    layer.enqueue(s)
    frameCount += 1
  }

  // MARK: - AVPictureInPictureControllerDelegate

  public func pictureInPictureControllerWillStartPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    // Full-rate frames from here on.
    pipActive = true
  }

  public func pictureInPictureControllerDidStartPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    channel.invokeMethod("pipStarted", arguments: nil)
  }

  public func pictureInPictureControllerDidStopPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    pipActive = false
    channel.invokeMethod("pipStopped", arguments: ["restored": false])
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
      completionHandler: @escaping (Bool) -> Void
  ) {
    pipActive = false
    channel.invokeMethod("pipStopped", arguments: ["restored": true])
    completionHandler(true)
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    pipActive = false
    channel.invokeMethod(
      "pipFailed",
      arguments: ["reason": "\(error.localizedDescription) | \(diag())"]
    )
  }

  // didTransitionToRenderSize is intentionally omitted: CMVideoSize is
  // not in scope for Swift in this SDK, and the method would be a no-op
  // anyway — aspect is preserved by the layer's .resizeAspect gravity.

  public func pictureInPictureControllerIsPlaybackPaused(
    _ controller: AVPictureInPictureController
  ) -> Bool {
    !playing
  }

  public func pictureInPictureControllerTimeRangeForPlayback(
    _ controller: AVPictureInPictureController
  ) -> CMTimeRange {
    if duration > 0 && duration.isFinite {
      return CMTimeRange(
        start: .zero,
        duration: CMTime(seconds: duration, preferredTimescale: 1000)
      )
    }
    return CMTimeRange(
      start: .negativeInfinity,
      duration: .positiveInfinity
    )
  }

  // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    self.playing = playing
    channel.invokeMethod("pipSetPlaying", arguments: playing)
    pip?.invalidatePlaybackState()
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    channel.invokeMethod("pipSkip", arguments: Int(skipInterval.seconds))
    completionHandler()
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    timeToSeekTo time: CMTime,
    completion completionHandler: @escaping (Bool) -> Void
  ) {
    channel.invokeMethod(
      "pipSkip",
      arguments: Int(time.seconds - lastPosition)
    )
    completionHandler(true)
  }
}
