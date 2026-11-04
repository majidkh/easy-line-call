import Flutter
import UIKit
import AVFoundation
import CoreImage
import CoreText
import Metal
#if canImport(MetalFX)
import MetalFX
#endif
import tennis_core

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let videoReader = VideoReaderSession()
  private let filmExport = FilmExportSession()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Native sequential video-frame reader for the ball-tracking scan and the
    // challenge review clips — mirrors macOS (MainFlutterWindow). Seeking to
    // each timestamp re-decodes from a keyframe every call (seconds/frame);
    // AVAssetReader decodes in order. Same "line_call/video" channel + method
    // names the Dart side uses on every platform.
    guard let registrar = engineBridge.pluginRegistry
      .registrar(forPlugin: "LineCallVideoReader")
    else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "line_call/video", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler {
      [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { result(nil); return }
      let a = call.arguments as? [String: Any] ?? [:]
      switch call.method {
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
      case "exportStart":
        self.filmExport.start(
          path: a["path"] as? String ?? "",
          outPath: a["outPath"] as? String ?? "",
          payload: a["payload"] as? [String: Any] ?? [:]
        ) { map in DispatchQueue.main.async { result(map) } }
      case "exportProgress":
        result(self.filmExport.status())
      case "exportCancel":
        self.filmExport.cancelExport()
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
  }
}

/// Sequential video frame reader (AVAssetReader). Decodes frames in order — no
/// per-frame seek — and returns at most one frame per `minIntervalMs` of video
/// time. iOS twin of the macOS VideoReaderSession; JPEG encoding goes through
/// CoreImage (iOS has no AppKit / NSBitmapImageRep). All work runs on a private
/// serial queue; the Dart loop awaits each call.
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
      // Track list and transform load asynchronously (iOS 15+); state
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
/// iOS twin of the macOS FilmExportSession — same reader → draw → writer
/// export (push model, AAC audio, CoreText numbers).
/// Annotated-film export (AVAssetReader → draw → AVAssetWriter). Re-reads
/// the source at FULL resolution, draws the Dart payload's court lines /
/// ball trails / detection dots / numbered bounce rings onto every frame,
/// and re-encodes H.264 at the source size and frame rate with the original
/// presentation timestamps (same FPS and speed) and the audio track passed
/// through untouched. Overlay coordinates replicate the live painters:
/// processing px scaled onto the full frame (no cover crop), so nothing is
/// cut off. One export at a time; state is queue-confined, progress reads
/// go through queue.sync from the Dart poll loop.
final class FilmExportSession: @unchecked Sendable {
  private struct FrameOverlay: Sendable {
    var tails: [[Double]] // polylines, flat [x,y,…] in processing px
    var heads: [Double] // ball dots, flat [x,y,…]
    var cands: [Double] // raw detections, flat [x,y,…]
    var marks: [[Int]] // [bounceIndex, number], 1 = newest
  }
  private struct Bounce: Sendable {
    var x, y: Double // processing px
    var isIn: Bool
  }

  private let queue = DispatchQueue(label: "linecall.filmexport")
  private let ci = CIContext(options: [.useSoftwareRenderer: false])
  private let colorSpace = CGColorSpaceCreateDeviceRGB()
  private var state = "idle" // idle | running | done | error
  private var progress = 0.0
  private var donePath = ""
  private var errorMsg = ""

  func status() -> [String: Any] {
    queue.sync {
      ["state": state, "progress": progress, "path": donePath,
       "error": errorMsg]
    }
  }

  func cancelExport() {
    // Completion must not depend on future writer callbacks: parked push
    // blocks may never be re-invoked once appends stop, so force both
    // group leaves here (exactly-once — a no-op past completion).
    queue.async {
      guard self.state == "running" else { return }
      self.stateLock.lock()
      self._cancelled = true
      let g = self._group
      // Before run() arms the group there is nothing to leave — the blocks
      // observe the flag when they arm and leave through the claims.
      var lv = true, la = true, entered = false
      if g != nil {
        lv = self._leftV
        la = self._leftA
        entered = self._audioEntered
        self._leftV = true
        self._leftA = true
      }
      self.stateLock.unlock()
      if !lv { g?.leave() }
      if !la, entered { g?.leave() }
    }
  }

  func start(path: String, outPath: String, payload: [String: Any],
             done: @escaping ([String: Any]) -> Void) {
    queue.async {
      guard self.state != "running" else {
        done(["ok": false, "error": "export already running"]); return
      }
      // --- payload -----------------------------------------------------
      func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
      func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
      let procW = num(payload["procW"]), procH = num(payload["procH"])
      let frameW = num(payload["frameW"]), frameH = num(payload["frameH"])
      let scanMs = (payload["scanMs"] as? [Any] ?? []).map { num($0) }
      let rawLines = payload["lines"] as? [Any] ?? []
      let lines: [[Double]] = rawLines.map { l in
        (l as? [Any] ?? []).map { num($0) }
      }
      let rawB = payload["bounces"] as? [Any] ?? []
      let bounces: [Bounce] = rawB.map { r in
        let m = r as? [String: Any] ?? [:]
        return Bounce(x: num(m["x"]), y: num(m["y"]),
                      isIn: (m["in"] as? Bool) ?? true)
      }
      let rawF = payload["frames"] as? [Any] ?? []
      let frames: [FrameOverlay] = rawF.map { r in
        let m = r as? [String: Any] ?? [:]
        let tails = (m["tails"] as? [Any] ?? []).map { t in
          (t as? [Any] ?? []).map { num($0) }
        }
        let flat = { (k: String) in
          (m[k] as? [Any] ?? []).map { num($0) }
        }
        let marks = (m["marks"] as? [Any] ?? []).map { x in
          (x as? [Any] ?? []).map { int($0) }
        }
        return FrameOverlay(tails: tails, heads: flat("heads"),
                            cands: flat("cands"), marks: marks)
      }
      guard procW > 0, procH > 0, frameW > 0, frameH > 0,
        !scanMs.isEmpty, frames.count == scanMs.count
      else {
        done(["ok": false, "error": "bad export payload"]); return
      }
      guard !path.isEmpty, !outPath.isEmpty else {
        done(["ok": false, "error": "missing video path"]); return
      }
      self.state = "running"
      self.progress = 0
      self.donePath = ""
      self.errorMsg = ""
      self.stateLock.lock()
      self._cancelled = false
      self._broke = false
      self._brokeMsg = ""
      self._group = nil
      self._leftV = false
      self._leftA = false
      self.stateLock.unlock()
      let fail: (String) -> Void = { msg in
        self.state = "error"
        self.errorMsg = msg
      }
      Task {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let vtracks = try? await asset.loadTracks(withMediaType: .video),
          let vtrack = vtracks.first
        else { self.queue.async { fail("no video track") }; done(["ok": false, "error": "no video track"]); return }
        let atracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let atrack = atracks.first
        // Source audio format — the re-encode matches rate/channels.
        var audioRate = 0.0, audioCh = 0
        if let atrack = atrack,
          let descs = try? await atrack.load(.formatDescriptions),
          let d = descs.first,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)
        {
          audioRate = asbd.pointee.mSampleRate
          audioCh = Int(asbd.pointee.mChannelsPerFrame)
        }
        if audioRate <= 0 { audioRate = 48000 }
        if audioCh <= 0 { audioCh = 2 }
        let natSize = (try? await vtrack.load(.naturalSize)) ?? .zero
        let transform =
          (try? await vtrack.load(.preferredTransform)) ?? .identity
        let fps = (try? await vtrack.load(.nominalFrameRate)) ?? 30
        let dur = ((try? await asset.load(.duration)) ?? .zero).seconds
        // Rotated output size — the overlays were computed on rotated scan
        // frames, so the export frame matches that orientation.
        let probe = CGRect(origin: .zero, size: natSize).applying(transform)
        let outW = Int(abs(probe.width).rounded())
        let outH = Int(abs(probe.height).rounded())
        guard outW > 0, outH > 0 else {
          self.queue.async { fail("bad video size") }
          done(["ok": false, "error": "bad video size"]); return
        }
        self.queue.async {
          self.run(asset: asset, vtrack: vtrack, atrack: atrack,
                   outPath: outPath, transform: transform,
                   outW: outW, outH: outH, fps: Double(max(fps, 1)),
                   durMs: max(dur, 0.001) * 1000,
                   audioRate: audioRate, audioCh: audioCh,
                   procW: procW, procH: procH, frameW: frameW, frameH: frameH,
                   scanMs: scanMs, lines: lines, bounces: bounces,
                   frames: frames, fail: fail)
          done(["ok": true])
        }
      }
    }
  }

  // Arms the push blocks on the serial queue and returns; completion
  // lands in the group notify. [audioRate]/[audioCh] come from the source
  // audio format (nil track → the audio blocks are skipped).
  private func run(asset: AVURLAsset, vtrack: AVAssetTrack,
                   atrack: AVAssetTrack?, outPath: String,
                   transform: CGAffineTransform, outW: Int, outH: Int,
                   fps: Double, durMs: Double,
                   audioRate: Double, audioCh: Int,
                   procW: Double, procH: Double, frameW: Double,
                   frameH: Double, scanMs: [Double], lines: [[Double]],
                   bounces: [Bounce], frames: [FrameOverlay],
                   fail: @escaping (String) -> Void) {
    let sx = Double(outW) / procW, sy = Double(outH) / procH
    let lx = Double(outW) / frameW, ly = Double(outH) / frameH
    let s = (sx + sy) / 2 // uniform in practice (aspect-preserved scan)
    do { // scoped so the reader/writer drop together at the end
      try? FileManager.default.removeItem(atPath: outPath)
      guard let reader = try? AVAssetReader(asset: asset) else {
        fail("cannot read video"); return
      }
      let vOut = AVAssetReaderTrackOutput(
        track: vtrack,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                          Int(kCVPixelFormatType_32BGRA)])
      vOut.alwaysCopiesSampleData = false
      guard reader.canAdd(vOut) else { fail("cannot read video"); return }
      reader.add(vOut)
      var aOut: AVAssetReaderTrackOutput?
      if atrack != nil {
        // Audio re-encodes (PCM → AAC): passthrough inputs never become
        // ready on this stack (verified four ways on rally-3.mov), while
        // 256 kbps AAC is transparent and keeps the same sync.
        let o = AVAssetReaderTrackOutput(track: atrack!, outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: audioRate,
          AVNumberOfChannelsKey: audioCh,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsNonInterleaved: false,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
        ])
        o.alwaysCopiesSampleData = false
        if reader.canAdd(o) { reader.add(o); aOut = o }
      }
      guard reader.startReading() else { fail("cannot read video"); return }
      let bitrate = min(40_000_000,
                        max(4_000_000,
                            Double(outW * outH) * fps * 0.15))
      let vSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: outW, AVVideoHeightKey: outH,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: Int(bitrate),
          AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
        ]]
      guard let writer = try? AVAssetWriter(
        outputURL: URL(fileURLWithPath: outPath), fileType: .mp4)
      else { fail("cannot write film"); return }
      let vIn = AVAssetWriterInput(mediaType: .video,
                                   outputSettings: vSettings)
      vIn.expectsMediaDataInRealTime = false
      vIn.transform = .identity // frames are pre-rotated, like the scan
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: vIn,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String:
            Int(kCVPixelFormatType_32BGRA),
          kCVPixelBufferWidthKey as String: outW,
          kCVPixelBufferHeightKey as String: outH,
        ])
      guard writer.canAdd(vIn) else { fail("cannot write film"); return }
      writer.add(vIn)
      var aIn: AVAssetWriterInput?
      if aOut != nil, atrack != nil {
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: audioRate,
          AVNumberOfChannelsKey: audioCh,
          AVEncoderBitRateKey: audioCh > 1 ? 256000 : 128000,
        ])
        i.expectsMediaDataInRealTime = false
        if writer.canAdd(i) { writer.add(i); aIn = i } else { aOut = nil }
      }
      guard writer.startWriting() else { fail("cannot write film"); return }
      writer.startSession(atSourceTime: .zero)
      // Push model (Apple's reader→writer pattern): each input pulls on
      // its own queue via requestMediaDataWhenReady. Polling
      // isReadyForMoreMediaData from one loop wedges the audio input
      // forever on this stack (verified with passthrough and AAC alike);
      // the push blocks below are the only shape that flows.
      // run() returns once the blocks are armed; completion lands in the
      // group notify, so the serial queue stays free for status polls.
      let group = DispatchGroup()
      let videoQueue = DispatchQueue(label: "linecall.filmexport.video",
                                     qos: .userInitiated)
      let audioQueue = DispatchQueue(label: "linecall.filmexport.audio",
                                     qos: .userInitiated)
      group.enter() // video
      stateLock.lock()
      _group = group
      _audioEntered = (aOut != nil && aIn != nil)
      stateLock.unlock()
      vIn.requestMediaDataWhenReady(on: videoQueue) {
        if self.isCancelled() || self.isBroke() || self.hasLeftV() { return }
        while vIn.isReadyForMoreMediaData {
          if self.isCancelled() || self.isBroke() {
            if self.claimLeaveV() { group.leave() }
            return
          }
          guard let sb = vOut.copyNextSampleBuffer() else {
            if self.claimLeaveV() {
              vIn.markAsFinished()
              group.leave()
            }
            return
          }
          let pts = CMSampleBufferGetPresentationTimeStamp(sb)
          guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
          let ms = pts.seconds * 1000
          var lo = 0, hi = scanMs.count - 1
          while lo < hi { // scan frame at this timestamp, like the live view
            let mid = (lo + hi + 1) >> 1
            if scanMs[mid] <= ms { lo = mid } else { hi = mid - 1 }
          }
          guard let pool = adaptor.pixelBufferPool else {
            self.noteBroke("no pixel pool")
            return
          }
          var out: CVPixelBuffer?
          guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            == kCVReturnSuccess, let dst = out
          else {
            self.noteBroke("no pixel buffer")
            return
          }
          self.annotate(src: pb, dst: dst, transform: transform,
                        ov: frames[lo], lines: lines, bounces: bounces,
                        sx: sx, sy: sy, lx: lx, ly: ly, s: s, w: outW, h: outH)
          if !adaptor.append(dst, withPresentationTime: pts) {
            self.noteBroke("video append failed")
            return
          }
          self.queue.async {
            self.progress = min(1, max(0, ms / durMs))
          }
        }
      }
      if let aOut = aOut, let aIn = aIn {
        group.enter() // audio
        aIn.requestMediaDataWhenReady(on: audioQueue) {
          if self.isCancelled() || self.isBroke() || self.hasLeftA() { return }
          while aIn.isReadyForMoreMediaData {
            if self.isCancelled() || self.isBroke() {
              if self.claimLeaveA() { group.leave() }
              return
            }
            guard let ab = aOut.copyNextSampleBuffer() else {
              if self.claimLeaveA() {
                aIn.markAsFinished()
                group.leave()
              }
              return
            }
            // Priming trims (negative PTS) are dropped — the writer
            // rejects anything before the session start.
            if CMSampleBufferGetPresentationTimeStamp(ab) < .zero { continue }
            aIn.append(ab)
            if writer.status != .writing {
              self.noteBroke("audio append failed")
              return
            }
          }
        }
      }
      group.notify(queue: self.queue) {
        if self.isCancelled() {
          reader.cancelReading()
          writer.cancelWriting()
          try? FileManager.default.removeItem(atPath: outPath)
          fail("cancelled")
          return
        }
        if self.isBroke() {
          reader.cancelReading()
          writer.cancelWriting()
          try? FileManager.default.removeItem(atPath: outPath)
          fail("encode failed: \(self.brokeMsg())")
          return
        }
        writer.finishWriting {
          self.queue.async {
            if writer.status == .completed {
              self.state = "done"
              self.donePath = outPath
              self.progress = 1
            } else {
              fail("encode failed: "
                + (writer.error?.localizedDescription
                  ?? reader.error?.localizedDescription ?? "unknown"))
            }
          }
        }
      }
    }
  }

  // Sticky cross-queue export state (the push blocks run off the serial
  // queue, so the cancel/failure flags live behind a lock). Group leaves
  // are exactly-once per track (_leftV/_leftA): the push blocks, cancel
  // and failure all funnel through the claim helpers, so completion never
  // hangs and never over-leaves.
  private let stateLock = NSLock()
  private var _cancelled = false
  private var _broke = false
  private var _brokeMsg = ""
  private var _group: DispatchGroup?
  private var _audioEntered = false
  private var _leftV = false
  private var _leftA = false
  private func isCancelled() -> Bool {
    stateLock.lock(); defer { stateLock.unlock() }; return _cancelled
  }
  private func isBroke() -> Bool {
    stateLock.lock(); defer { stateLock.unlock() }; return _broke
  }
  private func brokeMsg() -> String {
    stateLock.lock(); defer { stateLock.unlock() }; return _brokeMsg
  }
  private func hasLeftV() -> Bool {
    stateLock.lock(); defer { stateLock.unlock() }; return _leftV
  }
  private func hasLeftA() -> Bool {
    stateLock.lock(); defer { stateLock.unlock() }; return _leftA
  }
  /// True exactly once per export — the caller owns this track's leave.
  private func claimLeaveV() -> Bool {
    stateLock.lock(); defer { stateLock.unlock() }
    if _leftV { return false }
    _leftV = true
    return true
  }
  /// True exactly once per export — the caller owns this track's leave.
  private func claimLeaveA() -> Bool {
    stateLock.lock(); defer { stateLock.unlock() }
    if _leftA { return false }
    _leftA = true
    return true
  }
  private func noteBroke(_ msg: String) {
    // Failure completes through the notify like cancel does — force both
    // leaves so a parked sibling block can't hold completion hostage.
    stateLock.lock()
    _broke = true
    _brokeMsg = msg
    let g = _group
    let lv = _leftV, la = _leftA, entered = _audioEntered
    _leftV = true
    _leftA = true
    stateLock.unlock()
    if !lv { g?.leave() }
    if !la, entered { g?.leave() }
  }

  // Draws one annotated frame: base image (rotated like the scan frames)
  // then court lines, trails, dots and numbered rings in top-left coords.
  private func annotate(src: CVPixelBuffer, dst: CVPixelBuffer,
                        transform: CGAffineTransform,
                        ov: FrameOverlay, lines: [[Double]], bounces: [Bounce],
                        sx: Double, sy: Double, lx: Double, ly: Double,
                        s: Double, w: Int, h: Int) {
    var img = CIImage(cvPixelBuffer: src).transformed(by: transform)
    img = img.transformed(by: CGAffineTransform(
      translationX: -img.extent.origin.x, y: -img.extent.origin.y))
    CVPixelBufferLockBaseAddress(dst, [])
    defer { CVPixelBufferUnlockBaseAddress(dst, []) }
    guard let base = CVPixelBufferGetBaseAddress(dst) else { return }
    let rowBytes = CVPixelBufferGetBytesPerRow(dst)
    ci.render(img, toBitmap: base, rowBytes: rowBytes,
              bounds: CGRect(x: 0, y: 0, width: w, height: h),
              format: CIFormat.BGRA8, colorSpace: colorSpace)
    guard let ctx = CGContext(
      data: base, width: w, height: h, bitsPerComponent: 8,
      bytesPerRow: rowBytes, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
        CGBitmapInfo.byteOrder32Little.rawValue)
    else { return }
    let H = Double(h)
    let Y = { (y: Double) in H - y } // top-left → CoreGraphics y
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // Court marking: white casing + red core, painter widths at output size.
    let t = min(4.0, max(1.5, Double(min(w, h)) / 240))
    for (col, lw) in [(CGColor(red: 1, green: 1, blue: 1, alpha: 1), t * 2),
                      (CGColor(red: 0xF4 / 255, green: 0x43 / 255,
                               blue: 0x36 / 255, alpha: 1), t)] {
      ctx.setStrokeColor(col)
      ctx.setLineWidth(lw)
      for l in lines where l.count >= 4 {
        ctx.move(to: CGPoint(x: l[0] * lx, y: Y(l[1] * ly)))
        ctx.addLine(to: CGPoint(x: l[2] * lx, y: Y(l[3] * ly)))
        ctx.strokePath()
      }
    }
    // Ball trails.
    ctx.setStrokeColor(CGColor(red: 1, green: 0xEB / 255, blue: 0x3B / 255,
                               alpha: 0xAA / 255))
    ctx.setLineWidth(2 * s)
    for line in ov.tails {
      var i = 0
      var first = true
      while i + 1 < line.count {
        let p = CGPoint(x: line[i] * sx, y: Y(line[i + 1] * sy))
        if first { ctx.move(to: p); first = false } else { ctx.addLine(to: p) }
        i += 2
      }
      ctx.strokePath()
    }
    // Ball head dots + dark ring; raw detections smaller and dimmer.
    var i = 0
    while i + 1 < ov.heads.count {
      let c = CGPoint(x: ov.heads[i] * sx, y: Y(ov.heads[i + 1] * sy))
      ctx.setFillColor(CGColor(red: 1, green: 0xEB / 255, blue: 0x3B / 255,
                               alpha: 1))
      ctx.fillEllipse(in: CGRect(x: c.x - 5 * s, y: c.y - 5 * s,
                                 width: 10 * s, height: 10 * s))
      ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.66))
      ctx.setLineWidth(1.5 * s)
      ctx.strokeEllipse(in: CGRect(x: c.x - 5 * s, y: c.y - 5 * s,
                                   width: 10 * s, height: 10 * s))
      i += 2
    }
    i = 0
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0xCC / 255))
    while i + 1 < ov.cands.count {
      let c = CGPoint(x: ov.cands[i] * sx, y: Y(ov.cands[i + 1] * sy))
      ctx.fillEllipse(in: CGRect(x: c.x - 3 * s, y: c.y - 3 * s,
                                 width: 6 * s, height: 6 * s))
      i += 2
    }
    // Numbered bounce rings. Numbers go through CoreText (not
    // NSAttributedString.draw, which needs an AppKit/UIKit graphics-context
    // stack this bare CGContext doesn't have — it silently draws nothing).
    let ctFont = CTFontCreateWithName("Helvetica-Bold" as CFString,
                                      CGFloat(12 * s), nil)
    let numH = CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont)
    for m in ov.marks where m.count >= 2 {
      let bi = m[0]
      guard bi >= 0, bi < bounces.count else { continue }
      let b = bounces[bi]
      let c = CGPoint(x: b.x * sx, y: Y(b.y * sy))
      let ring = b.isIn
        ? CGColor(red: 0x69 / 255, green: 0xF0 / 255, blue: 0xAE / 255,
                  alpha: 1)
        : CGColor(red: 1, green: 0x52 / 255, blue: 0x52 / 255, alpha: 1)
      ctx.setFillColor(ring.copy(alpha: 0.35) ?? ring)
      ctx.fillEllipse(in: CGRect(x: c.x - 9 * s, y: c.y - 9 * s,
                                 width: 18 * s, height: 18 * s))
      ctx.setStrokeColor(ring)
      ctx.setLineWidth(2.5 * s)
      ctx.strokeEllipse(in: CGRect(x: c.x - 9 * s, y: c.y - 9 * s,
                                   width: 18 * s, height: 18 * s))
      // Label beside the ring, same placement as the live painter.
      let num = NSAttributedString(string: "\(m[1])", attributes: [
        kCTFontAttributeName as NSAttributedString.Key: ctFont,
        kCTForegroundColorAttributeName as NSAttributedString.Key:
          CGColor(red: 1, green: 1, blue: 1, alpha: 0.5),
      ])
      let line = CTLineCreateWithAttributedString(num)
      ctx.saveGState()
      ctx.textMatrix = .identity
      ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3,
                    color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      ctx.textPosition = CGPoint(
        x: c.x + 11 * s,
        y: c.y + 10 * s + numH / 2 - CTFontGetAscent(ctFont))
      CTLineDraw(line, ctx)
      ctx.restoreGState()
    }
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
    // MetalFX ships on devices only (no simulator slice): compile the
    // scaler out there and report unavailable — the review falls back
    // to bicubic. Deliberate divergence from the macOS twin.
#if !canImport(MetalFX)
    return nil
#else
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
#endif
  }
}
