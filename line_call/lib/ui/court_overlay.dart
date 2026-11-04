// Court overlay: draws the calibrated court marking over a frame, matched
// to the image's BoxFit so lines sit exactly on the paint.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engine/vline_calibrate_types.dart';
import '../engine/vline_court_core.dart' show courtMarking;

class CourtOverlay extends StatelessWidget {
  final VlineCalibration det;
  final bool cover; // true = BoxFit.cover, false = BoxFit.contain
  final bool doubles;
  final Color color;
  const CourtOverlay(this.det,
      {super.key,
      this.cover = false,
      this.doubles = true,
      this.color = Colors.red});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: CourtMarkingPainter(det,
          cover: cover, doubles: doubles, color: color),
    );
  }
}

/// Court marking painter, also used offscreen by the annotated-video
/// export (same lines as the live view).
class CourtMarkingPainter extends CustomPainter {
  final VlineCalibration det;
  final bool cover;
  final bool doubles;
  final Color color;
  CourtMarkingPainter(this.det,
      {required this.cover, required this.doubles, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final imgW = det.frameW.toDouble(), imgH = det.frameH.toDouble();
    if (imgW <= 0 || imgH <= 0) return;
    final sx = size.width / imgW, sy = size.height / imgH;
    final scale = cover ? math.max(sx, sy) : math.min(sx, sy);
    final dispW = imgW * scale, dispH = imgH * scale;
    final ox = (size.width - dispW) / 2, oy = (size.height - dispH) / 2;
    Offset toW(double x, double y) => Offset(ox + x * scale, oy + y * scale);

    final t = (size.shortestSide / 240).clamp(1.5, 4.0).toDouble();
    final casing = Paint()
      ..color = Colors.white
      ..strokeWidth = t * 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final core = Paint()
      ..color = color
      ..strokeWidth = t
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final marked = courtMarking(
      doubles: doubles,
      projected: det.projected,
      lines: det.lines,
      baselines: det.baselines,
      serviceLines: det.serviceLines,
    );
    for (final p in [casing, core]) {
      for (final l in marked) {
        canvas.drawLine(toW(l[0], l[1]), toW(l[2], l[3]), p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CourtMarkingPainter old) =>
      old.det != det ||
      old.cover != cover ||
      old.doubles != doubles ||
      old.color != color;
}
