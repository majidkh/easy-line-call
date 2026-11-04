// Unit tests for courtMarking() — the singles/doubles render-time view of the
// detected court (lib/line_calling/vline_court_core.dart). Pure geometry, no
// OpenCV: imports the platform-free core directly. Guards the index-based
// segment-order contract that projectCourt and the singles derivation share.
import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/engine/vline_court_core.dart';

// A simple axis-aligned court in image px (no perspective), in projectCourt's
// segment order: [0] doubles_L, [1] singles_L, [2] centre, [3] singles_R,
// [4] doubles_R, [5] near baseline, [6] far baseline, [7] near service,
// [8] far service, [9] net. Doubles span x 0..100, singles x 10..90; near
// baseline y=200, far baseline y=0.
final _projected = <List<double>>[
  [0, 200, 0, 0], // doubles_L
  [10, 200, 10, 0], // singles_L
  [50, 150, 50, 50], // centre (service-to-service)
  [90, 200, 90, 0], // singles_R
  [100, 200, 100, 0], // doubles_R
  [0, 200, 100, 200], // near baseline (doubles width)
  [0, 0, 100, 0], // far baseline (doubles width)
  [10, 150, 90, 150], // near service (singles width)
  [10, 50, 90, 50], // far service (singles width)
  [0, 100, 100, 100], // net (doubles width)
];

bool _touchesDoublesSideline(List<List<double>> segs) => segs.any((s) =>
    s[0] < 5 || s[0] > 95 || s[2] < 5 || s[2] > 95); // x near 0 or 100

void main() {
  group('courtMarking', () {
    test('doubles draws the full projected court unchanged', () {
      final out = courtMarking(
        doubles: true,
        projected: _projected,
        lines: const [],
        baselines: const [],
        serviceLines: const [],
      );
      expect(out, same(_projected));
      expect(out.length, 10);
    });

    test('singles drops the doubles sidelines and clips baselines + net', () {
      final out = courtMarking(
        doubles: false,
        projected: _projected,
        lines: const [],
        baselines: const [],
        serviceLines: const [],
      );
      // 3 inner longitudinals + 2 service lines + 3 clipped transverse lines
      expect(out.length, 8);
      expect(_touchesDoublesSideline(out), isFalse,
          reason: 'no line should reach the doubles sidelines at x≈0/100');
      // every transverse line now runs between the singles sidelines (x 10..90)
      for (final s in out) {
        for (final x in [s[0], s[2]]) {
          expect(x, inInclusiveRange(10 - 1e-6, 90 + 1e-6));
        }
      }
      // the clipped near baseline (y=200) spans exactly singles_L..singles_R
      final nearBase = out.firstWhere((s) => s[1] == 200 && s[3] == 200);
      expect(nearBase[0], closeTo(10, 1e-6));
      expect(nearBase[2], closeTo(90, 1e-6));
    });

    test('defensive: a non-10-segment projection is left untouched in singles',
        () {
      final weird = <List<double>>[
        [0, 0, 1, 1],
        [2, 2, 3, 3],
      ];
      final out = courtMarking(
        doubles: false,
        projected: weird,
        lines: const [],
        baselines: const [],
        serviceLines: const [],
      );
      expect(out, same(weird));
    });

    test('singles fallback (no projection) drops outer sidelines, clips bases',
        () {
      // 5 detected longitudinals, full-height; one doubles-width near baseline
      final lines = <List<double>>[
        [0, 200, 0, 0], // doubles_L
        [10, 200, 10, 0], // singles_L
        [50, 200, 50, 0], // centre
        [90, 200, 90, 0], // singles_R
        [100, 200, 100, 0], // doubles_R
      ];
      final out = courtMarking(
        doubles: false,
        projected: const [],
        lines: lines,
        baselines: const [
          [0, 200, 100, 200]
        ],
        serviceLines: const [
          [10, 150, 90, 150]
        ],
      );
      // 3 inner longitudinals + 1 clipped baseline + 1 service line
      expect(out.length, 5);
      expect(_touchesDoublesSideline(out), isFalse);
    });

    test('doubles fallback keeps every detected line', () {
      final lines = <List<double>>[
        [0, 200, 0, 0],
        [10, 200, 10, 0],
        [50, 200, 50, 0],
        [90, 200, 90, 0],
        [100, 200, 100, 0],
      ];
      final out = courtMarking(
        doubles: true,
        projected: const [],
        lines: lines,
        baselines: const [
          [0, 200, 100, 200]
        ],
        serviceLines: const [
          [10, 150, 90, 150]
        ],
      );
      expect(out.length, 7); // 5 longitudinals + 1 baseline + 1 service line
    });
  });

  // The Adjust-court screen drags these 4 corners and re-projects the court.
  group('court from corners', () {
    // a perspective trapezoid (near edge wide+low, far edge narrow+high)
    final nl = [100.0, 400.0], nr = [500.0, 400.0];
    final fl = [200.0, 100.0], fr = [400.0, 100.0];

    void expectPoint(List<double> seg, int i, List<double> p) {
      expect(seg[i], closeTo(p[0], 1e-3));
      expect(seg[i + 1], closeTo(p[1], 1e-3));
    }

    test('doubles: the 4 outer corners round-trip through the projection', () {
      final h = courtHomographyFromCorners(nl, nr, fl, fr, doubles: true);
      expect(h, isNotNull);
      final segs = courtSegmentsFromHomography(h!);
      expect(segs.length, 10);
      expectPoint(segs[0], 0, nl); // doubles_L near = NL
      expectPoint(segs[0], 2, fl); // doubles_L far = FL
      expectPoint(segs[4], 0, nr); // doubles_R near = NR
      expectPoint(segs[4], 2, fr); // doubles_R far = FR
      expectPoint(segs[5], 0, nl); // near baseline spans NL..NR
      expectPoint(segs[5], 2, nr);
      // inner singles sidelines sit strictly inside the doubles corners
      expect(segs[1][0], greaterThan(nl[0]));
      expect(segs[3][0], lessThan(nr[0]));
    });

    test('singles: the corners land on the singles sidelines', () {
      final h = courtHomographyFromCorners(nl, nr, fl, fr, doubles: false);
      expect(h, isNotNull);
      final segs = courtSegmentsFromHomography(h!);
      expectPoint(segs[1], 0, nl); // singles_L near = NL
      expectPoint(segs[1], 2, fl); // singles_L far = FL
      expectPoint(segs[3], 0, nr); // singles_R near = NR
      expectPoint(segs[3], 2, fr); // singles_R far = FR
      // the doubles sidelines are now extrapolated OUTSIDE the input corners
      expect(segs[0][0], lessThan(nl[0]));
      expect(segs[4][0], greaterThan(nr[0]));
    });

    test('a degenerate (collinear) quad yields no homography', () {
      final h = courtHomographyFromCorners(
          [0, 0], [10, 0], [20, 0], [30, 0],
          doubles: true);
      expect(h, isNull);
    });
  });
}
