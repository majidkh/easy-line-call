// Court bounce overlay: last-10 numbered rings (1 = newest) and tap routing.
import 'dart:ui' show Offset, Size;

import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/ui/track_overlay.dart'
    show bounceReviewLabel, bounceRingColor, numberedBounces;
import 'package:line_call/ui/track_page.dart' show tapBounce;
import 'package:tennis_core/types.dart';

BounceCall _b(int frame, [double x = 0, double y = 0]) =>
    BounceCall(frame, x, y, 'IN', 0, 0);

void main() {
  test('numberedBounces keeps the last 10 at or before idx, 1 newest', () {
    final all = [for (var f = 0; f < 12; f++) _b(f * 10)];
    final got = numberedBounces(all, 200);
    expect(got.length, 10);
    expect(got.first.$1.frame, 20); // oldest of the window
    expect(got.first.$2, 10);
    expect(got.last.$1.frame, 110);
    expect(got.last.$2, 1);
    // A new bounce pushes the oldest out and renumbers.
    final next =
        numberedBounces([for (final b in all) b, _b(120)], 200);
    expect(next.length, 10);
    expect(next.first.$1.frame, 30);
    expect(next.first.$2, 10);
    expect(next.last.$2, 1);
    // The idx cutoff hides future bounces.
    final early = numberedBounces(all, 25);
    expect(early.map((e) => e.$1.frame).toList(), [0, 10, 20]);
    expect(early.map((e) => e.$2).toList(), [3, 2, 1]);
    expect(numberedBounces(all, -1), isEmpty);
  });

  test('numberedBounces expires live calls older than the window', () {
    // Frames stamped 1 s apart; "now" is frame 200 (200 s).
    final scanMs = [for (var f = 0; f <= 200; f++) f * 1000.0];
    final all = [_b(10), _b(100), _b(190), _b(200)];
    final got = numberedBounces(all, 200, 10, scanMs, 200 * 1000.0);
    // Frame 10 (190 s old) expired; the rest renumber with newest = 1.
    expect(got.map((e) => e.$1.frame).toList(), [100, 190, 200]);
    expect(got.map((e) => e.$2).toList(), [3, 2, 1]);
    // No clock given: no expiry (file playback keeps its history).
    expect(numberedBounces(all, 200).length, 4);
  });

  test('tapBounce hits the nearest ring within slop', () {
    // 100x100 engine in a 200x200 view: scale 2, no offset.
    final bs = [_b(0, 50, 50), _b(1, 10, 10)];
    expect(
        tapBounce(const Offset(105, 100), const Size(200, 200), 100, 100, bs)
            ?.frame,
        0);
    expect(tapBounce(const Offset(0, 0), const Size(200, 200), 100, 100, bs),
        isNull);
    expect(
        tapBounce(const Offset(100, 100), const Size(200, 200), 0, 100, bs),
        isNull);
    // Cover mapping with a vertical offset: 100x100 engine in a 200x100
    // view scales by 2 around y = -50, so (50, 50) lands at (100, 50).
    expect(
        tapBounce(const Offset(100, 55), const Size(200, 100), 100, 100, bs)
            ?.frame,
        0);
  });

  test('uncallable verdicts render amber, never red', () {
    BounceCall q(String call) => BounceCall(0, 0, 0, call, 0, 0);
    // Engine uncertainty wins over the geometric call either way.
    expect(bounceRingColor(q('?'), isIn: true), Colors.amberAccent);
    expect(bounceRingColor(q('?'), isIn: false), Colors.amberAccent);
    expect(bounceRingColor(q('IN'), isIn: true), Colors.greenAccent);
    expect(bounceRingColor(q('OUT'), isIn: false), Colors.redAccent);
    expect(bounceReviewLabel(q('?'), isIn: true), 'UNCERTAIN');
    expect(bounceReviewLabel(q('?'), isIn: false), 'UNCERTAIN');
    expect(bounceReviewLabel(q('IN'), isIn: true), 'IN');
    expect(bounceReviewLabel(q('OUT'), isIn: false), 'OUT');
  });
}
