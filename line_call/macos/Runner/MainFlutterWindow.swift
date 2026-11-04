import Cocoa
import FlutterMacOS
import AVFoundation
import CoreImage
import Metal
import MetalFX
import tennis_core

class MainFlutterWindow: NSWindow {
  private let videoReader = VideoReaderSession()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    var windowFrame = self.frame
    // The app is landscape everywhere (phone-first); open the desktop
    // window landscape too so the layout matches.
    windowFrame.size = NSSize(width: 1180, height: 664)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Native video access. `video_thumbnail` has no macOS implementation, and
    // for the ball-tracking scan we need FAST sequential frame decode (seeking
    // to each timestamp re-decodes from a keyframe every time — seconds/frame).
    //   grabFrame   — one frame at a time (seek), for the scrub picker
    //   openReader / nextFrame / closeReader — sequential AVAssetReader, for Track
    let registrar = flutterViewController.registrar(forPlugin: "MacosVideoFrames")
    let channel = FlutterMethodChannel(
      name: "line_call/video", binaryMessenger: registrar.messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      let a = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "grabFrame":
        guard let path = a["path"] as? String else {
          result(FlutterMethodNotImplemented); return
        }
        let timeMs = (a["timeMs"] as? NSNumber)?.doubleValue ?? 0
        let maxWidth = (a["maxWidth"] as? NSNumber)?.intValue ?? 1920
        DispatchQueue.global(qos: .userInitiated).async {
          let data = MainFlutterWindow.grabFrame(
            path: path, timeMs: timeMs, maxWidth: maxWidth)
          DispatchQueue.main.async {
            result(data.map { FlutterStandardTypedData(bytes: $0) })
          }
        }
      case "openReader":
        self.videoReader.open(
          path: a["path"] as? String ?? "",
          startMs: (a["startMs"] as? NSNumber)?.doubleValue ?? 0,
          maxWidth: (a["maxWidth"] as? NSNumber)?.intValue ?? 1280,
          minIntervalMs: (a["minIntervalMs"] as? NSNumber)?.doubleValue ?? 30,
          cvColor: (a["cvColor"] as? Bool) ?? false
        ) { ok in DispatchQueue.main.async { result(ok) } }
      case "nextFrame":
        self.videoReader.next { map in
          DispatchQueue.main.async { result(map) }
        }
      case "closeReader":
        self.videoReader.close()
        result(nil)
      case "srUpscale2x":
        guard let bytes = (a["bytes"] as? FlutterStandardTypedData)?.data,
          let w = (a["width"] as? NSNumber)?.intValue,
          let h = (a["height"] as? NSNumber)?.intValue
        else {
          result(nil); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let out = FxUpscaler.upscale2x(rgba: bytes, width: w, height: h)
          DispatchQueue.main.async {
            if let (data, ow, oh) = out {
              result(["bytes": FlutterStandardTypedData(bytes: data),
                      "width": ow, "height": oh])
            } else {
              result(nil)
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  /// A JPEG still of the frame at [timeMs], longer side capped at [maxWidth].
  /// nil on any failure (the Dart side keeps the previous frame).
  static func grabFrame(path: String, timeMs: Double, maxWidth: Int) -> Data? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true // respect rotation metadata
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    if maxWidth > 0 {
      gen.maximumSize = CGSize(width: maxWidth, height: maxWidth)
    }
    let time = CMTime(seconds: max(0, timeMs) / 1000.0, preferredTimescale: 600)
    guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else {
      return nil
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
  }
}

/// Sequential video frame reader (AVAssetReader). Decodes frames in order —
/// no per-frame seek — and returns at most one frame per `minIntervalMs` of
/// video time (so a 60fps source yields ~30fps without extra inference). All
/// work runs on a private serial queue; the Dart loop awaits each call.
/// Sendable by queue confinement: every stored property is touched only on
/// that queue (the open Task hands its reader over through `Handoff` and
/// never touches it again), so cross-queue captures are sequential
/// transfers, never shared access.
final class VideoReaderSession: @unchecked Sendable {
  /// One-way transfer of a freshly built reader into the serial queue.
  private struct Handoff: @unchecked Sendable {
    var reader: AVAssetReader?
    var output: AVAssetReaderTrackOutput?
    var transform: CGAffineTransform
  }

  private let queue = DispatchQueue(label: "linecall.videoreader")
  private let ci = CIContext(options: [.useSoftwareRenderer: false])
  private let colorSpace = CGColorSpaceCreateDeviceRGB()
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var transform: CGAffineTransform = .identity
  private var maxWidth = 1280
  private var minIntervalMs: Double = 30
  private var lastMs: Double = -1e9
  private var cvColor = false

  func open(path: String, startMs: Double, maxWidth: Int, minIntervalMs: Double,
            cvColor: Bool = false, done: @escaping (Bool) -> Void) {
    queue.async {
      self.closeSync()
      // Track list and transform load asynchronously (macOS 13+); state
      // still publishes back on the serial queue, and the Dart loop
      // awaits each call, so open/close/next never interleave.
      Task {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
          let track = tracks.first,
          let r = try? AVAssetReader(asset: asset)
        else { done(false); return }
        let settings: [String: Any] =
          [kCVPixelBufferPixelFormatTypeKey as String: Int(
            cvColor ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA)]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { done(false); return }
        r.add(out)
        if startMs > 0 {
          r.timeRange = CMTimeRange(
            start: CMTime(seconds: startMs / 1000.0, preferredTimescale: 600),
            duration: .positiveInfinity)
        }
        guard r.startReading() else { done(false); return }
        let transform =
          (try? await track.load(.preferredTransform)) ?? .identity
        let handoff =
          Handoff(reader: r, output: out, transform: transform)
        self.queue.async {
          self.reader = handoff.reader
          self.output = handoff.output
          self.transform = handoff.transform
          self.maxWidth = maxWidth
          self.minIntervalMs = minIntervalMs
          self.cvColor = cvColor
          self.lastMs = -1e9
          done(true)
        }
      }
    }
  }

  func next(done: @escaping ([String: Any]?) -> Void) {
    queue.async {
      guard let out = self.output, let r = self.reader else { done(nil); return }
      while r.status == .reading {
        guard let sb = out.copyNextSampleBuffer() else { done(nil); return }
        let ms = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1000.0
        if ms + 0.5 < self.lastMs + self.minIntervalMs { continue } // too close
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        self.lastMs = ms
        var d = self.cvColor ? self.cvFrame(pb) : self.rawFrame(pb)
        if d != nil { d!["ms"] = ms } // real presentation time, for exact centring
        done(d)
        return
      }
      done(nil)
    }
  }

  func close() { queue.async { self.closeSync() } }

  private func closeSync() {
    reader?.cancelReading()
    reader = nil
    output = nil
    lastMs = -1e9
  }

  // OpenCV-equivalent pixels for the muse2 engine (cvColor mode): the raw
  // decoded YUV converted the way cv2.VideoCapture + cv2.resize do it (BT.601,
  // HDR tags ignored — muse2 was tuned on those colours), via the tennis_core
  // shim. The display rotation is applied like OpenCV's auto-orientation.
  private func cvFrame(_ pb: CVPixelBuffer) -> [String: Any]? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard CVPixelBufferGetPlaneCount(pb) == 2,
      let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
      let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)
    else { return nil }
    let sw = CVPixelBufferGetWidthOfPlane(pb, 0), sh = CVPixelBufferGetHeightOfPlane(pb, 0)
    let rot = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded() + 360) % 360
    let swap = rot == 90 || rot == 270
    let rw = swap ? sh : sw, rh = swap ? sw : sh
    let longer = max(rw, rh)
    let w = (maxWidth > 0 && longer > maxWidth) ? rw * maxWidth / longer : rw
    let h = rh * w / rw
    if w <= 0 || h <= 0 { return nil }
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let rc = sm_nv12_to_rgba_cv(
      y.assumingMemoryBound(to: UInt8.self), Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 0)),
      uv.assumingMemoryBound(to: UInt8.self), Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 1)),
      Int32(sw), Int32(sh), Int32(rot), &buf, Int32(w), Int32(h))
    if rc != 0 { return nil }
    return ["width": w, "height": h,
            "bytes": FlutterStandardTypedData(bytes: Data(buf))]
  }

  // RAW RGBA bytes (+ dims) instead of JPEG — the Dart side runs detection on
  // these directly, skipping a decode + GPU readback.
  private func rawFrame(_ pb: CVPixelBuffer) -> [String: Any]? {
    var img = CIImage(cvPixelBuffer: pb).transformed(by: transform)
    img = img.transformed(
      by: CGAffineTransform(translationX: -img.extent.origin.x, y: -img.extent.origin.y))
    let longer = max(img.extent.width, img.extent.height)
    if maxWidth > 0 && longer > CGFloat(maxWidth) {
      let s = CGFloat(maxWidth) / longer
      img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }
    let w = Int(img.extent.width.rounded()), h = Int(img.extent.height.rounded())
    if w <= 0 || h <= 0 { return nil }
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { ptr in
      ci.render(img, toBitmap: ptr.baseAddress!, rowBytes: w * 4,
                bounds: CGRect(x: 0, y: 0, width: w, height: h),
                format: CIFormat.RGBA8, colorSpace: colorSpace)
    }
    return ["width": w, "height": h,
            "bytes": FlutterStandardTypedData(bytes: Data(buf))]
  }
}

