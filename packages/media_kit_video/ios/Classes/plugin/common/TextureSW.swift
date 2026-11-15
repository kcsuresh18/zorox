#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif
import Accelerate

public class TextureSW: NSObject, FlutterTexture, ResizableTextureProtocol {
  public typealias UpdateCallback = () -> Void

  private let handle: OpaquePointer
  private let updateCallback: UpdateCallback
  private var renderContext: OpaquePointer?
  private var textureContexts = SwappableObjectManager<TextureSWContext>(
    objects: [],
    skipCheckArgs: true
  )

  // +43 (ZoroX): the software renderer's gamma. mpv's SW backend
  // (libswscale, mpv 0.36 as bundled by media_kit_libs_ios_video
  // 1.1.4) expands the limited range correctly but never converts the
  // transfer function, so this buffer holds bt.1886-encoded values
  // for most films; the hardware path's gl_video converts to the sRGB
  // the display assumes, so the same frame looked faded here (lifted
  // shadows, grey veil) and right there. A per-channel LUT maps the
  // source TRC to sRGB right after mpv renders — both paths then show
  // the same colours, in the app and in the PiP window (which taps
  // this same buffer). Only TRCs that need it (bt.1886 and other pure
  // powers above 2.2); bt.709/sRGB/HDR are left alone. The TRC is read
  // once per video size from video-params/gamma; unknown defaults to
  // bt.1886, the TRC mpv itself guesses for SDR.
  private var swLutExponent: Double?
  private var swLutSize: CGSize?
  private var swLut: [UInt8]?
  private static let swLutIdentity: [UInt8] = (0...255).map { UInt8($0) }

  init(
    handle: OpaquePointer,
    updateCallback: @escaping UpdateCallback
  ) {
    self.handle = handle
    self.updateCallback = updateCallback

    super.init()

    DispatchQueue.main.async {
      self.initMPV()
    }
  }

  deinit {
    disposePixelBuffer()
    disposeMPV()
  }

  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    let textureContext = textureContexts.current
    if textureContext == nil {
      return nil
    }

