// =============================================================================
// LINE CALLING — calibration bridge data types (pure Dart, platform-free).
//
// Shared by vline_calibrate_io.dart (real detector, FFI/OpenCV) and
// vline_calibrate_stub.dart (web no-op), so the UI can depend on these types
// on every platform. Everything is plain sendable data: instances cross the
// compute() isolate boundary.
// =============================================================================
import 'dart:typed_data';

/// Frame handed to the detector isolate: either an encoded image
/// (jpeg/png/heic bytes as picked/captured) or raw RGBA pixels — the
/// AI-upscaled frame only exists as a decoded bitmap on the UI side, and
/// re-encoding it would just blur the detail the upscale recovered.
class VlineRequest {
  final Uint8List? encoded;
  final Uint8List? rgba; // tightly packed width*height*4
  final int rgbaWidth, rgbaHeight;

  VlineRequest.encoded(Uint8List bytes)
      : encoded = bytes,
        rgba = null,
        rgbaWidth = 0,
        rgbaHeight = 0;

  VlineRequest.rgba(Uint8List pixels, this.rgbaWidth, this.rgbaHeight)
      : encoded = null,
        rgba = pixels;
}

class VlineCalibration {
  /// The 5 detected longitudinal court lines (doubles/singles sidelines both
  /// sides + centre service line), [x1,y1,x2,y2] each, ordered across the
  /// court, in the pixel space of the analyzed frame ([frameW] x [frameH]).
  final List<List<double>> lines;

  /// Stage-3 detected baselines (0..2, near first), same encoding as [lines].
  final List<List<double>> baselines;

  /// Stage-4 detected near service line (0..1), same encoding as [lines].
  final List<List<double>> serviceLines;

  /// Stage-6 full projected court (9 painted ITF lines) — when non-empty,
  /// this is the FINAL marking and the painter draws only these.
  final List<List<double>> projected;
  final double score, rms;
  final bool coarseRetry;
  final int frameW, frameH;

  VlineCalibration({
    required this.lines,
    this.baselines = const [],
    this.serviceLines = const [],
    this.projected = const [],
    required this.score,
    required this.rms,
    required this.coarseRetry,
    required this.frameW,
    required this.frameH,
  });

  /// Copy with a manually adjusted court (the painter draws [projected] when
  /// present, so replacing it is enough to apply the "Adjust court" edit).
  VlineCalibration copyWith({List<List<double>>? projected}) =>
      VlineCalibration(
        lines: lines,
        baselines: baselines,
        serviceLines: serviceLines,
        projected: projected ?? this.projected,
        score: score,
        rms: rms,
        coarseRetry: coarseRetry,
        frameW: frameW,
        frameH: frameH,
      );
}
