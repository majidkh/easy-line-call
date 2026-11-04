// =============================================================================
// LINE CALLING — calibration bridge between the UI and the vline detector
// (native platforms: iOS, Android, macOS, Linux, Windows).
//
// runVlineCalibration is a top-level compute() entry point: it decodes/wraps
// the frame, runs the stage-1 vertical-line court detection
// (vline_court.dart) at the standard processing width — including its
// coarse-scale retry — and maps the accepted candidate's 5 longitudinal
// lines back into the analyzed frame's pixel space.
//
// Import 'vline_calibrate.dart' (the facade), not this file: OpenCV rides on
// dart:ffi, which the web compiler refuses to even import.
// =============================================================================
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'vline_calibrate_types.dart';
import 'vline_court.dart';

export 'vline_calibrate_types.dart';

/// Top-level for compute(). Returns null when no court passes the gates
/// (honest reject — drawing wrong lines would corrupt the calibration).
VlineCalibration? runVlineCalibration(VlineRequest req) {
  cv.Mat src;
  if (req.encoded != null) {
    src = cv.imdecode(req.encoded!, cv.IMREAD_COLOR);
  } else {
    final rgba = cv.Mat.fromList(
        req.rgbaHeight, req.rgbaWidth, cv.MatType.CV_8UC4, req.rgba!);
    src = cv.cvtColor(rgba, cv.COLOR_RGBA2BGR);
    rgba.dispose();
  }
  if (src.cols == 0) {
    src.dispose();
    return null;
  }
  final srcW = src.cols, srcH = src.rows;
  cv.Mat proc;
  if (src.cols == kProcW) {
    proc = src;
  } else {
    final h = (src.rows * kProcW / src.cols).round();
    proc = cv.resize(src, (kProcW, h),
        interpolation: src.cols > kProcW ? cv.INTER_AREA : cv.INTER_CUBIC);
    src.dispose();
  }
  final auto = runVlineDetectionAuto(proc);
  final f = auto.scale * srcW / proc.cols;
  proc.dispose();
  final best = auto.result.best;
  if (best == null) return null;
  return VlineCalibration(
    lines: [
      for (final s in best.lines) [s.p1x * f, s.p1y * f, s.p2x * f, s.p2y * f]
    ],
    baselines: [
      for (final s in auto.result.baselines)
        [s.p1x * f, s.p1y * f, s.p2x * f, s.p2y * f]
    ],
    serviceLines: [
      for (final s in auto.result.serviceLines)
        [s.p1x * f, s.p1y * f, s.p2x * f, s.p2y * f]
    ],
    projected: [
      for (final s in auto.result.projection?.segments ?? const <List<double>>[])
        [s[0] * f, s[1] * f, s[2] * f, s[3] * f]
    ],
    score: best.score,
    rms: best.rms,
    coarseRetry: auto.scale != 1.0,
    frameW: srcW,
    frameH: srcH,
  );
}
