// Adaptive-stride rule: dense detection while a rally is live or a chain
// head is near the frontier, sparse dead-time watch otherwise.
import 'package:flutter_test/flutter_test.dart';
import 'package:tennis_core/src/driver.dart'
    show effectiveStride, rallyActiveNear;
import 'package:tennis_core/types.dart';

Track _track(int start, int end, {bool stray = false}) => Track(
      1,
      [for (var f = start; f <= end; f++) TrackPoint(f, 1, 1, true, 0.9)],
      const [],
      const [],
      stray,
    );

Rally _rally(int start, int end) =>
    Rally(0, 1, start, end, const [], const [], null);

void main() {
  test('empty session watches sparse', () {
    expect(rallyActiveNear(const [], const [], 240), isFalse);
  });

  test('live rally stays dense', () {
    expect(
        rallyActiveNear([_rally(100, 300)], const [], 240), isTrue);
  });

  test('recently ended rally stays dense through the memory window', () {
    expect(rallyActiveNear([_rally(100, 200)], const [], 240), isTrue);
    expect(
        rallyActiveNear([_rally(100, 200)], const [], 240, memory: 30),
        isFalse);
  });

  test('long-dead rally goes sparse', () {
    expect(
        rallyActiveNear([_rally(100, 200)], const [], 500), isFalse);
  });

  test('recent chain head stays dense without a rally yet', () {
    expect(rallyActiveNear(const [], [_track(210, 235)], 240), isTrue);
    expect(rallyActiveNear(const [], [_track(100, 120)], 240), isFalse);
  });

  test('stray chains never hold dense', () {
    expect(
        rallyActiveNear(const [], [_track(210, 235, stray: true)], 240),
        isFalse);
  });

  int eff(
          {bool adaptive = true,
          int stride = 3,
          int sparse = 9,
          int chunk = 24,
          required int lo,
          List<Rally> rallies = const [],
          List<Track> tracks = const []}) =>
      effectiveStride(
          adaptive: adaptive,
          stride: stride,
          sparseStride: sparse,
          chunk: chunk,
          lo: lo,
          rallies: rallies,
          tracks: tracks);

  test('disabled stays on fixed stride everywhere', () {
    expect(eff(adaptive: false, lo: 0), 3);
    expect(eff(adaptive: false, lo: 240), 3);
  });

  test('first chunk always dense so openers link exactly', () {
    expect(eff(lo: 0), 3);
    expect(eff(lo: 24), 9);
  });

  test('live rally holds dense, dead time goes sparse', () {
    expect(eff(lo: 240, rallies: [_rally(100, 300)]), 3);
    expect(eff(lo: 500, rallies: [_rally(100, 200)]), 9);
    expect(eff(lo: 240, tracks: [_track(210, 235)]), 3);
  });
}
