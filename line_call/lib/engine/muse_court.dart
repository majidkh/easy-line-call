// =============================================================================
// LINE CALLING — court frames between the muse2 engine and this app.
//
// muse2 (packages/tennis_core) works in metres with the origin at the COURT
// CENTRE (x across, y along; ±5.485 doubles sidelines, ±11.885 baselines) and
// in pixels at its PROCESSING width (1280). This app works in metres from the
// NEAR-LEFT doubles corner (x 0..10.97, y 0..23.77 away from the camera) and
// in pixels of the calibrated frame (VlineCalibration.frameW × frameH).
//
// Pure math (no FFI), so it compiles on every platform.
// =============================================================================
import 'dart:ui' show Offset;

import 'package:tennis_core/types.dart' show CourtCalib;

import 'court_geometry.dart';
import 'vline_court_core.dart'
    show courtHomographyFromCorners, courtSegmentsFromHomography, homographyFrom4;

/// muse2's processing width (pipeline/driver default).
const int kMuseProcW = 1280;

const double _halfDbl = CourtModel.doublesWidth / 2; // 5.485
const double _halfLen = CourtModel.length / 2; // 11.885

/// Row-major 3x3 product a·b.
List<double> mat3Mul(List<double> a, List<double> b) => [
      for (var r = 0; r < 3; r++)
        for (var c = 0; c < 3; c++)
          a[3 * r] * b[c] + a[3 * r + 1] * b[3 + c] + a[3 * r + 2] * b[6 + c]
    ];

/// Row-major 3x3 inverse, or null when singular.
List<double>? mat3Inv(List<double> m) {
  final a = m[0], b = m[1], c = m[2];
  final d = m[3], e = m[4], f = m[5];
  final g = m[6], h = m[7], i = m[8];
  final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  if (det.abs() < 1e-18 || !det.isFinite) return null;
  return [
    (e * i - f * h) / det,
    (c * h - b * i) / det,
    (b * f - c * e) / det,
    (f * g - d * i) / det,
    (a * i - c * g) / det,
    (c * d - a * f) / det,
    (d * h - e * g) / det,
    (b * g - a * h) / det,
    (a * e - b * d) / det,
  ];
}

List<double> _apply(List<double> h, double x, double y) {
  final w = h[6] * x + h[7] * y + h[8];
  return [(h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w];
}

/// muse2 calibration (processing px) → this app's 10-segment projected court
/// in frame px ([procToFrame] = frameW / processing width). The NEAR baseline
/// is whichever end sits lower in the image, and left/right follow the image,
/// so the court is labelled the same way a manual corner pick would be.
/// Null on a degenerate fit.
List<List<double>>? projectedFromMuse(CourtCalib c, double procToFrame) {
  final h = c.hCourt2Img;
  List<double> px(double wx, double wy) {
    final p = _apply(h, wx, wy);
    return [p[0] * procToFrame, p[1] * procToFrame];
  }

  // The two baselines' midpoints decide which world end is near the camera.
  final a = px(0, -_halfLen), b = px(0, _halfLen);
  if (!a.every((v) => v.isFinite) || !b.every((v) => v.isFinite)) return null;
  final nearSign = a[1] >= b[1] ? -1.0 : 1.0; // muse2 world-y sign of near end
  final n1 = px(-_halfDbl, nearSign * _halfLen);
  final n2 = px(_halfDbl, nearSign * _halfLen);
  final f1 = px(-_halfDbl, -nearSign * _halfLen);
  final f2 = px(_halfDbl, -nearSign * _halfLen);
  // left/right by image x along each baseline
  final (nl, nr) = n1[0] <= n2[0] ? (n1, n2) : (n2, n1);
  final (fl, fr) = f1[0] <= f2[0] ? (f1, f2) : (f2, f1);
  final hw = courtHomographyFromCorners(nl, nr, fl, fr, doubles: true);
  if (hw == null) return null;
  return courtSegmentsFromHomography(hw);
}

/// The calibrated (possibly hand-adjusted) court as muse2 session
/// homographies in PROCESSING px: (h_img2court, h_court2img). [frameToProc]
/// = processing width / frameW. Null unless [projected] is the full court.
(List<double>, List<double>)? museHomographies(
    List<List<double>> projected, double frameToProc) {
  if (projected.length != 10) return null;
  final l = projected[0], r = projected[4]; // doubles sidelines, near→far
  // frame px → app court metres (same corners CourtMapper uses)
  final i2w = homographyFrom4(
    [
      [l[0], l[1], 1],
      [r[0], r[1], 1],
      [l[2], l[3], 1],
      [r[2], r[3], 1],
    ],
    [
      [0, 0, 1],
      [CourtModel.doublesWidth, 0, 1],
      [0, CourtModel.length, 1],
      [CourtModel.doublesWidth, CourtModel.length, 1],
    ],
  );
  if (i2w == null) return null;
  final s = 1 / frameToProc; // processing px → frame px
  final procToFrame = [s, 0.0, 0.0, 0.0, s, 0.0, 0.0, 0.0, 1.0];
  const toCentre = [1.0, 0.0, -_halfDbl, 0.0, 1.0, -_halfLen, 0.0, 0.0, 1.0];
  final img2court = mat3Mul(toCentre, mat3Mul(i2w, procToFrame));
  final court2img = mat3Inv(img2court);
  if (court2img == null) return null;
  return (img2court, court2img);
}

/// muse2's JudgeBounce verdict (rally.cpp) for a bounce at app court metres
/// [court]: OUT when it lands more than 6 cm past the line. muse2 always
/// judges the doubles court; [doubles] = false applies the same rule to the
/// singles sidelines.
CourtCall museCall(Offset court, {required bool doubles}) {
  final wx = court.dx - _halfDbl, wy = court.dy - _halfLen;
  final halfW = doubles ? _halfDbl : (CourtModel.singlesRight - CourtModel.centre);
  final dOut = [wx.abs() - halfW, wy.abs() - _halfLen].reduce((a, b) => a > b ? a : b);
  return CourtCall(court, dOut <= 0.06);
}