/// Device built-in 2x upscale (MetalFX spatial scaler): one GPU pass per
/// crop — milliseconds, versus the hundreds of TFLite tile inferences the
/// challenge review used to wait on. The Dart magnifier shows the 2x tile
/// at 4x with a bicubic second step. Pure Swift + Metal (no Flutter
/// types), shared verbatim with the iOS twin.
final class FxUpscaler {
  private static var device: MTLDevice?
  private static var queue: MTLCommandQueue?

  /// RGBA [w]×[h] bytes → 2x BGRA bytes (+ new dims). nil when Metal /
  /// MetalFX is unavailable — callers fall back to bicubic.
  static func upscale2x(rgba: Data, width w: Int, height h: Int)
    -> (Data, Int, Int)?
  {
    guard w > 0, h > 0, rgba.count >= w * h * 4 else { return nil }
    guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
      return nil
    }
    device = dev
    guard let q = queue ?? dev.makeCommandQueue() else { return nil }
    queue = q
    let desc = MTLFXSpatialScalerDescriptor()
    desc.inputWidth = w
    desc.inputHeight = h
    desc.outputWidth = w * 2
    desc.outputHeight = h * 2
    desc.colorTextureFormat = .bgra8Unorm
    desc.outputTextureFormat = .bgra8Unorm
    desc.colorProcessingMode = .perceptual
    guard let scaler = desc.makeSpatialScaler(device: dev),
      let cb = q.makeCommandBuffer()
    else {
      return nil
    }
    func tex(_ w: Int, _ h: Int, _ usage: MTLTextureUsage) -> MTLTexture? {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
      d.usage = usage
      d.storageMode = .shared
      return dev.makeTexture(descriptor: d)
    }
    guard let src = tex(w, h, .shaderRead),
      let dst = tex(w * 2, h * 2, .shaderWrite)
    else {
      return nil
    }
    // RGBA → BGRA swizzle on upload (sub-millisecond for review crops).
    var bgra = [UInt8](repeating: 0, count: w * h * 4)
    rgba.withUnsafeBytes { ptr in
      let s = ptr.bindMemory(to: UInt8.self)
      for i in 0 ..< w * h {
        bgra[i * 4] = s[i * 4 + 2]
        bgra[i * 4 + 1] = s[i * 4 + 1]
        bgra[i * 4 + 2] = s[i * 4]
        bgra[i * 4 + 3] = s[i * 4 + 3]
      }
    }
    src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                withBytes: bgra, bytesPerRow: w * 4)
    scaler.colorTexture = src
    scaler.outputTexture = dst
    scaler.encode(commandBuffer: cb)
    cb.commit()
    cb.waitUntilCompleted()
    guard cb.status == .completed else { return nil }
    var out = [UInt8](repeating: 0, count: w * 2 * h * 2 * 4)
    dst.getBytes(&out, bytesPerRow: w * 2 * 4,
                 from: MTLRegionMake2D(0, 0, w * 2, h * 2), mipmapLevel: 0)
    return (Data(out), w * 2, h * 2)
  }
}
