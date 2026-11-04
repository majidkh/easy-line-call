// Challenge browser: cover tap mapping and depth-adaptive review zoom.
import 'dart:ui' show Offset, Size;

import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/ui/challenge_page.dart'
    show callChipColor, challengeZoomForY, coverNorm, upscaleProgress;

void main() {
  test('coverNorm inverts BoxFit.cover (centered overdraw)', () {
    // 100x100 footage in a 200x100 view: scale 2, drawn 200x200 around
    // y = -50, so view (100, 50) is footage (0.5, 0.5) and the top edge
    // crops a quarter of the height.
    const view = Size(200, 100), content = Size(100, 100);
    final c = coverNorm(const Offset(100, 50), view, content);
    expect(c.dx, closeTo(0.5, 1e-9));
    expect(c.dy, closeTo(0.5, 1e-9));
    expect(coverNorm(const Offset(100, 0), view, content).dy,
        closeTo(0.25, 1e-9));
    expect(coverNorm(const Offset(0, 50), view, content).dx,
        closeTo(0.0, 1e-9));
    // Degenerate sizes fall back to the center.
    expect(coverNorm(const Offset(3, 4), const Size(0, 9), content),
        const Offset(0.5, 0.5));
  });

  test('challengeZoomForY zooms further for far-court points', () {
    expect(challengeZoomForY(0.9, 10, 20), 10); // near, clamped
    expect(challengeZoomForY(0.75, 10, 20), 10); // near pivot
    expect(challengeZoomForY(0.35, 10, 20), 20); // far pivot
    expect(challengeZoomForY(0.1, 10, 20), 20); // far, clamped
    expect(challengeZoomForY(0.55, 10, 20), closeTo(15, 1e-9)); // midpoint
  });

  test('upscaleProgress aggregates frame and tile fractions', () {
    // 10 frames, 3 done, 4th half tiled → 35%.
    expect(upscaleProgress(3, 10, 0.5), closeTo(0.35, 1e-9));
    expect(upscaleProgress(0, 10, 0.0), 0.0);
    expect(upscaleProgress(10, 10, 0.0), 1.0);
    // Degenerate / out-of-range inputs clamp instead of throwing.
    expect(upscaleProgress(0, 0, 0.0), 1.0);
    expect(upscaleProgress(11, 10, 2.0), 1.0);
  });

  test('callChipColor keeps undecided reviews amber, never red', () {
    expect(callChipColor('IN'), Colors.greenAccent);
    expect(callChipColor('OUT'), Colors.redAccent);
    expect(callChipColor('UNCERTAIN'), Colors.amberAccent);
    expect(callChipColor(null), Colors.amberAccent);
  });
}
