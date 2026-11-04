// Court frames between the muse2 engine and the app (muse_court.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/engine/muse_court.dart';
import 'package:tennis_core/types.dart';

// muse2 core/fixtures/court_img8630.json — fitted at 1280 px on IMG_8630.
const _img2court = [
  -0.0061809101306451375, 0.0008720530540763627, 3.489369685637627, //
  -0.004502835795773401, 0.0607096113721019, -21.92759374188711, //
  0.00027410638943112036, -0.003431775790896164, 1.0,
];
const _court2img = [
  -172.25431125558222, -152.18475250540104, -2735.986454732454, //
  -17.859914216532204, -84.55021812666055, -1791.6629906140963, //
  -0.014075213913565409, -0.24844257864633956, -4.398634307994913,
];

List<double> _apply(List<double> h, double x, double y) {
  final w = h[6] * x + h[7] * y + h[8];
  return [(h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w];
}

void main() {
  const calib = CourtCalib(_img2court, _court2img, 0.6, 10, []);

  test('muse2 court -> projected court -> muse2 homography round-trips', () {
    const frameScale = 1.5; // a 1920-wide calibration frame
    final proj = projectedFromMuse(calib, frameScale)!;
    expect(proj, hasLength(10));
    final (i2c, _) = museHomographies(proj, 1 / frameScale)!;
    // Same ground mapping, up to muse2's end labelling (a 180° relabel when
    // muse2's +y end is the near one).
    for (final p in [
      [400.0, 500.0],
      [640.0, 420.0],
      [900.0, 600.0],
      [700.0, 380.0],
    ]) {
      final a = _apply(_img2court, p[0], p[1]);
      final b = _apply(i2c, p[0], p[1]);
      final same = (a[0] - b[0]).abs() < 1e-6 && (a[1] - b[1]).abs() < 1e-6;
      final flipped = (a[0] + b[0]).abs() < 1e-6 && (a[1] + b[1]).abs() < 1e-6;
      expect(same || flipped, isTrue, reason: 'muse2 $a vs app $b at $p');
    }
  });

  test('near baseline is the one lower in the image, left is image-left', () {
    final proj = projectedFromMuse(calib, 1.0)!;
    final near = proj[5], far = proj[6]; // near/far baselines, left→right
    expect((near[1] + near[3]) / 2, greaterThan((far[1] + far[3]) / 2));
    expect(near[0], lessThan(near[2]));
    expect(far[0], lessThan(far[2]));
  });

  test('IN/OUT uses muse2 JudgeBounce 6 cm margin', () {
    expect(museCall(const Offset(10.97 + 0.05, 5), doubles: true).inBounds, isTrue);
    expect(museCall(const Offset(10.97 + 0.07, 5), doubles: true).inBounds, isFalse);
    expect(museCall(const Offset(-0.07, 20), doubles: true).inBounds, isFalse);
    expect(museCall(const Offset(9.598 + 0.07, 5), doubles: false).inBounds, isFalse);
    expect(museCall(const Offset(1.372 - 0.05, 5), doubles: false).inBounds, isTrue);
    expect(museCall(const Offset(5, 23.77 + 0.05), doubles: false).inBounds, isTrue);
    expect(museCall(const Offset(5, -0.1), doubles: false).inBounds, isFalse);
  });

  test('alley balls are OUT in singles, IN in doubles', () {
    // Between the singles (1.372 / 9.598) and doubles (0 / 10.97) sidelines.
    for (final x in [0.7, 10.27]) {
      expect(museCall(Offset(x, 5), doubles: false).inBounds, isFalse,
          reason: 'x=$x singles');
      expect(museCall(Offset(x, 5), doubles: true).inBounds, isTrue,
          reason: 'x=$x doubles');
    }
    // On the singles line itself: IN either way.
    expect(museCall(const Offset(1.372, 5), doubles: false).inBounds, isTrue);
    expect(museCall(const Offset(9.598, 5), doubles: false).inBounds, isTrue);
  });
}
