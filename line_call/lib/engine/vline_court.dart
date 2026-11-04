// =============================================================================
// LINE CALLING — court detection v-next, stage 1: OpenCV-backed shell.
//
// The full algorithm (Lab conversion, stripe validation, VP pencils, exact
// 1D-projective matching and all its gates) is pure Dart and lives in
// vline_court_core.dart, which this file re-exports — import THIS file from
// native code and tests. Here live only the dartcv-backed pieces: Mat
// decode/resize and the Canny+HoughLinesP seeder. Web must import the core
// directly (opencv_dart rides on dart:ffi, which the web compiler rejects)
// and seed with the pure-Dart Canny+Hough from vline_seeds.dart instead —
// seeds only need to land NEAR lines, the stripe validator re-finds the
// exact centreline, but the two seeders are not bit-identical, so the
// calibrated regression numbers (vline_report_test) apply to THIS path.
// =============================================================================
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'vline_court_core.dart';

export 'vline_court_core.dart';

/// BGR 8U Mat -> float Lab (matches OpenCV's float Lab path, D65).
LabImage labFromBgr(cv.Mat bgr) {
  final rgba = cv.cvtColor(bgr, cv.COLOR_BGR2RGBA);
  final lab = labFromRgba(rgba.data, bgr.cols, bgr.rows);
  rgba.dispose();
  return lab;
}

// ---------------------------------------------------------------- seeds
/// Line-segment seeds from Canny+HoughLinesP on the three Lab channels.
List<List<double>> houghSeeds(LabImage lab) {
  final w = lab.width, h = lab.height;
  final segs = <List<double>>[];
  for (var ch = 0; ch < 3; ch++) {
    final buf = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      final v = lab.data[i * 3 + ch];
      final u = ch == 0 ? v * 2.55 : v + 128.0;
      buf[i] = u < 0 ? 0 : (u > 255 ? 255 : u.round());
    }
    final mat = cv.Mat.fromList(h, w, cv.MatType.CV_8UC1, buf);
    final edges = cv.canny(mat, 30, 90);
    final lines = cv.HoughLinesP(edges, 1, math.pi / 180, 26,
        minLineLength: 22, maxLineGap: 3);
    for (var i = 0; i < lines.rows; i++) {
      final v = lines.at<cv.Vec4i>(i, 0);
      segs.add([
        v.val1.toDouble(),
        v.val2.toDouble(),
        v.val3.toDouble(),
        v.val4.toDouble()
      ]);
    }
    lines.dispose();
    edges.dispose();
    mat.dispose();
  }
  segs.removeWhere((s) {
    final l = math.sqrt((s[2] - s[0]) * (s[2] - s[0]) + (s[3] - s[1]) * (s[3] - s[1]));
    return l < 22;
  });
  segs.sort((a, b) {
    double len(List<double> s) =>
        (s[2] - s[0]) * (s[2] - s[0]) + (s[3] - s[1]) * (s[3] - s[1]);
    return len(b).compareTo(len(a));
  });
  if (segs.length > 700) segs.length = 700;
  return segs;
}

/// Decode + normalize to processing width (down- OR up-scaling: small images
/// have ~1px court lines, below what the stripe profiles can detect — at the
/// standard width they become detectable). Caller owns the returned Mat.
cv.Mat decodeAndDownscale(Uint8List bytes, {int width = kProcW}) {
  final src = cv.imdecode(bytes, cv.IMREAD_COLOR);
  if (src.cols == width || src.cols == 0) return src;
  final h = (src.rows * width / src.cols).round();
  final out = cv.resize(src, (width, h),
      interpolation: src.cols > width ? cv.INTER_AREA : cv.INTER_CUBIC);
  src.dispose();
  return out;
}

/// Detection with a coarse-scale retry: small upscaled sources (e.g. a 533px
/// photo brought to 1400) can blur their ~1px lines past the stripe profiles;
/// at 800 the same lines are crisp (texflip/09). Retry only on failure.
VlineAuto runVlineDetectionAuto(cv.Mat procBgr) {
  final r1 = runVlineDetection(procBgr);
  if (r1.best != null || procBgr.cols <= 800) return VlineAuto(r1, 1.0);
  final h2 = (procBgr.rows * 800 / procBgr.cols).round();
  final small = cv.resize(procBgr, (800, h2), interpolation: cv.INTER_AREA);
  final r2 = runVlineDetection(small);
  small.dispose();
  if (r2.best != null) return VlineAuto(r2, procBgr.cols / 800.0);
  return VlineAuto(r1, 1.0);
}

/// Run stage-1 detection on an already-downscaled BGR Mat.
VlineResult runVlineDetection(cv.Mat procBgr) {
  final lab = labFromBgr(procBgr);
  return runVlineDetectionLab(lab, houghSeeds(lab));
}
