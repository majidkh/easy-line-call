// =============================================================================
// LINE CALLING — calibration bridge, Flutter web.
//
// Same job as vline_calibrate_io.dart but with zero dart:ffi in the import
// graph: the pure-Dart core (vline_court_core.dart) runs the full detection,
// seeded by the pure Canny+Hough (vline_seeds.dart). Web callers must hand
// over decoded RGBA pixels — there is no synchronous image decoder here, and
// the UI has the frame decoded for display anyway. Note compute() on web
// runs on the main isolate, so the page accepts a short UI freeze.
// =============================================================================
import 'vline_calibrate_types.dart';
import 'vline_court_core.dart';

export 'vline_calibrate_types.dart';

VlineCalibration? runVlineCalibration(VlineRequest req) {
  final rgba = req.rgba;
  if (rgba == null) return null; // web callers must decode to RGBA first
  final w = req.rgbaWidth, h = req.rgbaHeight;
  if (w < 50 || h < 50) return null;
  final auto = runVlineDetectionAutoRgba(rgba, w, h);
  final best = auto.result.best;
  if (best == null) return null;
  final f = auto.scale * w / kProcW;
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
    frameW: w,
    frameH: h,
  );
}
