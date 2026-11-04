// =============================================================================
// LINE CALLING — court geometry for the ball-tracking stage (Phase A).
//
// Maps frame-pixel points (e.g. a ball bounce) to ITF court coordinates in
// metres via the calibrated court, and calls a point in/out for the chosen
// format. Origin is the near-left DOUBLES corner: x runs across the court
// (0 .. 10.97 m), y runs away from the camera (0 .. 23.77 m).
//
// The mapping is a ground-plane homography recovered from the 4 detected
// doubles corners — so it is only valid for points ON the court surface (a
// ball bounce), not a ball in the air. Single-camera, so it's an approximate
// call, not Hawk-Eye.
// =============================================================================
import 'dart:ui' show Offset;

import 'vline_court_core.dart' show homographyFrom4;

/// ITF court dimensions (metres) and the tennis-ball radius.
class CourtModel {
  static const double doublesWidth = 10.97;
  static const double singlesLeft = 1.372; // inner sideline x
  static const double singlesRight = 9.598;
  static const double length = 23.77;
  static const double serviceNear = 5.485; // service line y (near)
  static const double serviceFar = 18.285; // service line y (far)
  static const double net = 11.885; // net y
  static const double centre = doublesWidth / 2; // centre service line x
  static const double ballRadius = 0.033; // ~33 mm; a ball touching a line = in
}

/// A bounce mapped to the court, with its in/out verdict.
class CourtCall {
  /// Court position in metres (x across, y down-court).
  final Offset court;
  final bool inBounds;
  const CourtCall(this.court, this.inBounds);
}

/// Maps frame-pixel points to court metres using the calibration's 4 doubles
/// corners, and calls them in/out for [doubles] vs singles. Points must be in
/// the SAME pixel space as the [projected] court they were built from
/// (VlineCalibration.frameW × frameH).
class CourtMapper {
  final List<double> _h; // image->world homography, row-major 3x3
  final bool doubles;
  const CourtMapper._(this._h, this.doubles);

  /// Build from projectCourt's 10-segment output. projected[0] is the left
  /// doubles sideline (near→far), projected[4] the right — their endpoints are
  /// the 4 doubles corners. Null if the projection isn't the full court or the
  /// quad is degenerate.
  static CourtMapper? fromProjected(List<List<double>> projected,
      {required bool doubles}) {
    if (projected.length != 10) return null;
    final l = projected[0], r = projected[4];
    final h = homographyFrom4(
      [
        [l[0], l[1], 1], // near-left  image px
        [r[0], r[1], 1], // near-right
        [l[2], l[3], 1], // far-left
        [r[2], r[3], 1], // far-right
      ],
      [
        [0, 0, 1], // near-left  world m
        [CourtModel.doublesWidth, 0, 1], // near-right
        [0, CourtModel.length, 1], // far-left
        [CourtModel.doublesWidth, CourtModel.length, 1], // far-right
      ],
    );
    return h == null ? null : CourtMapper._(h, doubles);
  }

  /// Frame pixel → court metres (assumes the point is on the court plane).
  Offset toCourt(Offset framePt) {
    final x = framePt.dx, y = framePt.dy;
    final w = _h[6] * x + _h[7] * y + _h[8];
    return Offset(
      (_h[0] * x + _h[1] * y + _h[2]) / w,
      (_h[3] * x + _h[4] * y + _h[5]) / w,
    );
  }

  /// Map a frame point and call it in/out (ball-radius tolerance: a bounce
  /// touching the line counts as in).
  CourtCall call(Offset framePt) {
    final c = toCourt(framePt);
    const r = CourtModel.ballRadius;
    final xMin = (doubles ? 0.0 : CourtModel.singlesLeft) - r;
    final xMax =
        (doubles ? CourtModel.doublesWidth : CourtModel.singlesRight) + r;
    final inB = c.dx >= xMin &&
        c.dx <= xMax &&
        c.dy >= -r &&
        c.dy <= CourtModel.length + r;
    return CourtCall(c, inB);
  }
}
