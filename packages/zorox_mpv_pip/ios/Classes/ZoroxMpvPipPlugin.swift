import Accelerate
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Flutter
import Foundation
import UIKit

/// Host view for the PiP display layer. CALayer sublayers do NOT follow
/// their superlayer's bounds, so the host must push its size into the
/// layer on every layout pass. Without this, a layer framed while the
/// window was portrait keeps a portrait frame after the player rotates
/// to landscape — and PiP opens a narrow vertical strip (+29).
private final class PipHostView: UIView {
  weak var displayLayer: AVSampleBufferDisplayLayer?

  override func layoutSubviews() {
    super.layoutSubviews()
    if let layer = displayLayer, layer.frame != bounds {
      layer.frame = bounds
    }
  }
}

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
/// +29: frames are enqueued ONLY while the PiP window is actually up
/// (gated on the PiP delegate, not the request), the feed is downscaled
/// to ~640 px wide (vImage), and the in-app Video widget is unmounted
/// while PiP is up — the +28 build drew the film twice (Flutter texture
/// + PiP layer), saturating the CPU (cut-cut voice, dropped frames) and
/// leaving a second copy of the video visible inside the app. The
/// display layer also tracks the window on rotation now: a layer framed
/// while portrait stayed portrait after the player rotated, and PiP
/// opened a narrow vertical strip.
///
/// +30: +29's gate broke PiP completely — the window never opens, on
/// either the button or the home-swipe path. Chicken-and-egg:
/// startPictureInPicture() refuses while the layer is EMPTY
/// (isPictureInPicturePossible == false), but pipActive is only set
/// once PiP WILL start, so no frame is ever enqueued. The +28 build
/// opened because its ~5 fps trickle kept a frame in the layer. The
/// fix is a PRIME: the latest frame is held in memory (never enqueued)
/// and pushed into the layer only at the moment a start is attempted —
/// synchronously in enter(), and when the app backgrounds (for
/// auto-PiP), with a flush on become-active if PiP never started.
/// There is deliberately NO standing trickle: the host view is a
/// subview of the FlutterView itself, so it renders ABOVE the Metal
/// layer — any frame in the display layer shows on top of the player
/// as a second copy. The +28 video proves it: the second copy was
/// full-width with shifted, clipped subtitles, i.e. the layer's own
/// video rect on top of the Flutter scene, not Flutter's video showing
/// through. So the layer stays empty in-app and is primed only when
/// a start is imminent.
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

  // MARK: - Prime (+30)
  //
  // The latest rendered frame, held in memory (never enqueued) so a
  // PiP start always has a frame to push into the layer. Two slots,
  // ping-pong: ingest() writes only the INACTIVE slot and then swaps
  // the current pointer under the lock, so a buffer being enqueued by
  // enter() is never overwritten mid-copy. The slots are plain
  // CVPixelBuffers (not from the live-feed pool) so holding one can
  // never starve the live feed. Refreshed at most ~5 fps while the
  // player runs; a paused film keeps its last frame, which is exactly
  // the frame PiP should open on.
  private var primeBuffers: [CVPixelBuffer?] = [nil, nil]
  private var primeCurrent = 0
  private var primeReady = false
  private var primeUpdatedAt: CFAbsoluteTime = 0
  private var primeW = 0
  private var primeH = 0
  private var primeCount = 0
  private var lastPrimedAt: CFAbsoluteTime = 0
  private var enterPending = false
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  deinit {
    if let observer = frameObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    for observer in lifecycleObservers {
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

      // Full-window host, NOT hidden: PiP refuses to start for a layer
      // that is hidden or outside the window hierarchy. NOTE the host
      // is a subview of the FlutterView itself, so it renders ABOVE
      // the Metal layer — the layer is NOT hidden behind Flutter's
      // view. Any frame in it shows on top of the player as a second
      // copy (+28). The layer therefore stays EMPTY in-app and is
      // primed only when a start is imminent (+30). The host is a
      // PipHostView (+29) so the layer tracks the window on rotation:
      // a plain sublayer keeps the frame it was created with.
      let host = PipHostView(frame: rootView.bounds)
      host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      host.isHidden = false
      displayLayer.frame = host.bounds
      host.displayLayer = displayLayer
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

    // +30: auto-PiP is evaluated by the system as the app backgrounds,
    // with no Dart call in between — the layer must already hold a
    // frame then. Prime it on resign-active (and again on entering
    // background, second chance), and flush on become-active if PiP
    // never started, so no frozen frame lingers on top of the player.
    // didBecomeActive (not willEnterForeground): resign-active also
    // fires for transient interruptions (Control Center, a call) where
    // the app never backgrounds, and only become-active follows those.
    // Main queue: these notifications arrive there.
    if lifecycleObservers.isEmpty {
      let center = NotificationCenter.default
      lifecycleObservers.append(
        center.addObserver(
          forName: UIApplication.willResignActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in self?.primeForBackground() }
      )
      lifecycleObservers.append(
        center.addObserver(
          forName: UIApplication.didEnterBackgroundNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in self?.primeForBackground() }
      )
      lifecycleObservers.append(
        center.addObserver(
          forName: UIApplication.didBecomeActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in self?.clearStalePrime() }
      )
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

  /// Pushes the host's current bounds into the display layer. The
  /// host's layoutSubviews does this on every rotation; this is the
  /// belt-and-braces call right before PiP starts, so the window is
  /// shaped by the window's size now, not by the size at prepare time.
  private func syncLayerFrame() {
    guard let host = hostView, let layer = layer else { return }
    if layer.frame != host.bounds {
      layer.frame = host.bounds
    }
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
    // One enter at a time: a double-tap on the button must not run two
    // poll loops against the same result callback.
    lock.lock()
    let already = enterPending
    if !already { enterPending = true }
    lock.unlock()
    guard !already else {
      result(
        FlutterError(code: "busy", message: "PiP start already running", details: nil)
      )
      return
    }
    syncLayerFrame()
    // +30: the layer MUST hold a frame before startPictureInPicture —
    // an empty layer reports isPictureInPicturePossible == false and
    // the start refuses (the +29 regression). Prime it with the latest
    // held frame, then poll for possible: the layer processes the
    // enqueued buffer asynchronously, so possible may flip true a
    // beat after the enqueue. The Dart side has a 5 s watchdog, so a
    // ~1 s wait here is safe.
    attemptEnter(pip: pip, result: result, attemptsLeft: 20)
  }

  /// One tick of the enter() poll. Prime the layer if a newer held
  /// frame arrived since the last prime, then start when possible.
  /// Runs on the main queue (MethodChannel handlers are main-thread).
  private func attemptEnter(
    pip: AVPictureInPictureController,
    result: @escaping FlutterResult,
    attemptsLeft: Int
  ) {
    // Keep the layer's image fresh while we wait: a newer prime
    // replaces the stale one.
    if let prime = takePrimeIfNewer() {
      enqueuePrime(prime)
    }
    if pip.isPictureInPictureActive {
      finishEnter(result: result, success: true)
      return
    }
    if pip.isPictureInPicturePossible {
      syncLayerFrame()
      pip.startPictureInPicture()
      finishEnter(result: result, success: true)
      return
    }
    if attemptsLeft > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self = self else { return }
        self.attemptEnter(
          pip: pip,
          result: result,
          attemptsLeft: attemptsLeft - 1
        )
      }
      return
    }
    // Still impossible after ~1 s: flush the prime so no frozen frame
    // lingers on top of the player, and report with diag.
    layer?.flushAndRemoveImage()
    finishEnter(result: result, success: false)
  }

  /// Clears the enter guard and answers the MethodChannel call exactly
  /// once. A failure carries the diag string so a future "PiP doesn't
  /// open" can be told apart from a layer problem.
  private func finishEnter(result: @escaping FlutterResult, success: Bool) {
    lock.lock()
    enterPending = false
    lock.unlock()
    if success {
      result(true)
    } else {
      result(
        FlutterError(code: "not_possible", message: diag(), details: nil)
      )
    }
  }

  /// Pushes the held prime frame into the display layer, synchronously
  /// on the calling (main) thread. The prime is copied into a fresh
  /// pool buffer first: the held slot will be overwritten by a later
  /// refresh, and the copy must never be torn mid-enqueue. Returns
  /// false when the layer isn't ready — the caller retries on the next
  /// poll tick.
  @discardableResult
  private func enqueuePrime(_ pb: CVPixelBuffer) -> Bool {
    guard let layer = layer, layer.isReadyForMoreMediaData else {
      return false
    }
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    guard let dst = makeBuffer(w, h) else { return false }
    copyFrame(src: pb, dst: dst)
    enqueue(dst, on: layer)
    lock.lock()
    primeCount += 1
    lastPrimedAt = CFAbsoluteTimeGetCurrent()
    lock.unlock()
    return true
  }

  /// Auto-PiP prime (+30): the system evaluates auto-PiP as the app
  /// backgrounds, with no Dart call in between — the layer must already
  /// hold a frame then, or the system silently skips it (the +29
  /// home-swipe failure). Only while actually playing: a paused film
  /// never auto-opens, so no prime is needed. The frame is on top of
  /// the player only while the app is leaving the screen, so the user
  /// never sees it; clearStalePrime() removes it on foreground return
  /// if PiP never started.
  private func primeForBackground() {
    guard prepared, playing, !pipActive else { return }
    guard let prime = takePrime(), let layer = layer else { return }
    syncLayerFrame()
    enqueuePrime(prime)
  }

  /// Back active without PiP up: a background prime that never became
  /// a window would sit on top of the player as a frozen frame. Flush
  /// it. This also covers transient interruptions (Control Center, a
  /// call): resign-active primes, become-active follows without any
  /// foreground transition. Harmless when PiP did start — the live
  /// feed is already flowing and the flush only clears a stale image.
  private func clearStalePrime() {
    guard !pipActive else { return }
    layer?.flushAndRemoveImage()
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
    for observer in lifecycleObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    lifecycleObservers = []
    pool = nil
    lock.lock()
    armed = false
    pipActive = false
    prepared = false
    primeBuffers = [nil, nil]
    primeReady = false
    primeUpdatedAt = 0
    primeW = 0
    primeH = 0
    enterPending = false
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
  /// start, the audio category, how many frames reached the PiP
  /// layer — and the prime state (+30): whether a frame is held ready
  /// for a start, how old it is, and how many primes were enqueued.
  /// The first thing to check when PiP fails on a phone: primed=false
  /// means no frame ever arrived (renderer tap broken); primed=true
  /// with possible=false means the layer saw the prime but the
  /// controller still refuses.
  private func diag() -> String {
    lock.lock()
    let pReady = primeReady
    let pAgeMs = primeReady
      ? Int((CFAbsoluteTimeGetCurrent() - primeUpdatedAt) * 1000)
      : -1
    let pCount = primeCount
    lock.unlock()
    return "layer=\(layer?.status.rawValue ?? -1) "
      + "inWindow=\(hostView?.window != nil) "
      + "possible=\(pip?.isPictureInPicturePossible ?? false) "
      + "audio=\(AVAudioSession.sharedInstance().category.rawValue) "
      + "frames=\(frameCount) "
      + "primed=\(pReady) primeAgeMs=\(pAgeMs) primes=\(pCount)"
  }

  // MARK: - Frame ingest

  private func ingest(_ pb: CVPixelBuffer) {
    lock.lock()
    let isArmed = armed
    let isPipActive = pipActive
    let targetLayer = layer
    lock.unlock()
    guard isArmed, let layer = targetLayer else { return }

    // The PiP window is small: full-res 1080p frames through the copy
    // + compositor are wasted work and helped saturate the CPU (+29).
    // Cap the feed at ~640 px wide; the aspect is preserved and the
    // height is kept even (BGRA rows).
    let sw = CVPixelBufferGetWidth(pb)
    let sh = CVPixelBufferGetHeight(pb)
    let maxPipWidth = 640
    let tw: Int
    let th: Int
    if sw > maxPipWidth {
      tw = maxPipWidth
      th = max(2, (sh * maxPipWidth / sw) & ~1)
    } else {
      tw = sw
      th = sh
    }

    // Frames feed the PiP window ONLY while it is actually up (+29):
    // the host view is a subview of the FlutterView itself, so it
    // renders ABOVE the Metal layer — any frame enqueued while the app
    // is in the foreground shows as a second copy of the video inside
    // the app (the +28 second screen). While PiP is NOT up, the frame
    // only refreshes the held prime (+30): a copy in memory, never
    // enqueued, so the layer stays empty in-app and a start always
    // has a fresh frame to push.
    if isPipActive {
      guard let dst = makeBuffer(tw, th) else { return }
      copyFrame(src: pb, dst: dst)
      frameQueue.async { [weak self] in
        self?.enqueue(dst, on: layer)
      }
      return
    }
    refreshPrime(pb, tw: tw, th: th)
  }

  // MARK: - Prime (+30)

  /// Refreshes the held prime with the latest rendered frame, at most
  /// ~5 fps. Runs on the media_kit render thread (ingest is called
  /// synchronously from the frame notification). The copy goes into
  /// the INACTIVE slot and the swap happens under the lock, so a
  /// buffer being enqueued by enter() is never overwritten mid-copy.
  /// One ~640 px vImage scale per 200 ms is negligible next to the
  /// render work itself.
  private func refreshPrime(_ pb: CVPixelBuffer, tw: Int, th: Int) {
    let now = CFAbsoluteTimeGetCurrent()
    lock.lock()
    let last = primeUpdatedAt
    let current = primeCurrent
    let pw = primeW
    let ph = primeH
    let existing = primeBuffers[1 - current]
    lock.unlock()
    guard now - last >= 0.2 else { return }

    // Reuse the inactive slot's buffer when it already has the right
    // size; otherwise create a fresh one. The buffer object is only
    // ever written here, on the render thread, and the array slot is
    // assigned under the lock below — so no other thread can observe
    // a half-written slot.
    let writeSlot = 1 - current
    let dst: CVPixelBuffer?
    if let existing = existing, pw == tw && ph == th {
      dst = existing
    } else {
      dst = createPrimeBuffer(w: tw, h: th)
    }
    guard let dst = dst else { return }
    copyFrame(src: pb, dst: dst)
    lock.lock()
    primeBuffers[writeSlot] = dst
    primeCurrent = writeSlot
    primeReady = true
    primeUpdatedAt = now
    primeW = tw
    primeH = th
    lock.unlock()
  }

  /// The current prime buffer, if one is held. The returned buffer is
  /// never written again — the next refresh writes the other slot —
  /// so it is safe to enqueue directly. Callers must NOT hold it
  /// across a release().
  private func takePrime() -> CVPixelBuffer? {
    lock.lock()
    defer { lock.unlock() }
    guard primeReady else { return nil }
    return primeBuffers[primeCurrent]
  }

  /// The current prime, but only if it is newer than the last one
  /// enqueued — the enter() poll uses this so it re-primes only when
  /// a fresher frame arrived while waiting for possible to flip.
  private func takePrimeIfNewer() -> CVPixelBuffer? {
    lock.lock()
    defer { lock.unlock() }
    guard primeReady, primeUpdatedAt > lastPrimedAt else { return nil }
    return primeBuffers[primeCurrent]
  }

  /// A fresh prime-slot buffer, created directly — NOT from the
  /// live-feed pool, so holding a prime can never starve the live
  /// feed. IOSurface-backed, like the pool buffers.
  private func createPrimeBuffer(w: Int, h: Int) -> CVPixelBuffer? {
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: w,
      kCVPixelBufferHeightKey as String: h,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    var out: CVPixelBuffer?
    guard CVPixelBufferCreate(
      kCFAllocatorDefault,
      w,
      h,
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary,
      &out
    ) == kCVReturnSuccess, let buf = out else { return nil }
    return buf
  }

  /// Synchronous copy into our own IOSurface-backed BGRA pool: the
  /// renderer reuses its buffer on the next render, so the tap's buffer
  /// must not be handed to the display layer as-is. When the target is
  /// smaller than the source (+29 downscale) the copy scales with
  /// vImage (SIMD): both buffers are 32BGRA, 4 bytes/pixel, and scaling
  /// is channel-order agnostic, so ARGB8888 is the right routine for
  /// BGRA data too.
  private func copyFrame(src: CVPixelBuffer, dst: CVPixelBuffer) {
    let sw = CVPixelBufferGetWidth(src)
    let sh = CVPixelBufferGetHeight(src)
    let dw = CVPixelBufferGetWidth(dst)
    let dh = CVPixelBufferGetHeight(dst)
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
    if sw == dw && sh == dh {
      if sb == db {
        memcpy(d, s, sb * sh)
      } else {
        for y in 0..<sh {
          memcpy(d + y * db, s + y * sb, min(sb, db))
        }
      }
      return
    }
    var srcBuf = vImage_Buffer(
      data: s,
      height: vImagePixelCount(sh),
      width: vImagePixelCount(sw),
      rowBytes: sb
    )
    var dstBuf = vImage_Buffer(
      data: d,
      height: vImagePixelCount(dh),
      width: vImagePixelCount(dw),
      rowBytes: db
    )
    _ = vImageScale_ARGB8888(
      &srcBuf,
      &dstBuf,
      nil,
      vImage_Flags(kvImageNoFlags)
    )
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
    lock.lock()
    pipActive = true
    lock.unlock()
  }

  public func pictureInPictureControllerDidStartPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    channel.invokeMethod("pipStarted", arguments: nil)
  }

  public func pictureInPictureControllerDidStopPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    stopPipFeed()
    channel.invokeMethod("pipStopped", arguments: ["restored": false])
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
      completionHandler: @escaping (Bool) -> Void
  ) {
    stopPipFeed()
    channel.invokeMethod("pipStopped", arguments: ["restored": true])
    completionHandler(true)
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    stopPipFeed()
    channel.invokeMethod(
      "pipFailed",
      arguments: ["reason": "\(error.localizedDescription) | \(diag())"]
    )
  }

  /// Stops the PiP feed and empties the display layer (+29): the layer
  /// renders above Flutter's scene, so a stale frame left in it would
  /// keep showing as a second copy of the video inside the app after
  /// PiP stops. The prime (+30) is held in memory, not in the layer,
  /// so the next start re-primes from the next frame arrival.
  private func stopPipFeed() {
    lock.lock()
    pipActive = false
    let targetLayer = layer
    lock.unlock()
    targetLayer?.flushAndRemoveImage()
  }

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

  // Required by AVPictureInPictureSampleBufferPlaybackDelegate (the
  // fifth of its five callbacks). The parameter type is CMVideoDimensions
  // in this SDK — the earlier CMVideoSize spelling is not in scope for
  // Swift here, which is why the method was briefly deleted; deleting it
  // broke conformance (build 6af8e5c9: "does not conform to protocol
  // 'AVPictureInPictureSampleBufferPlaybackDelegate'"). The body is a
  // no-op — aspect is preserved by the layer's .resizeAspect gravity.
  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
  }
}
