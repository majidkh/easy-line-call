// Shared court/track overlay painting: the live tracking view and the
// offline annotated-video export draw the same balls, trails, detections
// and numbered bounce rings through these mappings and painters.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tennis_core/types.dart'
    show BounceCall, Candidate, MuseUpdate;

import '../engine/court_geometry.dart';
import '../engine/muse_court.dart';


/// Raw ball candidates within [window] frames of the shown frame [idx] —
/// what the painter draws as live detection dots.
List<Candidate> candsNear(MuseUpdate u, int idx, [int window = 2]) => [
      for (final e in u.cands.entries)
        if ((e.key - idx).abs() <= window) ...e.value
    ];

/// Last [max] bounces at or before frame [idx] ([all] oldest-first), as
/// (bounce, number) with 1 the newest — what the court overlay draws and
/// what taps can hit. A new bounce pushes the oldest out and renumbers.
/// When [scanMs] (frame → ms clock) and [nowMs] are given, bounces older
/// than [windowMs] are hidden first, so live calls expire with the 2-minute
/// challenge buffer and the newest is always 1.
List<(BounceCall, int)> numberedBounces(List<BounceCall> all, int idx,
    [int max = 10,
    List<double>? scanMs,
    double? nowMs,
    double windowMs = 120 * 1000]) {
  final shown = [
    for (final b in all)
      if (b.frame <= idx &&
          (scanMs == null ||
              nowMs == null ||
              b.frame < 0 ||
              b.frame >= scanMs.length ||
              nowMs - scanMs[b.frame] <= windowMs))
        b
  ];
  final window =
      shown.length <= max ? shown : shown.sublist(shown.length - max);
  return [
    for (var i = 0; i < window.length; i++) (window[i], window.length - i)
  ];
}

/// Engine (processing-px) coords → full-bleed view coords with BoxFit.cover.
/// The one mapping the painter, tap routing and tests share.
Offset coverMap(
    double x, double y, Size size, int procW, int procH) {
  final s = math.max(size.width / procW, size.height / procH);
  final ox = (size.width - procW * s) / 2;
  final oy = (size.height - procH * s) / 2;
  return Offset(ox + x * s, oy + y * s);
}

/// Ring color for a bounce: uncallable engine verdicts ('?') render
/// amber, never red — the geometry alone cannot decide them.
Color bounceRingColor(BounceCall b, {required bool isIn}) =>
    b.call == '?'
        ? Colors.amberAccent
        : (isIn ? Colors.greenAccent : Colors.redAccent);

/// Review label for a tapped bounce: the engine's uncertainty wins
/// over the geometric call.
String bounceReviewLabel(BounceCall b, {required bool isIn}) =>
    b.call == '?' ? 'UNCERTAIN' : (isIn ? 'IN' : 'OUT');

/// Singles/doubles-aware IN test for a bounce at its court coords.
bool bounceIsIn(BounceCall b, {required bool doubles}) => museCall(
      Offset(
        b.wx + CourtModel.doublesWidth / 2,
        b.wy + CourtModel.length / 2,
      ),
      doubles: doubles,
    ).inBounds;

/// Ball trails + bounce rings over the footage. Engine coordinates are
/// processing px ([procW] x [procH]); the video fills the view with
/// BoxFit.cover, so this painter uses the same cover mapping.
class TrackOverlayPainter extends CustomPainter {
  final MuseUpdate? update;
  final int idx;
  final int procW, procH;
  final List<(BounceCall, int)> court; // numbered rings, 1 = newest
  final bool Function(BounceCall) inOf; // singles/doubles-aware call
  TrackOverlayPainter(
      this.update, this.idx, this.procW, this.procH, this.court, this.inOf);

  @override
  void paint(Canvas canvas, Size size) {
    final u = update;
    if (u == null || procW <= 0 || procH <= 0) return;
    Offset toW(double x, double y) => coverMap(x, y, size, procW, procH);

    // Ball trails (recent points only) + current positions.
    final trail = Paint()
      ..color = const Color(0xAAFFEB3B)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final ball = Paint()..color = const Color(0xFFFFEB3B);
    for (final t in u.tracks) {
      if (t.stray) continue;
      // Shorts exist for stitch/Judge inputs; only long tracks display.
      if (t.points.length < 6) continue;
      final pts = [
        for (final p in t.points)
          if (p.frame <= idx && p.frame > idx - 30) p
      ];
      for (var i = 0; i + 1 < pts.length; i++) {
        canvas.drawLine(toW(pts[i].x, pts[i].y),
            toW(pts[i + 1].x, pts[i + 1].y), trail);
      }
      if (pts.isNotEmpty) {
        final c = toW(pts.last.x, pts.last.y);
        canvas.drawCircle(c, 5, ball);
        canvas.drawCircle(
            c,
            5,
            Paint()
              ..color = Colors.black54
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
    }

    // Raw detections at the shown frame — smaller and dimmer than the
    // tracked ball dot, so the rally visibly "lights up" the moment the
    // detector sees the ball, before tracks and bounces form.
    final cand = Paint()..color = const Color(0xCCFFFFFF);
    for (final c in candsNear(u, idx)) {
      canvas.drawCircle(toW(c.x, c.y), 3, cand);
    }

    // Numbered bounce rings (last 10 up to the shown frame).
    for (final (b, n) in court) {
      final c = toW(b.x, b.y);
      final call = bounceRingColor(b, isIn: inOf(b));
      final ring = Paint()
        ..color = call
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(c, 9, ring);
      canvas.drawCircle(
          c, 9, Paint()..color = call.withValues(alpha: 0.35));
      final tp = TextPainter(
        text: TextSpan(
          text: '$n',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 12,
            fontWeight: FontWeight.bold,
            shadows: [
              Shadow(color: Colors.black, blurRadius: 3, offset: Offset(0, 1))
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c + Offset(11, -10 - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant TrackOverlayPainter old) =>
      old.update != update || old.idx != idx;
}
