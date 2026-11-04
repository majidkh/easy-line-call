// =============================================================================
// LINE CALLING — top-down court minimap (Phase A).
//
// Draws the ITF court from above and plots bounce calls on it (green = in,
// red = out). Used to visualise where the ball landed and to sanity-check the
// image→court mapping with hand-placed test points.
// =============================================================================
import 'package:flutter/material.dart';

import 'court_geometry.dart';

class CourtMinimap extends StatelessWidget {
  /// Singles → draw the singles court bounds emphasised; doubles → the full
  /// court. (All lines are drawn either way; the [doubles] flag only tints the
  /// active boundary.)
  final bool doubles;
  final List<CourtCall> calls;

  /// Recent projected ball positions (court metres) — drawn as a yellow trail
  /// with the current spot highlighted.
  final List<Offset> track;

  const CourtMinimap({
    super.key,
    required this.doubles,
    this.calls = const [],
    this.track = const [],
  });

  @override
  Widget build(BuildContext context) {
    // court is 10.97 × 23.77 (≈1:2.17) — a tall panel
    return AspectRatio(
      aspectRatio: CourtModel.doublesWidth / CourtModel.length,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xCC0A2A1E), // dark green, translucent
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: CustomPaint(painter: _MinimapPainter(doubles, calls, track)),
      ),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  final bool doubles;
  final List<CourtCall> calls;
  final List<Offset> track;
  _MinimapPainter(this.doubles, this.calls, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size); // contain off-court (airborne) points
    const pad = 6.0;
    final sx = (size.width - 2 * pad) / CourtModel.doublesWidth;
    final sy = (size.height - 2 * pad) / CourtModel.length;
    final s = sx < sy ? sx : sy;
    final ox = (size.width - CourtModel.doublesWidth * s) / 2;
    final oy = (size.height - CourtModel.length * s) / 2;
    Offset p(double x, double y) => Offset(ox + x * s, oy + y * s);

    final line = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final boundary = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;

    const w = CourtModel.doublesWidth, len = CourtModel.length;
    const sl = CourtModel.singlesLeft, sr = CourtModel.singlesRight;

    void seg(double x1, double y1, double x2, double y2, Paint pt) =>
        canvas.drawLine(p(x1, y1), p(x2, y2), pt);

    // sidelines (doubles outer + singles inner)
    seg(0, 0, 0, len, doubles ? boundary : line);
    seg(w, 0, w, len, doubles ? boundary : line);
    seg(sl, 0, sl, len, doubles ? line : boundary);
    seg(sr, 0, sr, len, doubles ? line : boundary);
    // baselines (full width)
    seg(0, 0, w, 0, boundary);
    seg(0, len, w, len, boundary);
    // service lines (singles width) + centre service line
    seg(sl, CourtModel.serviceNear, sr, CourtModel.serviceNear, line);
    seg(sl, CourtModel.serviceFar, sr, CourtModel.serviceFar, line);
    seg(CourtModel.centre, CourtModel.serviceNear, CourtModel.centre,
        CourtModel.serviceFar, line);
    // net
    canvas.drawLine(
        p(0, CourtModel.net),
        p(w, CourtModel.net),
        Paint()
          ..color = const Color(0xFF00E6E6)
          ..strokeWidth = 1.4);

    // ball track (trail + current position)
    if (track.isNotEmpty) {
      final trail = Paint()
        ..color = const Color(0xAAFFEB3B)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i + 1 < track.length; i++) {
        canvas.drawLine(p(track[i].dx, track[i].dy),
            p(track[i + 1].dx, track[i + 1].dy), trail);
      }
      final last = track.last;
      canvas.drawCircle(
          p(last.dx, last.dy), 4, Paint()..color = const Color(0xFFFFEB3B));
      canvas.drawCircle(
          p(last.dx, last.dy),
          4,
          Paint()
            ..color = Colors.black54
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
    }

    // bounce calls — last 10 only, fading 10% per step (newest fully opaque)
    for (var i = 0; i < calls.length; i++) {
      final age = calls.length - 1 - i; // 0 = newest
      if (age >= 10) continue;
      final op = 1.0 - age * 0.1;
      final c = calls[i];
      final sp = p(c.court.dx, c.court.dy);
      final fill =
          (c.inBounds ? const Color(0xFF22DD66) : const Color(0xFFFF4757))
              .withValues(alpha: op);
      canvas.drawCircle(sp, 4, Paint()..color = fill);
      canvas.drawCircle(
          sp,
          4,
          Paint()
            ..color = Colors.white.withValues(alpha: op)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
    }
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter old) =>
      old.doubles != doubles ||
      old.calls != calls ||
      old.track.length != track.length;
}