    return Unmanaged.passRetained(textureContext!.pixelBuffer)
  }

  private func initMPV() {
    let api = UnsafeMutableRawPointer(
      mutating: (MPV_RENDER_API_TYPE_SW as NSString).utf8String
    )
    var params: [mpv_render_param] = [
      mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
      mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
    ]

    MPVHelpers.checkError(
      mpv_render_context_create(&renderContext, handle, &params)
    )

    mpv_render_context_set_update_callback(
      renderContext,
      { (ctx) in
        // +32 (ZoroX): count mpv's update callbacks — the diag snapshot
        // tells an mpv stall (this stops) apart from a Worker/main-hop
        // stall (this grows but renders don't).
        ZoroXMpvRenderStats.shared.noteUpdate()
        let that = unsafeBitCast(ctx, to: TextureSW.self)
        DispatchQueue.main.async {
          that.updateCallback()
        }
      },
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    )
  }

  private func disposeMPV() {
    mpv_render_context_set_update_callback(renderContext, nil, nil)
    mpv_render_context_free(renderContext)
  }

  public func resize(_ size: CGSize) {
    if size.width == 0 || size.height == 0 {
      return
    }

    NSLog("TextureSW: resize: \(size.width)x\(size.height)")
    createPixelBuffer(size)
  }

  private func createPixelBuffer(_ size: CGSize) {
    disposePixelBuffer()

    textureContexts.reinit(
      objects: [
        TextureSWContext(size: size),
        TextureSWContext(size: size),
        TextureSWContext(size: size),
      ],
      skipCheckArgs: true
    )
  }

  private func disposePixelBuffer() {
    textureContexts.reinit(objects: [], skipCheckArgs: true)
  }

  public func render(_ size: CGSize) {
    let textureContext = textureContexts.nextAvailable()
    if textureContext == nil {
      return
    }

    CVPixelBufferLockBaseAddress(
      textureContext!.pixelBuffer,
      CVPixelBufferLockFlags(rawValue: 0)
    )
    defer {
      CVPixelBufferUnlockBaseAddress(
        textureContext!.pixelBuffer,
        CVPixelBufferLockFlags(rawValue: 0)
      )
    }

    var ssize: [Int32] = [Int32(size.width), Int32(size.height)]
    let format: String = "bgr0"
    var pitch: Int = CVPixelBufferGetBytesPerRow(textureContext!.pixelBuffer)
    let buffer = CVPixelBufferGetBaseAddress(textureContext!.pixelBuffer)

    // pointers
    let ssizePtr = ssize.withUnsafeMutableBytes {
      $0.baseAddress?.assumingMemoryBound(to: Int32.self)
    }
    let formatPtr = UnsafeMutablePointer(
      mutating: (format as NSString).utf8String
    )
    let pitchPtr = withUnsafeMutablePointer(to: &pitch) { $0 }
    let bufferPtr = buffer!.assumingMemoryBound(to: UInt8.self)

    var params: [mpv_render_param] = [
      mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: ssizePtr),
      mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: formatPtr),
      mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: pitchPtr),
      mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: bufferPtr),
      mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
    ]

    // +32 (ZoroX): time the render — the diag snapshot shows whether
    // the software render itself is slow (renderMs in the tens of ms)
    // or the frames simply never arrive.
    let renderStart = DispatchTime.now()
    mpv_render_context_render(renderContext, &params)
    let renderMs =
      Double(
        DispatchTime.now().uptimeNanoseconds
          - renderStart.uptimeNanoseconds
      ) / 1_000_000
    ZoroXMpvRenderStats.shared.noteRender(durationMs: renderMs)

    // +43: correct the SW path's gamma (see applySwGammaCorrection):
    // mpv writes the video's own transfer function into this buffer
    // while the hardware path hands Flutter sRGB values, so without
    // this the same frame looks faded here and right there.
    applySwGammaCorrection(
      size: size,
      pitch: pitch,
      buffer: bufferPtr
    )

    textureContexts.pushAsReady(textureContext!)

    // ZoroX fork: export the completed frame for the iOS mpv PiP plugin
    // (see MediaKitFrameTap.swift). Posted while the buffer is still
    // locked by the defer above, so the observer's synchronous copy reads
    // stable memory; the pool reuses this buffer on a later render.
    // +32: the render counters ride in userInfo for the plugin's diag.
    NotificationCenter.default.post(
      name: .zoroxMpvRenderedFrame,
      object: textureContext!.pixelBuffer,
      userInfo: ZoroXMpvRenderStats.shared.snapshot()
    )
  }

  /// The video's transfer function as a pure power (bt.1886 -> 2.4),
  /// or 2.4 when mpv cannot say (no video yet, or an untagged file —
  /// mpv guesses bt.1886 for SDR itself).
  private func readVideoGammaExponent() -> Double {
    guard
      let cStr = mpv_get_property_string(handle, "video-params/gamma")
    else { return 2.4 }
    defer { mpv_free(cStr) }
    switch String(cString: cStr) {
    case "bt.1886", "gamma2.4":
      return 2.4
    case "gamma2.6":
      return 2.6
    case "gamma2.8":
      return 2.8
    default:
      // bt.709, srgb, gamma2.2 and every HDR/log curve: no correction
      // (2.2 makes the LUT an identity, so it is skipped below).
      return 2.2
    }
  }

  /// Maps the rendered frame's transfer function to sRGB, in place.
  /// A no-op (apart from one property read per new video size) when
  /// the source is already sRGB-like or HDR.
  private func applySwGammaCorrection(
    size: CGSize,
    pitch: Int,
    buffer: UnsafeMutablePointer<UInt8>
  ) {
    let width = Int(size.width)
    let height = Int(size.height)
    if width <= 0 || height <= 0 || pitch <= 0 { return }
    // A new size is a new video, which may carry a different TRC.
    if swLutSize != size {
      swLutSize = size
      swLutExponent = nil
      swLut = nil
    }
    if swLutExponent == nil {
      let source = readVideoGammaExponent()
      swLutExponent = source > 2.21 ? source / 2.2 : 1.0
    }
    guard let exponent = swLutExponent, exponent > 1.0 else { return }
    if swLut == nil {
      swLut = (0...255).map { i in
        let v = pow(Double(i) / 255.0, exponent)
        return UInt8(max(0, min(255, (v * 255.0).rounded())))
      }
    }
    guard let lut = swLut else { return }
    lut.withUnsafeBufferPointer { lutPtr in
      Self.swLutIdentity.withUnsafeBufferPointer { idPtr in
        var src = vImage_Buffer(
          data: buffer,
          height: vImagePixelCount(height),
          width: vImagePixelCount(width),
          rowBytes: pitch
        )
        var dst = src
        _ = vImageTableLookUp_ARGB8888(
          &src,
          &dst,
          lutPtr.baseAddress,
          lutPtr.baseAddress,
          lutPtr.baseAddress,
          idPtr.baseAddress,
          // +45: kvImageNoFlags imports into Swift as Int, but this
          // parameter is vImage_Flags (UInt32) — the bare constant does
          // not convert, so wrap it (the standard vImage Swift idiom).
          vImage_Flags(kvImageNoFlags)
        )
      }
    }
  }
}
