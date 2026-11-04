// Unit tests for CourtMapper (lib/line_calling/court_geometry.dart) — the
// image→court homography and the in/out call that the ball-tracking stage
// relies on. Pure geometry, no ML.
import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/engine/court_geometry.dart';
import 'package:line_call/engine/vline_court_core.dart';

// world(metres)→image px for the trapezoid below, to place test points exactly.
Offset _worldToImage(List<double> h, double x, double y) {
  final w = h[6] * x + h[7] * y + h[8];
  return Offset(
      (h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w);
}

void main() {
  // 4 doubles corners as a perspective trapezoid in image px
  final nl = [100.0, 400.0], nr = [500.0, 400.0];
  final fl = [200.0, 100.0], fr = [400.0, 100.0];
  final h = courtHomographyFromCorners(nl, nr, fl, fr, doubles: true)!;
  final projected = courtSegmentsFromHomography(h);

  group('CourtMapper', () {
    test('the 4 image corners round-trip to the world corners', () {
      final m = CourtMapper.fromProjected(projected, doubles: true)!;
      void near(Offset got, double x, double y) {
        expect(got.dx, closeTo(x, 1e-2));
        expect(got.dy, closeTo(y, 1e-2));
      }

      near(m.toCourt(Offset(nl[0], nl[1])), 0, 0);
      near(m.toCourt(Offset(nr[0], nr[1])), CourtModel.doublesWidth, 0);
      near(m.toCourt(Offset(fl[0], fl[1])), 0, CourtModel.length);
      near(m.toCourt(Offset(fr[0], fr[1])), CourtModel.doublesWidth,
          CourtModel.length);
    });

    test('doubles: inside is IN, beyond the sideline is OUT', () {
      final m = CourtMapper.fromProjected(projected, doubles: true)!;
      // a corner sits on the line → IN (ball-radius tolerance)
      expect(m.call(Offset(nl[0], nl[1])).inBounds, isTrue);
      // well left of the near-left corner → outside the left sideline
      expect(m.call(Offset(nl[0] - 60, nl[1])).inBounds, isFalse);
      // court centre → IN
      expect(
          m
              .call(_worldToImage(
                  h, CourtModel.centre, CourtModel.length / 2))
              .inBounds,
          isTrue);
    });

    test('singles: a ball in the doubles alley is OUT', () {
      final m = CourtMapper.fromProjected(projected, doubles: false)!;
      // the doubles corner maps to court x=0 — in the alley, outside singles
      expect(m.call(Offset(nl[0], nl[1])).inBounds, isFalse);
      // a point just inside the singles sideline → IN
      expect(
          m
              .call(_worldToImage(
                  h, CourtModel.singlesLeft + 0.2, CourtModel.length / 2))
              .inBounds,
          isTrue);
    });

    test('rejects a projection that is not the full 10-segment court', () {
      expect(CourtMapper.fromProjected(const [], doubles: true), isNull);
    });
  });
}
