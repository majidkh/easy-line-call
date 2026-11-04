// =============================================================================
// LINE CALLING — court detection v-next, stage 1 (Dart port of
// tools/vline_court.py, 2026-06-11).
//
// Finds the 5 longitudinal ("vertical") court lines — doubles/singles
// sidelines both sides + centre service line — by:
//   1. Seeding line segments (Canny+HoughLinesP on L/a/b channels; the Python
//      reference uses LSD, which dartcv does not expose — seeds only need to
//      land NEAR lines, the stripe validator re-finds the exact centreline).
//   2. Validating each seed as a color-stripe via perpendicular Lab profiles:
//      centre differs from both flanks, chroma (a,b) consistent along the
//      line while LUMINANCE FLOATS FREE -> robust to lights and shadows.
//   3. Extending through small occlusions, merging collinear same-color
//      fragments, dropping short lines.
//   4. Grouping into pencils by vanishing point (the camera-angle constraint:
//      parallel court lines must be concurrent in the image).
//   5. Searching same-color 5-line subsets whose pencil positions match the
//      tennis model x-pattern {0, 1.372, 5.486, 9.598, 10.97} m under an
//      exact 1D projectivity, for any camera position. A 4+1 mode fits four
//      detected lines and verifies paint along the predicted fifth.
//
// THIS FILE IS THE PLATFORM-FREE CORE (pure Dart, no dart:ffi): everything
// from Lab conversion through stripe validation, pencils and matching, plus
// RGBA-based entry points seeded by the pure Canny+Hough (vline_seeds.dart).
// The OpenCV-backed pieces — Mat decode/resize and the cv Canny+HoughLinesP
// seeder — live in vline_court.dart, which re-exports this file and is the
// import for native code and the tests. Web imports this core directly.
// Drawing helpers for the report tool live in the test, not here.
// =============================================================================
import 'dart:math' as math;
import 'dart:typed_data';

import 'vline_seeds.dart';

// ---------------------------------------------------------------- constants
const int kProcW = 1400;

/// Model x-positions of the 5 longitudinal lines (metres, left->right).
const List<double> kModelX = [0.0, 1.372, 5.486, 9.598, 10.97];
const List<String> kRoleNames = [
  'doubles_L', 'singles_L', 'centre_serv', 'singles_R', 'doubles_R'
];

// stripe profile
const double kProfT = 9.0; // profile half-extent (px)
const double kProfStep = 0.5; // profile sampling step (px)
const double kTauStripe = 9.0; // min Lab dE centre-vs-nearest-flank
const double kAbTol = 10.0; // chroma consistency tolerance along a line
const double kSampleStep = 4.0; // spacing of samples along a segment
const double kMinInlierFrac = 0.55;
const int kMinInliers = 6;

// tracing / merging
const double kExtStep = 3.0;
const int kExtMaxSteps = 500;
const int kExtFailStop = 12; // consecutive misses (36px gap: nets, shadows)
const double kMergeAng = 1.3; // deg
const double kMergeOff = 2.8; // px
const double kMergeGap = 70.0; // px
const double kMergeAb = 10.0;
const double kShortMin = 34.0; // floor; shorts survive as centre candidates

// families / matching
const double kVertMaxDeg = 88.0; // per-line prior: prune only the truly
                                 // horizontal. Corner end poses legitimately
                                 // put the off-side sideline at ~85-87 deg
                                 // (8441 t11.6s: left doubles 86.9 deg while
                                 // the right doubles is 18.5) — a tighter
                                 // per-line cap (84 was tried) starves the
                                 // true pencil of its flat members. Pose
                                 // policing lives in the SET-mean gate below.
const double kSetMeanVertDeg = 66.0; // pose gate (Majid, 2026-06-12): the
                                 // court reads vertical-ish as a SET in every
                                 // end-of-court pose. True end/corner fans
                                 // measure 53-66 deg mean (8366/8440/915/301/
                                 // 664/649; corner poses like test1 and
                                 // 8441-t11.6 average ~65.5). Raising to 75
                                 // (texflip/06's elevated NET-SIDE pose,
                                 // 73.6) was tried and REVERTED: walking-
                                 // video junk fans live at 66-75 (8441 t0.0/
                                 // t1.6 redrew badminton overlay + practice-
                                 // net lines) and no other signal separates
                                 // them — net-side support needs stage 2.
                                 // texflip/05's last alias (5-set, 69.9) also
                                 // dies here.
                                 // [2026-06-12 night: the stage-2 signals now
                                 // EXIST — see kSetMeanVertDegFlat.]
const double kSetMeanVertDegFlat = 76.0; // NET-SIDE band (Majid, 2026-06-12):
                                 // fans of 66-76 deg mean (texflip/06's
                                 // elevated net-side pose = 73.6) are now
                                 // admitted into matching but the WINNING
                                 // candidate is accepted only if the court
                                 // PROJECTS (a detected baseline + second
                                 // transverse anchor passing all ordering/
                                 // sanity gates) — the anchor-confirmed
                                 // structure the 2026-06-12 daytime junk
                                 // (8441 badminton/practice-net fans at
                                 // 66-75) cannot produce. Enforced in
                                 // runVlineDetectionLab, not here.
const double kVpAngTol = 1.4; // deg, line-through-VP residual (long lines)

/// Direction uncertainty scales ~1/length (a few px of end-noise tilt a
/// short stripe much more than a long one) -> length-adaptive VP tolerance.
/// Noise constant 9px: steep ~220px singles lines in eye-height corner views
/// (567/664) carry that much end-bias from junction/baseline contamination.
double vpTolDeg(double length) =>
    (math.atan(9.0 / length) * 180.0 / math.pi).clamp(kVpAngTol, 2.6);
const double kSetAbTol = 25.0; // white paint drifts up to ~23 ab-units across
                               // warm/cool venue lighting (posterImage-301)
const double kFitRmsPx = 2.0; // 5-line fit rms gate (proc px)
const double kFitRms4Px = 2.6; // 4-line fit rms gate (one redundancy)
const double kMinSpanFrac = 0.18; // span gate for 4+1 candidates
const double kMinSpanFrac5 = 0.10; // a FULL 5-detected set is strong evidence:
                                   // allow smaller-in-frame courts (texflip/03)
const double kPredEvFrac = 0.08; // min evidence fraction along predicted 5th
const double kPredRunPx = 36.0; // min contiguous evidence run
const double kPredMassPx = 56.0; // min total evidence mass
const double kSlotTolM = 0.30; // in-court same-color paint must sit on a slot
const double kPenAbTol = 12.0; // color match for the slot rule
const double kScoreAccept = 0.75; // worse than this is not a court (every
                                  // visually-verified true fit scores <=0.35;
                                  // borderline junk lived in 0.75..1.2)
const double kWeakRatioMax = 25.0; // scale-ratio bound (max/min implied
                                  // px-per-metre across the 5 slots) for the
                                  // EVIDENCE-FREE weak-centre path only: with
                                  // zero paint proof, demand sober geometry.
                                  // True poses reach ~20x (8547 t6.0s 5-set:
                                  // 19.5; 8441-t11.6 weak-centre: 15.4); the
                                  // texflip/05 twin-pair alias needs 44x. A
                                  // GENERAL gate (16) was tried and REVERTED:
                                  // it killed half of 8547's true 5-sets
                                  // (19.5 > 16 > the okEvidence aliases'
                                  // 15.6-18.2 — no global threshold exists).
// Ground-plane camera-height gates (Majid's narrow-tramline rule,
// 2026-06-12; 8441 t0.2s): adjacent longitudinal lines dx metres apart obey
// gap/drop = dx/h at any image row, so each pair reads out the camera
// height h — the SAME h for every pair of a real court. Junk quintets that
// grab off-ground structure break this: 8441's practice-net wall pair reads
// 16.6m (t0.2s) / 14.1m (t1.4s) with cross-pair ratios 24-27, the net-tape
// fan (t10.6s) ratio 6.9, while every true match across the suite stays
// h<=10.04 (texflip/02, elevated broadcast pose) and ratio<=4.76 (corner
// poses t11.0/test1). Lines must also sit measurably BELOW the horizon
// (the VP horizontal): ceiling fans cross it (t2.8s, min drop -0.15*W) and
// horizon-hugging net tape reads 0.015*W, vs 0.021*W for the deepest true
// line (t11.6s).
const double kCamHMaxM = 12.0;
const double kCamHRatioMax = 5.7;
const double kMinHorizonDropFrac = 0.018;

const double kCoincRms = 0.7;     // a 4+1 whose predicted ridge is collinear
                                  // with a DETECTED long stripe is a 5-set in
                                  // disguise and must nearly meet 5-set
                                  // standards refit with that stripe's own
                                  // tau: texflip/15's legit case refits at
                                  // 0.60px, texflip/05's resurrection alias
                                  // (a 5-set the gates rejected, revived by
                                  // freeing one line as "predicted") at 0.85.

// ---------------------------------------------------------------- Lab image
/// Float Lab image (L 0..100, a/b approx -127..127), interleaved 3 floats/px.
class LabImage {
  final int width, height;
  final Float32List data; // (y*width + x)*3
  LabImage(this.width, this.height, this.data);
}

final Float64List _srgbLut = () {
  final lut = Float64List(256);
  for (var i = 0; i < 256; i++) {
    final c = i / 255.0;
    lut[i] = c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }
  return lut;
}();

double _labF(double t) =>
    t > 0.008856 ? math.pow(t, 1.0 / 3.0).toDouble() : 7.787 * t + 16.0 / 116.0;

/// Tightly packed RGBA bytes -> float Lab (matches OpenCV's float Lab path,
/// D65). The platform-free twin of vline_court.dart's labFromBgr.
LabImage labFromRgba(Uint8List src, int w, int h) {
  final out = Float32List(w * h * 3);
  for (var i = 0, n = w * h; i < n; i++) {
    final r = _srgbLut[src[i * 4]];
    final g = _srgbLut[src[i * 4 + 1]];
    final b = _srgbLut[src[i * 4 + 2]];
    final x = (0.412453 * r + 0.357580 * g + 0.180423 * b) / 0.950456;
    final y = 0.212671 * r + 0.715160 * g + 0.072169 * b;
    final z = (0.019334 * r + 0.119193 * g + 0.950227 * b) / 1.088754;
    final fy = _labF(y);
    out[i * 3] = y > 0.008856 ? 116.0 * fy - 16.0 : 903.3 * y;
    out[i * 3 + 1] = 500.0 * (_labF(x) - fy);
    out[i * 3 + 2] = 200.0 * (fy - _labF(z));
  }
  return LabImage(w, h, out);
}

/// Bilinear Lab sample at float coords (clamped) -> writes L,a,b into [out].
void sampleLab(LabImage img, double x, double y, Float64List out, int o) {
  final w = img.width, h = img.height;
  var xc = x < 0 ? 0.0 : (x > w - 1.001 ? w - 1.001 : x);
  var yc = y < 0 ? 0.0 : (y > h - 1.001 ? h - 1.001 : y);
  final x0 = xc.floor(), y0 = yc.floor();
  final fx = xc - x0, fy = yc - y0;
  final d = img.data;
  final i00 = (y0 * w + x0) * 3, i01 = i00 + 3;
  final i10 = i00 + w * 3, i11 = i10 + 3;
  final w00 = (1 - fx) * (1 - fy), w01 = fx * (1 - fy);
  final w10 = (1 - fx) * fy, w11 = fx * fy;
  for (var c = 0; c < 3; c++) {
    out[o + c] =
        d[i00 + c] * w00 + d[i01 + c] * w01 + d[i10 + c] * w10 + d[i11 + c] * w11;
  }
}

// ---------------------------------------------------------------- helpers
double _median(List<double> v) {
  if (v.isEmpty) return 0;
  final s = List<double>.from(v)..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : 0.5 * (s[m - 1] + s[m]);
}

/// TLS line through points -> centroid (cx,cy) + unit dir (dx,dy),
/// oriented dy>=0 like the Python reference.
List<double> tlsFit(Float64List xs, Float64List ys) {
  final n = xs.length;
  var cx = 0.0, cy = 0.0;
  for (var i = 0; i < n; i++) {
    cx += xs[i];
    cy += ys[i];
  }
  cx /= n;
  cy /= n;
  var sxx = 0.0, sxy = 0.0, syy = 0.0;
  for (var i = 0; i < n; i++) {
    final ux = xs[i] - cx, uy = ys[i] - cy;
    sxx += ux * ux;
    sxy += ux * uy;
    syy += uy * uy;
  }
  final ang = 0.5 * math.atan2(2 * sxy, sxx - syy);
  var dx = math.cos(ang), dy = math.sin(ang);
  if (dy < 0 || (dy == 0 && dx < 0)) {
    dx = -dx;
    dy = -dy;
  }
  return [cx, cy, dx, dy];
}

/// Homogeneous line through point (px,py) with direction (dx,dy).
List<double> lineHomog(double px, double py, double dx, double dy) =>
    [-dy, dx, dy * px - dx * py];

double segAngleFromVertical(double dx, double dy) =>
    math.atan2(dx.abs(), dy.abs()).abs() * 180.0 / math.pi;

/// Smallest-eigenvector of a symmetric 3x3 (Jacobi) — for VP refinement.
List<double> smallestEig3(List<double> m) {
  // m: row-major symmetric 3x3 (will be copied)
  final a = List<double>.from(m);
  final v = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];
  for (var sweep = 0; sweep < 24; sweep++) {
    var off = 0.0;
    for (final ij in const [
      [0, 1],
      [0, 2],
      [1, 2]
    ]) {
      off += a[ij[0] * 3 + ij[1]] * a[ij[0] * 3 + ij[1]];
    }
    if (off < 1e-18) break;
    for (final ij in const [
      [0, 1],
      [0, 2],
      [1, 2]
    ]) {
      final p = ij[0], q = ij[1];
      final apq = a[p * 3 + q];
      if (apq.abs() < 1e-15) continue;
      final theta = 0.5 * math.atan2(2 * apq, a[q * 3 + q] - a[p * 3 + p]);
      final c = math.cos(theta), s = math.sin(theta);
      for (var k = 0; k < 3; k++) {
        final akp = a[k * 3 + p], akq = a[k * 3 + q];
        a[k * 3 + p] = c * akp - s * akq;
        a[k * 3 + q] = s * akp + c * akq;
      }
      for (var k = 0; k < 3; k++) {
        final apk = a[p * 3 + k], aqk = a[q * 3 + k];
        a[p * 3 + k] = c * apk - s * aqk;
        a[q * 3 + k] = s * apk + c * aqk;
      }
      for (var k = 0; k < 3; k++) {
        final vkp = v[k * 3 + p], vkq = v[k * 3 + q];
        v[k * 3 + p] = c * vkp - s * vkq;
        v[k * 3 + q] = s * vkp + c * vkq;
      }
    }
  }
  var best = 0;
  for (var i = 1; i < 3; i++) {
    if (a[i * 3 + i].abs() < a[best * 3 + best].abs()) best = i;
  }
  return [v[best], v[3 + best], v[6 + best]];
}

/// Solve a 3x3 linear system (Gaussian elimination, partial pivot).
List<double>? solve3(List<double> a, List<double> b) {
  final m = [
    [a[0], a[1], a[2], b[0]],
    [a[3], a[4], a[5], b[1]],
    [a[6], a[7], a[8], b[2]],
  ];
  for (var col = 0; col < 3; col++) {
    var piv = col;
    for (var r = col + 1; r < 3; r++) {
      if (m[r][col].abs() > m[piv][col].abs()) piv = r;
    }
    if (m[piv][col].abs() < 1e-12) return null;
    final tmp = m[col];
    m[col] = m[piv];
    m[piv] = tmp;
    for (var r = 0; r < 3; r++) {
      if (r == col) continue;
      final f = m[r][col] / m[col][col];
      for (var c = col; c < 4; c++) {
        m[r][c] -= f * m[col][c];
      }
    }
  }
  return [m[0][3] / m[0][0], m[1][3] / m[1][1], m[2][3] / m[2][2]];
}

// ---------------------------------------------------------------- Stripe
class Stripe {
  Float64List sx, sy; // support centreline points
  double labL, labA, labB; // median stripe color
  int lsign; // +1 brighter than flanks, -1 darker
  int id = -1;
  bool isLong = false;
  late double cx, cy, dx, dy, p1x, p1y, p2x, p2y, length;

  Stripe(this.sx, this.sy, this.labL, this.labA, this.labB, this.lsign) {
    refit();
  }

  void refit() {
    // Robust trimmed TLS: support can be contaminated by locally-collinear
    // clutter (e.g. the white net tape where a sideline crosses behind it),
    // which tilts a plain least-squares line so it diverges from the paint
    // at the far end. Iterate: fit -> drop MAD-scaled outliers -> refit.
    for (var round = 0; ; round++) {
      final f = tlsFit(sx, sy);
      cx = f[0];
      cy = f[1];
      dx = f[2];
      dy = f[3];
      if (round >= 2 || sx.length < 12) break;
      final n = sx.length;
      final off = Float64List(n);
      final absOff = <double>[];
      for (var i = 0; i < n; i++) {
        off[i] = -(sx[i] - cx) * dy + (sy[i] - cy) * dx;
        absOff.add(off[i].abs());
      }
      absOff.sort();
      final mad = absOff[n ~/ 2];
      final thr = math.max(1.2, 3.0 * mad * 1.4826);
      final keepX = <double>[], keepY = <double>[];
      for (var i = 0; i < n; i++) {
        if (off[i].abs() <= thr) {
          keepX.add(sx[i]);
          keepY.add(sy[i]);
        }
      }
      if (keepX.length == n || keepX.length < math.max(6, n ~/ 2)) break;
      sx = Float64List.fromList(keepX);
      sy = Float64List.fromList(keepY);
    }
    var tMin = double.infinity, tMax = -double.infinity;
    for (var i = 0; i < sx.length; i++) {
      final t = (sx[i] - cx) * dx + (sy[i] - cy) * dy;
      if (t < tMin) tMin = t;
      if (t > tMax) tMax = t;
    }
    p1x = cx + dx * tMin;
    p1y = cy + dy * tMin;
    p2x = cx + dx * tMax;
    p2y = cy + dy * tMax;
    length = tMax - tMin;
  }

  List<double> homog() => lineHomog(cx, cy, dx, dy);
}

// ------------------------------------------------- stripe profile machinery
// offset/width search grid (mirrors Python _COMBOS, as integer index bands)
class _Combos {
  late final int m;
  late final Float64List off;
  late final Int32List innerA, innerB, flLA, flLB, flRA, flRB;
  late final int tCount;

  _Combos() {
    tCount = ((2 * kProfT) / kProfStep).round() + 1; // 37
    int idx(double t) {
      final i = ((t + kProfT) / kProfStep).round();
      return i < 0 ? 0 : (i > tCount ? tCount : i);
    }

    final offs = <double>[];
    final ia = <int>[], ib = <int>[], la = <int>[], lb = <int>[];
    final ra = <int>[], rb = <int>[];
    for (var c = -5.0; c <= 5.0 + 1e-9; c += 0.5) {
      for (final hh in const [1.0, 1.5, 2.0, 2.5, 3.5, 5.0]) {
        final flIn = hh + 0.7, flOut = hh + 3.0;
        if (c.abs() + flOut > kProfT) continue;
        offs.add(c);
        final a0 = idx(c - 0.6 * hh);
        var b0 = idx(c + 0.6 * hh);
        if (b0 <= a0) b0 = a0 + 1;
        ia.add(a0);
        ib.add(b0);
        la.add(idx(c - flOut));
        lb.add(idx(c - flIn));
        ra.add(idx(c + flIn));
        rb.add(idx(c + flOut));
      }
    }
    m = offs.length;
    off = Float64List.fromList(offs);
    innerA = Int32List.fromList(ia);
    innerB = Int32List.fromList(ib);
    flLA = Int32List.fromList(la);
    flLB = Int32List.fromList(lb);
    flRA = Int32List.fromList(ra);
    flRB = Int32List.fromList(rb);
  }
}

final _Combos _combos = _Combos();

/// Per-sample stripe search over one perpendicular profile.
/// prof: tCount*3 Lab floats. Returns [offC, dIn, L, a, b, lsign].
void _searchProfile(Float64List prof, Float64List out6) {
  final t = _combos.tCount;
  // prefix sums (t+1)*3
  final cum = Float64List((t + 1) * 3);
  for (var i = 0; i < t; i++) {
    cum[(i + 1) * 3] = cum[i * 3] + prof[i * 3];
    cum[(i + 1) * 3 + 1] = cum[i * 3 + 1] + prof[i * 3 + 1];
    cum[(i + 1) * 3 + 2] = cum[i * 3 + 2] + prof[i * 3 + 2];
  }
  double bandL(int a, int b, int c) =>
      (cum[b * 3 + c] - cum[a * 3 + c]) / ((b - a) > 0 ? (b - a) : 1);
  var bestD = -1.0, bestOff = 0.0;
  var bL = 0.0, bA = 0.0, bB = 0.0, bFlankL = 0.0;
  for (var k = 0; k < _combos.m; k++) {
    final ia = _combos.innerA[k], ib = _combos.innerB[k];
    final inL = bandL(ia, ib, 0), inA = bandL(ia, ib, 1), inB = bandL(ia, ib, 2);
    final la = _combos.flLA[k], lb = _combos.flLB[k];
    final ra = _combos.flRA[k], rb = _combos.flRB[k];
    final llL = bandL(la, lb, 0), llA = bandL(la, lb, 1), llB = bandL(la, lb, 2);
    final rrL = bandL(ra, rb, 0), rrA = bandL(ra, rb, 1), rrB = bandL(ra, rb, 2);
    final dL = math.sqrt((inL - llL) * (inL - llL) +
        (inA - llA) * (inA - llA) +
        (inB - llB) * (inB - llB));
    final dR = math.sqrt((inL - rrL) * (inL - rrL) +
        (inA - rrA) * (inA - rrA) +
        (inB - rrB) * (inB - rrB));
    final dIn = dL < dR ? dL : dR;
    if (dIn > bestD) {
      bestD = dIn;
      bestOff = _combos.off[k];
      bL = inL;
      bA = inA;
      bB = inB;
      bFlankL = 0.5 * (llL + rrL);
    }
  }
  out6[0] = bestOff;
  out6[1] = bestD;
  out6[2] = bL;
  out6[3] = bA;
  out6[4] = bB;
  out6[5] = bL >= bFlankL ? 1.0 : -1.0;
}

/// Build one perpendicular profile at (px,py) with normal (nx,ny).
void _fillProfile(LabImage lab, double px, double py, double nx, double ny,
    Float64List prof) {
  final t = _combos.tCount;
  for (var j = 0; j < t; j++) {
    final tt = -kProfT + j * kProfStep;
    sampleLab(lab, px + tt * nx, py + tt * ny, prof, j * 3);
  }
}

// ---------------------------------------------------------------- stage 1
Stripe? validateSegment(LabImage lab, List<double> seg) {
  final p1x = seg[0], p1y = seg[1], p2x = seg[2], p2y = seg[3];
  final len = math.sqrt(
      (p2x - p1x) * (p2x - p1x) + (p2y - p1y) * (p2y - p1y));
  if (len < 18) return null;
  final dx = (p2x - p1x) / len, dy = (p2y - p1y) / len;
  final nx = -dy, ny = dx;
  final k = (len / kSampleStep).floor() + 1;
  if (k < 2) return null;
  final prof = Float64List(_combos.tCount * 3);
  final res = Float64List(6);
  final offs = Float64List(k), dIns = Float64List(k);
  final labL = Float64List(k), labA = Float64List(k), labB = Float64List(k);
  final signs = Int32List(k);
  for (var i = 0; i < k; i++) {
    final bx = p1x + dx * (i * kSampleStep), by = p1y + dy * (i * kSampleStep);
    _fillProfile(lab, bx, by, nx, ny, prof);
    _searchProfile(prof, res);
    offs[i] = res[0];
    dIns[i] = res[1];
    labL[i] = res[2];
    labA[i] = res[3];
    labB[i] = res[4];
    signs[i] = res[5].toInt();
  }
  final okIdx = <int>[];
  for (var i = 0; i < k; i++) {
    if (dIns[i] >= kTauStripe) okIdx.add(i);
  }
  if (okIdx.length < kMinInliers) return null;
  final medA = _median([for (final i in okIdx) labA[i]]);
  final medB = _median([for (final i in okIdx) labB[i]]);
  var signSum = 0;
  for (final i in okIdx) {
    signSum += signs[i];
  }
  final medSign = signSum >= 0 ? 1 : -1;
  final inl = <int>[];
  for (var i = 0; i < k; i++) {
    if (dIns[i] < kTauStripe) continue;
    final da = labA[i] - medA, db = labB[i] - medB;
    if (math.sqrt(da * da + db * db) > kAbTol) continue;
    if (signs[i] != medSign) continue;
    inl.add(i);
  }
  if (inl.length < kMinInliers || inl.length < kMinInlierFrac * k) return null;
  final sx = Float64List(inl.length), sy = Float64List(inl.length);
  for (var j = 0; j < inl.length; j++) {
    final i = inl[j];
    sx[j] = p1x + dx * (i * kSampleStep) + offs[i] * nx;
    sy[j] = p1y + dy * (i * kSampleStep) + offs[i] * ny;
  }
  final medL = _median([for (final i in inl) labL[i]]);
  final medA2 = _median([for (final i in inl) labA[i]]);
  final medB2 = _median([for (final i in inl) labB[i]]);
  return Stripe(sx, sy, medL, medA2, medB2, medSign);
}

void extendStripe(LabImage lab, Stripe st) {
  final w = lab.width, h = lab.height;
  final prof = Float64List(_combos.tCount * 3);
  final res = Float64List(6);
  final newX = <double>[], newY = <double>[];
  for (final sgn in const [-1.0, 1.0]) {
    var px = sgn > 0 ? st.p2x : st.p1x;
    var py = sgn > 0 ? st.p2y : st.p1y;
    final nx = -st.dy, ny = st.dx;
    var fails = 0;
    for (var step = 0; step < kExtMaxSteps; step++) {
      px += sgn * kExtStep * st.dx;
      py += sgn * kExtStep * st.dy;
      if (px < -20 || px > w + 20 || py < -20 || py > h + 20) break;
      _fillProfile(lab, px, py, nx, ny, prof);
      _searchProfile(prof, res);
      final da = res[3] - st.labA, db = res[4] - st.labB;
      final good = res[1] >= kTauStripe * 0.8 &&
          res[0].abs() <= 4.0 &&
          math.sqrt(da * da + db * db) <= kAbTol + 2 &&
          res[5].toInt() == st.lsign;
      if (good) {
        newX.add(px + res[0] * nx);
        newY.add(py + res[0] * ny);
        fails = 0;
      } else {
        fails++;
        if (fails >= kExtFailStop) break;
      }
    }
  }
  if (newX.isNotEmpty) {
    final sx = Float64List(st.sx.length + newX.length);
    final sy = Float64List(st.sy.length + newY.length);
    sx.setAll(0, st.sx);
    sy.setAll(0, st.sy);
    sx.setAll(st.sx.length, newX);
    sy.setAll(st.sy.length, newY);
    st.sx = sx;
    st.sy = sy;
    st.refit();
  }
}

List<Stripe> mergeStripes(List<Stripe> stripes) {
  final n = stripes.length;
  final parent = List<int>.generate(n, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final a = stripes[i], b = stripes[j];
      final dot = (a.dx * b.dx + a.dy * b.dy).abs().clamp(0.0, 1.0);
      final ang = math.acos(dot) * 180.0 / math.pi;
      if (ang > kMergeAng) continue;
      final la = a.homog();
      final nrm = math.sqrt(la[0] * la[0] + la[1] * la[1]);
      final maxLen = a.length > b.length ? a.length : b.length;
      final off1 = (la[0] * b.p1x + la[1] * b.p1y + la[2]).abs() / nrm;
      final off2 = (la[0] * b.p2x + la[1] * b.p2y + la[2]).abs() / nrm;
      if ((off1 > off2 ? off1 : off2) > kMergeOff + 0.004 * maxLen) continue;
      final da = a.labA - b.labA, db = a.labB - b.labB;
      if (math.sqrt(da * da + db * db) > kMergeAb || a.lsign != b.lsign) {
        continue;
      }
      double proj(Stripe s, double x, double y) =>
          (x - a.cx) * a.dx + (y - a.cy) * a.dy;
      var a0 = proj(a, a.p1x, a.p1y), a1 = proj(a, a.p2x, a.p2y);
      if (a0 > a1) {
        final t = a0;
        a0 = a1;
        a1 = t;
      }
      var b0 = proj(a, b.p1x, b.p1y), b1 = proj(a, b.p2x, b.p2y);
      if (b0 > b1) {
        final t = b0;
        b0 = b1;
        b1 = t;
      }
      final gap = (a0 > b0 ? a0 : b0) - (a1 < b1 ? a1 : b1);
      if (gap > kMergeGap) continue;
      final pi = find(i), pj = find(j);
      if (pi != pj) parent[pj] = pi;
    }
  }
  final groups = <int, List<Stripe>>{};
  for (var i = 0; i < n; i++) {
    groups.putIfAbsent(find(i), () => []).add(stripes[i]);
  }
  final out = <Stripe>[];
  for (final sts in groups.values) {
    var total = 0;
    for (final s in sts) {
      total += s.sx.length;
    }
    final sx = Float64List(total), sy = Float64List(total);
    var o = 0;
    for (final s in sts) {
      sx.setAll(o, s.sx);
      sy.setAll(o, s.sy);
      o += s.sx.length;
    }
    out.add(Stripe(
        sx,
        sy,
        _median([for (final s in sts) s.labL]),
        _median([for (final s in sts) s.labA]),
        _median([for (final s in sts) s.labB]),
        sts.first.lsign));
  }
  return out;
}

List<Stripe> dedupeStripes(List<Stripe> stripes) {
  final sorted = List<Stripe>.from(stripes)
    ..sort((a, b) => b.length.compareTo(a.length));
  final kept = <Stripe>[];
  for (final s in sorted) {
    var dup = false;
    for (final k in kept) {
      final dot = (s.dx * k.dx + s.dy * k.dy).abs().clamp(0.0, 1.0);
      if (math.acos(dot) * 180.0 / math.pi > 1.5) continue;
      final lk = k.homog();
      final nrm = math.sqrt(lk[0] * lk[0] + lk[1] * lk[1]);
      final o1 = (lk[0] * s.p1x + lk[1] * s.p1y + lk[2]).abs() / nrm;
      final o2 = (lk[0] * s.p2x + lk[1] * s.p2y + lk[2]).abs() / nrm;
      final offm = o1 > o2 ? o1 : o2;
      double proj(double x, double y) => (x - k.cx) * k.dx + (y - k.cy) * k.dy;
      var s0 = proj(s.p1x, s.p1y), s1 = proj(s.p2x, s.p2y);
      if (s0 > s1) {
        final t = s0;
        s0 = s1;
        s1 = t;
      }
      var k0 = proj(k.p1x, k.p1y), k1 = proj(k.p2x, k.p2y);
      if (k0 > k1) {
        final t = k0;
        k0 = k1;
        k1 = t;
      }
      final overlap = (s1 < k1 ? s1 : k1) - (s0 > k0 ? s0 : k0);
      if (offm < 5.0 && overlap > 0.4 * s.length) {
        dup = true;
        break;
      }
    }
    if (!dup) kept.add(s);
  }
  return kept;
}

List<Stripe> detectStripes(
    LabImage lab, double minLen, List<List<double>> seeds) {
  var stripes = <Stripe>[];
  for (final seg in seeds) {
    final st = validateSegment(lab, seg);
    if (st != null) stripes.add(st);
  }
  stripes = dedupeStripes(mergeStripes(stripes));
  stripes = [for (final s in stripes) if (s.length >= kShortMin) s];
  for (final s in stripes) {
    extendStripe(lab, s);
  }
  stripes = dedupeStripes(mergeStripes(stripes));
  stripes = [for (final s in stripes) if (s.length >= kShortMin) s];
  for (var i = 0; i < stripes.length; i++) {
    stripes[i].id = i;
    stripes[i].isLong = stripes[i].length >= minLen;
  }
  return stripes;
}

// ---------------------------------------------------------------- pencils
/// Fit a line CONSTRAINED through the (finite) VP to the stripe's support:
/// returns [rmsPx, thetaOriented]. Contamination near the VP (where pencil
/// lines converge within a few px) barely moves this fit, unlike the free
/// TLS direction.
List<double> vpConstrainedFit(List<double> v, Stripe s) {
  final vx = v[0] / v[2], vy = v[1] / v[2];
  var sxx = 0.0, sxy = 0.0, syy = 0.0;
  final n = s.sx.length;
  for (var i = 0; i < n; i++) {
    final rx = s.sx[i] - vx, ry = s.sy[i] - vy;
    sxx += rx * rx;
    sxy += rx * ry;
    syy += ry * ry;
  }
  final ang = 0.5 * math.atan2(2 * sxy, sxx - syy);
  var ux = math.cos(ang), uy = math.sin(ang);
  final mx = 0.5 * (s.p1x + s.p2x) - vx, my = 0.5 * (s.p1y + s.p2y) - vy;
  if (ux * mx + uy * my < 0) {
    ux = -ux;
    uy = -uy;
  }
  var rss = 0.0;
  for (var i = 0; i < n; i++) {
    final rx = s.sx[i] - vx, ry = s.sy[i] - vy;
    final d = ux * ry - uy * rx;
    rss += d * d;
  }
  return [math.sqrt(rss / n), math.atan2(uy, ux)];
}

double vpResidualDeg(List<double> v, Stripe s) {
  if (v[2].abs() < 1e-9) {
    final n = math.sqrt(v[0] * v[0] + v[1] * v[1]);
    final dot = ((v[0] / n) * s.dx + (v[1] / n) * s.dy).abs().clamp(0.0, 1.0);
    return math.acos(dot) * 180.0 / math.pi;
  }
  final px = v[0] / v[2], py = v[1] / v[2];
  final mx = 0.5 * (s.p1x + s.p2x), my = 0.5 * (s.p1y + s.p2y);
  final ux = px - mx, uy = py - my;
  final nu = math.sqrt(ux * ux + uy * uy);
  if (nu < 1e-6) return 0.0;
  final dot = ((ux / nu) * s.dx + (uy / nu) * s.dy).abs().clamp(0.0, 1.0);
  return math.acos(dot) * 180.0 / math.pi;
}

List<double> _cross(List<double> a, List<double> b) => [
      a[1] * b[2] - a[2] * b[1],
      a[2] * b[0] - a[0] * b[2],
      a[0] * b[1] - a[1] * b[0]
    ];

class Pencil {
  final List<double> v; // homogeneous VP
  final List<Stripe> members;
  Pencil(this.v, this.members);
}

List<Pencil> findPencils(List<Stripe> stripes, {int maxGroups = 7}) {
  // PRODUCT CONSTRAINT (Majid): cameras film from the END of the court —
  // either end, anywhere across the back, yaw within ~±45° — so longitudinal
  // lines always recede upward-diagonally, never horizontal. Truly horizontal
  // stripes (transverse paint, net bands, rails) cannot seed or join a
  // longitudinal pencil, and a candidate set must read vertical-ish as a
  // whole (kSetMeanVertDeg).
  final vert = [
    for (final s in stripes)
      if (segAngleFromVertical(s.dx, s.dy) <= kVertMaxDeg) s
  ];
  final longs = [for (final s in vert) if (s.isLong) s];
  final shorts = [for (final s in vert) if (!s.isLong) s];
  if (longs.length < 3) return [];
  // Score EVERY pair-seeded VP candidate, then keep the strongest DISTINCT
  // ones. (The previous greedy remove-inliers loop starved later VPs: a
  // coincidental mega-VP could consume most court lines from the seeding
  // pool, leaving too few to ever seed the true court VP.)
  final cands = <(List<double>, List<Stripe>, double)>[];
  for (var i = 0; i < longs.length; i++) {
    for (var j = i + 1; j < longs.length; j++) {
      final v = _cross(longs[i].homog(), longs[j].homog());
      final nv = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
      if (nv < 1e-9) continue;
      final inl = [
        for (final s in longs)
          if (vpResidualDeg(v, s) <= vpTolDeg(s.length)) s
      ];
      if (inl.length < 3) continue;
      var wsum = 0.0;
      for (final s in inl) {
        wsum += math.sqrt(s.length);
      }
      cands.add((v, inl, wsum));
    }
  }
  cands.sort((a, b) => b.$3.compareTo(a.$3));
  final pencils = <Pencil>[];
  final acceptedLongSets = <Set<Stripe>>[];
  for (final cand in cands) {
    if (pencils.length >= maxGroups) break;
    final candSet = cand.$2.toSet();
    var dup = false;
    for (final acc in acceptedLongSets) {
      if (candSet.intersection(acc).length >= 0.7 * candSet.length) {
        dup = true;
        break;
      }
    }
    if (dup) continue;
    var v = cand.$1;
    var inl = cand.$2;
    for (var it = 0; it < 2; it++) {
      // refine: smallest eigenvector of sum w * l l^T (l normalized)
      final m = List<double>.filled(9, 0);
      for (final s in inl) {
        final l = s.homog();
        final nrm = math.sqrt(l[0] * l[0] + l[1] * l[1]);
        final w = math.sqrt(s.length);
        final ln = [l[0] / nrm * w, l[1] / nrm * w, l[2] / nrm * w];
        for (var r = 0; r < 3; r++) {
          for (var c = 0; c < 3; c++) {
            m[r * 3 + c] += ln[r] * ln[c];
          }
        }
      }
      v = smallestEig3(m);
      inl = [
        for (final s in longs)
          if (vpResidualDeg(v, s) <= vpTolDeg(s.length)) s
      ];
      if (inl.length < 3) break;
    }
    if (inl.length < 3) continue;
    // membership is NOT exclusive: a line belongs to every pencil whose VP
    // it passes near. Fallback: a stripe whose free direction drifted (line
    // blending near the VP) still belongs if its SUPPORT fits a line through
    // the VP at low residual.
    final inlSet2 = inl.toSet();
    final members = [
      ...inl,
      for (final s in longs)
        if (!inlSet2.contains(s) &&
            v[2].abs() > 1e-9 &&
            vpResidualDeg(v, s) <= 6.0 &&
            vpConstrainedFit(v, s)[0] <= 3.2)
          s,
      for (final s in shorts)
        if (vpResidualDeg(v, s) <= vpTolDeg(s.length)) s,
    ];
    pencils.add(Pencil(v, members));
    acceptedLongSets.add(inl.toSet());
  }
  return pencils;
}

/// Per-line pencil parameters: absolute direction angles (unwrapped into one
/// continuous window) + lever arms. For VP at infinity: perpendicular offsets.
class PencilAngles {
  final Float64List theta, lever;
  final bool finite;
  PencilAngles(this.theta, this.lever, this.finite);
}

PencilAngles pencilAngles(List<double> v, List<Stripe> stripes) {
  final n = stripes.length;
  final th = Float64List(n), lev = Float64List(n);
  if (v[2].abs() > 1e-9) {
    final vx = v[0] / v[2], vy = v[1] / v[2];
    for (var i = 0; i < n; i++) {
      final s = stripes[i];
      final mx = 0.5 * (s.p1x + s.p2x), my = 0.5 * (s.p1y + s.p2y);
      final rx = mx - vx, ry = my - vy;
      // constrained-through-VP direction: the right pencil parameter, and
      // robust to line-blend contamination near the VP
      th[i] = vpConstrainedFit(v, s)[1];
      lev[i] = math.sqrt(rx * rx + ry * ry);
    }
    // unwrap around the first line, keep ABSOLUTE angles
    final th0 = th[0];
    for (var i = 0; i < n; i++) {
      var d = th[i] - th0;
      d = (d + math.pi) % (2 * math.pi) - math.pi;
      th[i] = th0 + d;
    }
    return PencilAngles(th, lev, true);
  }
  final un = math.sqrt(v[0] * v[0] + v[1] * v[1]);
  final ux = v[0] / un, uy = v[1] / un;
  for (var i = 0; i < n; i++) {
    final s = stripes[i];
    final mx = 0.5 * (s.p1x + s.p2x), my = 0.5 * (s.p1y + s.p2y);
    th[i] = -uy * mx + ux * my;
    lev[i] = 1.0;
  }
  return PencilAngles(th, lev, false);
}

// ---------------------------------------------------------------- 1D fit
class Fit1D {
  final double a, b, c, xs, sc;
  final Float64List res;
  Fit1D(this.a, this.b, this.c, this.xs, this.sc, this.res);

  double? predict(double xq) {
    final d = c * (xq / xs) + 1.0;
    if (d.abs() < 1e-9) return null;
    return (a * (xq / xs) + b) / d * sc;
  }

  double? invert(double tq) {
    final tn = tq / sc;
    final d = tn * c - a;
    if (d.abs() < 1e-12) return null;
    return (b - tn) / d * xs;
  }

  double get rms {
    var s = 0.0;
    for (final r in res) {
      s += r * r;
    }
    return math.sqrt(s / res.length);
  }

  double get maxAbs {
    var m = 0.0;
    for (final r in res) {
      if (r.abs() > m) m = r.abs();
    }
    return m;
  }
}

Fit1D? fit1dHomography(List<double> x, Float64List tau, Float64List wgt) {
  final n = x.length;
  var xs = 0.0, sc = 1e-6;
  for (final v in x) {
    if (v.abs() > xs) xs = v.abs();
  }
  for (final v in tau) {
    if (v.abs() > sc) sc = v.abs();
  }
  final xn = [for (final v in x) v / xs];
  final tn = [for (final v in tau) v / sc];
  final wn = [for (final v in wgt) v * sc];
  // least squares: rows [Xn, 1, -Xn*tn]*wn = tn*wn
  List<double>? lstsq(List<List<double>> rows, List<double> y) {
    final ata = List<double>.filled(9, 0);
    final aty = List<double>.filled(3, 0);
    for (var i = 0; i < rows.length; i++) {
      for (var r = 0; r < 3; r++) {
        aty[r] += rows[i][r] * y[i];
        for (var c = 0; c < 3; c++) {
          ata[r * 3 + c] += rows[i][r] * rows[i][c];
        }
      }
    }
    return solve3(ata, aty);
  }

  var theta = lstsq([
    for (var i = 0; i < n; i++) [xn[i] * wn[i], wn[i], -xn[i] * tn[i] * wn[i]]
  ], [
    for (var i = 0; i < n; i++) tn[i] * wn[i]
  ]);
  if (theta == null) return null;
  for (var it = 0; it < 5; it++) {
    final a = theta![0], b = theta[1], c = theta[2];
    final den = [for (var i = 0; i < n; i++) c * xn[i] + 1.0];
    var bad = false;
    for (final d in den) {
      if (d.abs() < 1e-6 || d.sign != den[0].sign) bad = true;
    }
    if (bad) return null;
    final r = [
      for (var i = 0; i < n; i++) ((a * xn[i] + b) / den[i] - tn[i]) * wn[i]
    ];
    final jrows = [
      for (var i = 0; i < n; i++)
        [
          xn[i] / den[i] * wn[i],
          1.0 / den[i] * wn[i],
          -xn[i] * (a * xn[i] + b) / (den[i] * den[i]) * wn[i]
        ]
    ];
    final dth = lstsq(jrows, [for (final v in r) -v]);
    if (dth == null) break;
    theta = [a + dth[0], b + dth[1], c + dth[2]];
  }
  final a = theta![0], b = theta[1], c = theta[2];
  final den = [for (var i = 0; i < n; i++) c * xn[i] + 1.0];
  for (final d in den) {
    if (d.abs() < 1e-6 || d.sign != den[0].sign) return null;
  }
  final res = Float64List(n);
  for (var i = 0; i < n; i++) {
    res[i] = ((a * xn[i] + b) / den[i] - tn[i]) * wn[i];
  }
  return Fit1D(a, b, c, xs, sc, res);
}

/// Implied image scale (px per model-metre) at model position [xq], for a
/// fit whose tau values convert to px via weight [wq]: wq * |dt/dx|(xq).
double fitPxPerM(Fit1D fit, double xq, double wq) {
  final xn = xq / fit.xs;
  final den = fit.c * xn + 1.0;
  if (den.abs() < 1e-9) return double.infinity;
  // d(tau)/dx = sc/xs * (a - b*c) / (c*x/xs + 1)^2
  final d = (fit.a - fit.b * fit.c) / (den * den) * fit.sc / fit.xs;
  return wq * d.abs();
}

/// Max/min implied px-per-metre across the slots: a real ground-plane court
/// cannot have wildly different width-scales side by side (see
/// kWeakRatioMax).
double fitScaleRatio(Fit1D fit, List<double> xs, List<double> ws) {
  var lo = double.infinity, hi = 0.0;
  for (var i = 0; i < xs.length; i++) {
    final s = fitPxPerM(fit, xs[i], ws[i]);
    if (s < lo) lo = s;
    if (s > hi) hi = s;
  }
  return lo <= 0 ? double.infinity : hi / lo;
}

// ---------------------------------------------------------------- probe
class ProbeResult {
  final double ev, runPx, massPx;
  // sub-pixel paint ridge points of the best run (for refitting the predicted
  // line onto the actual paint), null if no quality run
  final Float64List? ridgeX, ridgeY;
  ProbeResult(this.ev, this.runPx, this.massPx, this.ridgeX, this.ridgeY);
}

ProbeResult probeLineEvidence(LabImage lab, double p0x, double p0y, double dx,
    double dy, double expA, double expB, int expSign,
    {double? tmin, List<Stripe> avoid = const []}) {
  final w = lab.width, h = lab.height;
  final cand = <double>[];
  if (dx.abs() > 1e-9) {
    cand.add((0 - p0x) / dx);
    cand.add((w - 1 - p0x) / dx);
  }
  if (dy.abs() > 1e-9) {
    cand.add((0 - p0y) / dy);
    cand.add((h - 1 - p0y) / dy);
  }
  final ts = <double>[];
  for (final t in cand) {
    if (t <= -1e9 || t >= 1e9) continue;
    final x = p0x + t * dx, y = p0y + t * dy;
    if (x >= -1 && x <= w && y >= -1 && y <= h) ts.add(t);
  }
  ts.sort();
  if (ts.length < 2) return ProbeResult(0, 0, 0, null, null);
  var t0 = ts.first;
  final t1 = ts.last;
  if (tmin != null) {
    t0 = math.max(t0, tmin);
    if (t1 - t0 < 2 * kSampleStep) return ProbeResult(0, 0, 0, null, null);
  }
  final n = math.max(((t1 - t0) / kSampleStep).floor(), 2);
  final nx = -dy, ny = dx;
  final prof = Float64List(_combos.tCount * 3);
  final res = Float64List(6);
  final hit = List<bool>.filled(n, false);
  final offArr = Float64List(n);
  final baseX = Float64List(n), baseY = Float64List(n);
  final innerA = Float64List(n), innerB = Float64List(n);
  final tt = Float64List(n);
  // precompute avoid lines (normalized homog)
  final avoidL = [
    for (final s in avoid)
      () {
        final l = s.homog();
        final nrm = math.sqrt(l[0] * l[0] + l[1] * l[1]);
        return [l[0] / nrm, l[1] / nrm, l[2] / nrm];
      }()
  ];
  for (var i = 0; i < n; i++) {
    final t = t0 + (t1 - t0) * i / (n - 1);
    tt[i] = t;
    final bx = p0x + t * dx, by = p0y + t * dy;
    baseX[i] = bx;
    baseY[i] = by;
    _fillProfile(lab, bx, by, nx, ny, prof);
    _searchProfile(prof, res);
    final da = res[3] - expA, db = res[4] - expB;
    var ok = res[1] >= kTauStripe * 0.8 &&
        res[0].abs() <= 4.0 &&
        math.sqrt(da * da + db * db) <= kAbTol + 4 &&
        res[5].toInt() == expSign;
    if (ok && avoidL.isNotEmpty) {
      // competitive void: hit belongs to predicted only if its ridge is
      // closer to the predicted line than to any known line
      final rx = bx + res[0] * nx, ry = by + res[0] * ny;
      for (final l in avoidL) {
        if ((l[0] * rx + l[1] * ry + l[2]).abs() <= res[0].abs() + 1.0) {
          ok = false;
          break;
        }
      }
    }
    hit[i] = ok;
    offArr[i] = res[0];
    innerA[i] = res[3];
    innerB[i] = res[4];
  }
  final hitIdx = <int>[];
  for (var i = 0; i < n; i++) {
    if (hit[i]) hitIdx.add(i);
  }
  if (hitIdx.isEmpty) return ProbeResult(0, 0, 0, null, null);
  final ev = hitIdx.length / n;
  final massPx = hitIdx.length * kSampleStep;
  // longest run tolerating gaps of <= 3 samples
  final runs = <List<int>>[];
  var cur = <int>[hitIdx.first];
  for (var i = 1; i < hitIdx.length; i++) {
    if (hitIdx[i] - hitIdx[i - 1] > 4) {
      runs.add(cur);
      cur = [];
    }
    cur.add(hitIdx[i]);
  }
  runs.add(cur);
  var best = runs.first;
  for (final r in runs) {
    if (r.last - r.first > best.last - best.first) best = r;
  }
  // run quality: dense, collinear (sub-pixel), chroma-tight
  final nRun = best.last - best.first + 1;
  final density = best.length / nRun;
  var stt = 0.0, sto = 0.0, st2 = 0.0, so = 0.0;
  for (final i in best) {
    stt += tt[i];
    sto += tt[i] * offArr[i];
    st2 += tt[i] * tt[i];
    so += offArr[i];
  }
  final m = best.length.toDouble();
  final denom = st2 - stt * stt / m;
  final slope = denom.abs() < 1e-9 ? 0.0 : (sto - stt * so / m) / denom;
  final icpt = (so - slope * stt) / m;
  var rss = 0.0;
  var meanA = 0.0, meanB = 0.0;
  for (final i in best) {
    final e = slope * tt[i] + icpt - offArr[i];
    rss += e * e;
    meanA += innerA[i];
    meanB += innerB[i];
  }
  meanA /= m;
  meanB /= m;
  var varA = 0.0, varB = 0.0;
  for (final i in best) {
    varA += (innerA[i] - meanA) * (innerA[i] - meanA);
    varB += (innerB[i] - meanB) * (innerB[i] - meanB);
  }
  final lineRms = math.sqrt(rss / m);
  final abStd = math.sqrt(varA / m + varB / m);
  if (density < 0.55 || lineRms > 1.4 || abStd > 7.0) {
    return ProbeResult(ev, 0, massPx, null, null);
  }
  final runPx = tt[best.last] - tt[best.first];
  final ridgeX = Float64List(best.length), ridgeY = Float64List(best.length);
  for (var j = 0; j < best.length; j++) {
    final i = best[j];
    ridgeX[j] = baseX[i] + offArr[i] * nx;
    ridgeY[j] = baseY[i] + offArr[i] * ny;
  }
  return ProbeResult(ev, runPx, massPx, ridgeX, ridgeY);
}

// ---------------------------------------------------------------- contain
/// Convex hull (monotone chain) of points [(x,y)...] -> CCW polygon.
List<List<double>> _convexHull(List<List<double>> pts) {
  final p = List<List<double>>.from(pts)
    ..sort((a, b) => a[0] != b[0] ? a[0].compareTo(b[0]) : a[1].compareTo(b[1]));
  double crossZ(List<double> o, List<double> a, List<double> b) =>
      (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  final lower = <List<double>>[];
  for (final pt in p) {
    while (lower.length >= 2 &&
        crossZ(lower[lower.length - 2], lower.last, pt) <= 0) {
      lower.removeLast();
    }
    lower.add(pt);
  }
  final upper = <List<double>>[];
  for (final pt in p.reversed) {
    while (upper.length >= 2 &&
        crossZ(upper[upper.length - 2], upper.last, pt) <= 0) {
      upper.removeLast();
    }
    upper.add(pt);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

/// Signed distance of point to convex polygon: positive inside (like
/// cv2.pointPolygonTest with measureDist).
double _signedDistToPoly(List<List<double>> poly, double x, double y) {
  var minD = double.infinity;
  var inside = true;
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i], b = poly[(i + 1) % poly.length];
    final ex = b[0] - a[0], ey = b[1] - a[1];
    // CCW polygon: point is inside if left of every edge
    final crossZ = ex * (y - a[1]) - ey * (x - a[0]);
    if (crossZ < 0) inside = false;
    final len2 = ex * ex + ey * ey;
    var t = len2 < 1e-12 ? 0.0 : ((x - a[0]) * ex + (y - a[1]) * ey) / len2;
    t = t.clamp(0.0, 1.0);
    final px = a[0] + t * ex, py = a[1] + t * ey;
    final d = math.sqrt((x - px) * (x - px) + (y - py) * (y - py));
    if (d < minD) minD = d;
  }
  return inside ? minD : -minD;
}

/// Clip an infinite line (p0 + t*d) to the convex hull of the given
/// stripes' endpoints. Returns [t0, t1] or null if it misses the hull.
List<double>? clipLineToHull(
    List<Stripe> stripes, double p0x, double p0y, double dx, double dy) {
  final pts = <List<double>>[];
  for (final s in stripes) {
    pts.add([s.p1x, s.p1y]);
    pts.add([s.p2x, s.p2y]);
  }
  final hull = _convexHull(pts);
  if (hull.length < 3) return null;
  final ts = <double>[];
  for (var i = 0; i < hull.length; i++) {
    final a = hull[i], b = hull[(i + 1) % hull.length];
    final ex = b[0] - a[0], ey = b[1] - a[1];
    final den = dx * ey - dy * ex;
    if (den.abs() < 1e-12) continue;
    final t = ((a[0] - p0x) * ey - (a[1] - p0y) * ex) / den;
    final u = (dx * (a[1] - p0y) - dy * (a[0] - p0x)) / -den;
    if (u >= 0 && u <= 1) ts.add(t);
  }
  if (ts.length < 2) return null;
  ts.sort();
  return [ts.first, ts.last];
}

/// A real court has transverse paint (baseline/service line) crossing the
/// longitudinal lines INSIDE their segments at a steep angle. Junk quintets
/// (practice-net pieces + floor fragments, IMG_8441) have no such crossing
/// line. Threshold is 3 of 5: corner views (301/664/649) foreshorten the
/// far end, so the baseline crosses at most 3 detected segments at >=18
/// deg. No same-color condition: paint blends per surface (texflip/02 red
/// surround, texflip/06 blue court), so a baseline's measured color can sit
/// far from the sidelines' median.
bool hasTransversal(List<Stripe> combo, List<Stripe> all) {
  final comboSet = combo.toSet();
  for (final t in all) {
    if (comboSet.contains(t) || t.length < 100) continue;
    var crossed = 0;
    for (final s in combo) {
      final dot = (t.dx * s.dx + t.dy * s.dy).abs().clamp(0.0, 1.0);
      if (math.acos(dot) * 180.0 / math.pi < 18) continue;
      // intersection of the two infinite lines
      final den = t.dx * s.dy - t.dy * s.dx;
      if (den.abs() < 1e-9) continue;
      final rx = s.p1x - t.p1x, ry = s.p1y - t.p1y;
      final u = (rx * t.dy - ry * t.dx) / den; // param along s from p1
      if (u >= -0.2 * s.length && u <= 1.2 * s.length) crossed++;
    }
    if (crossed >= 3) return true;
  }
  return false;
}

/// Parallel ground lines meet only at the VP — beyond their visible extents.
/// If any pair of the chosen five crosses through a segment's INTERIOR, the
/// pair cannot be parallel in the world (Majid's rule; 8441 t0.8s: practice-
/// net pole + wall lines crossing mid-frame won the 800px retry). Pairs
/// within 6 deg are exempt: noise places a compressed far pair's crossing
/// anywhere, including inside a segment.
bool linesCrossInterior(List<Stripe> lines) {
  for (var i = 0; i < lines.length; i++) {
    for (var j = i + 1; j < lines.length; j++) {
      final a = lines[i], b = lines[j];
      final dot = (a.dx * b.dx + a.dy * b.dy).abs().clamp(0.0, 1.0);
      if (math.acos(dot) * 180.0 / math.pi < 6.0) continue;
      final den = a.dx * b.dy - a.dy * b.dx;
      if (den.abs() < 1e-9) continue;
      final rx = b.p1x - a.p1x, ry = b.p1y - a.p1y;
      final ta = (rx * b.dy - ry * b.dx) / den;
      final tb = (rx * a.dy - ry * a.dx) / den;
      if ((ta > 0.10 * a.length && ta < 0.90 * a.length) ||
          (tb > 0.10 * b.length && tb < 0.90 * b.length)) {
        return true;
      }
    }
  }
  return false;
}

/// Camera-height read of an adjacent pair of longitudinal lines: ground
/// lines [dxM] metres apart obey gap/drop = dxM/h at any common image row,
/// where gap is their horizontal separation at that row and drop is the
/// row's distance below the horizon (~ the horizontal through the pencil
/// VP — longitudinal ground lines vanish ON the horizon). h is the camera
/// height: the same for every pair of a real court, and 1-6 m for every
/// supported pose. Junk pairs off the ground plane read absurd heights
/// (8441 t0.2s: practice-net wall lines 17px apart at 220px drop -> 16.6m
/// "tramline"). Measured at both segments' mid-rows -> (hLo, hHi); null if
/// the construction is degenerate (infinite VP, row at/above the horizon
/// where there is no depth signal, near-horizontal cut).
(double, double)? pairImpliedCamH(
    Stripe a, Stripe b, double dxM, List<double> v,
    {double minDrop = 24}) {
  if (v[2].abs() < 1e-9) return null;
  final vy = v[1] / v[2];
  double? atRow(Stripe p, Stripe q) {
    final py = 0.5 * (p.p1y + p.p2y);
    final drop = py - vy;
    if (drop < minDrop) return null;
    if (q.dy.abs() < 1e-4) return null;
    final qx = q.p1x + q.dx * (py - q.p1y) / q.dy;
    final gap = (qx - 0.5 * (p.p1x + p.p2x)).abs();
    if (gap < 1e-6) return double.infinity;
    return dxM * drop / gap;
  }

  final h1 = atRow(a, b), h2 = atRow(b, a);
  if (h1 == null || h2 == null) {
    final h = h1 ?? h2;
    return h == null ? null : (h, h);
  }
  return h1 < h2 ? (h1, h2) : (h2, h1);
}

/// Set-level ground-plane gate (see kCamHMaxM block): every chosen line
/// must sit below the horizon by kMinHorizonDropFrac of the image width,
/// and the camera heights implied by the four adjacent pairs must be sane
/// (<= kCamHMaxM) and mutually consistent (<= kCamHRatioMax) — it is one
/// camera over one ground plane. Tau-ordering suffices: the slot-gap list
/// is symmetric under the model mirror (1.372/4.114/4.112/1.372).
bool groundPlaneOk(List<Stripe> ordered, List<double> v, int imgW) {
  if (v[2].abs() < 1e-9) return true; // no finite VP -> no horizon to test
  final vy = v[1] / v[2];
  final minDrop = kMinHorizonDropFrac * imgW;
  for (final s in ordered) {
    if (0.5 * (s.p1y + s.p2y) - vy < minDrop) return false;
  }
  var lo = double.infinity, hi = 0.0;
  for (var i = 0; i < 4; i++) {
    final dxM = kModelX[i + 1] - kModelX[i];
    final r =
        pairImpliedCamH(ordered[i], ordered[i + 1], dxM, v, minDrop: minDrop);
    if (r == null) continue;
    if (r.$1 < lo) lo = r.$1;
    if (r.$2 > hi) hi = r.$2;
  }
  if (hi > kCamHMaxM) return false;
  if (lo.isFinite && hi > lo * kCamHRatioMax) return false;
  return true;
}

/// Majid's coherence rule: a (projected) court-perpendicular connecting the
/// two OUTER lines must cut ALL five segments. Each segment is oriented
/// near->far via the VP; the outer segments are connected at corresponding
/// fractional positions (sweeping near/mid/far tolerates partial occlusion);
/// at least one connector must cross the three INNER segments within their
/// extents. Scattered quintets (pieces at unrelated depths — badminton bits,
/// net-band fragments) admit no such common crossing.
bool commonCrossing(List<Stripe> ordered, List<double> v) {
  List<List<double>> ends(Stripe s) {
    if (v[2].abs() > 1e-9) {
      final vx = v[0] / v[2], vy = v[1] / v[2];
      final d1 = math.sqrt((s.p1x - vx) * (s.p1x - vx) + (s.p1y - vy) * (s.p1y - vy));
      final d2 = math.sqrt((s.p2x - vx) * (s.p2x - vx) + (s.p2y - vy) * (s.p2y - vy));
      return d1 >= d2
          ? [[s.p1x, s.p1y], [s.p2x, s.p2y]]
          : [[s.p2x, s.p2y], [s.p1x, s.p1y]];
    }
    final un = math.sqrt(v[0] * v[0] + v[1] * v[1]);
    final ux = v[0] / un, uy = v[1] / un;
    final t1 = s.p1x * ux + s.p1y * uy, t2 = s.p2x * ux + s.p2y * uy;
    return t1 <= t2
        ? [[s.p1x, s.p1y], [s.p2x, s.p2y]]
        : [[s.p2x, s.p2y], [s.p1x, s.p1y]];
  }

  final e0 = ends(ordered.first), e4 = ends(ordered.last);
  for (final f in const [0.0, 0.25, 0.5, 0.75, 1.0]) {
    final ax = e0[0][0] + (e0[1][0] - e0[0][0]) * f;
    final ay = e0[0][1] + (e0[1][1] - e0[0][1]) * f;
    final bx = e4[0][0] + (e4[1][0] - e4[0][0]) * f;
    final by = e4[0][1] + (e4[1][1] - e4[0][1]) * f;
    final tdx = bx - ax, tdy = by - ay;
    var all = true;
    for (var i = 1; i <= 3; i++) {
      final s = ordered[i];
      final den = tdx * s.dy - tdy * s.dx;
      if (den.abs() < 1e-9) {
        all = false;
        break;
      }
      final rx = s.p1x - ax, ry = s.p1y - ay;
      final u = (rx * tdy - ry * tdx) / den; // param along s from p1
      // true courts may have staggered PARTIAL detections (a near-half
      // segment next to a far-half fragment): allow half-a-length slack;
      // scattered junk misses by multiples of a length
      if (u < -0.35 * s.length || u > 1.35 * s.length) {
        all = false;
        break;
      }
    }
    if (all) return true;
  }
  return false;
}

/// Count same-color stripes crossing the quintet transversally (>=3 of the
/// 5 lines, within extents, at a steep angle). A real tennis court has at
/// most ~5-6 paint transversals (baselines, service lines, net band); a
/// quintet assembled from SEVERAL adjacent badminton courts is crossed by
/// dozens of same-color lines.
int countTransversals(List<Stripe> combo, List<Stripe> all,
    double comboA, double comboB) {
  final comboSet = combo.toSet();
  var count = 0;
  for (final t in all) {
    if (comboSet.contains(t) || t.length < 80) continue;
    final da = t.labA - comboA, db = t.labB - comboB;
    if (math.sqrt(da * da + db * db) > kPenAbTol) continue;
    var crossed = 0;
    for (final s in combo) {
      final dot = (t.dx * s.dx + t.dy * s.dy).abs().clamp(0.0, 1.0);
      if (math.acos(dot) * 180.0 / math.pi < 18) continue;
      final den = t.dx * s.dy - t.dy * s.dx;
      if (den.abs() < 1e-9) continue;
      final rx = s.p1x - t.p1x, ry = s.p1y - t.p1y;
      final u = (rx * t.dy - ry * t.dx) / den;
      if (u >= -0.2 * s.length && u <= 1.2 * s.length) crossed++;
    }
    if (crossed >= 3) count++;
  }
  return count;
}

/// Centre segment must lie inside the hull of the four sideline segments.
double containmentCheck(List<Stripe> ordered) {
  final pts = <List<double>>[];
  for (final s in [ordered[0], ordered[1], ordered[3], ordered[4]]) {
    pts.add([s.p1x, s.p1y]);
    pts.add([s.p2x, s.p2y]);
  }
  final hull = _convexHull(pts);
  if (hull.length < 3) return 0;
  final cs = ordered[2];
  var viol = 0.0;
  for (final p in [
    [cs.p1x, cs.p1y],
    [cs.p2x, cs.p2y]
  ]) {
    final d = _signedDistToPoly(hull, p[0], p[1]);
    if (d < 0) viol += -d;
  }
  return viol;
}

// ---------------------------------------------------------------- matching
class CourtCandidate {
  final int pencil;
  final List<Stripe> lines; // 5, tau-ordered; predicted has id -1
  final double rms, maxRes, viol, unexp, score, spanPx, totLen;
  final int? predRole; // slot index of the predicted line, if any
  final double? ev, runPx;
  CourtCandidate(this.pencil, this.lines, this.rms, this.maxRes, this.viol,
      this.unexp, this.score, this.spanPx, this.totLen, this.predRole, this.ev,
      this.runPx);
}

Iterable<List<int>> _combinations(int n, int k) sync* {
  if (k > n) return;
  final idx = List<int>.generate(k, (i) => i);
  while (true) {
    yield List<int>.from(idx);
    var i = k - 1;
    while (i >= 0 && idx[i] == n - k + i) {
      i--;
    }
    if (i < 0) return;
    idx[i]++;
    for (var j = i + 1; j < k; j++) {
      idx[j] = idx[j - 1] + 1;
    }
  }
}

List<CourtCandidate> matchCourt(
    List<Pencil> pencils, LabImage lab, int imgW, int imgH,
    [List<Stripe> allStripes = const []]) {
  final results = <CourtCandidate>[];
  for (var pi = 0; pi < pencils.length; pi++) {
    final v = pencils[pi].v;
    final group = pencils[pi].members;
    if (group.length < 5) continue;
    final pa = pencilAngles(v, group);
    final order = List<int>.generate(group.length, (i) => i)
      ..sort((a, b) => pa.theta[a].compareTo(pa.theta[b]));
    final glines = [for (final i in order) group[i]];
    final gth = Float64List.fromList([for (final i in order) pa.theta[i]]);
    final glev = Float64List.fromList([for (final i in order) pa.lever[i]]);
    final n = glines.length;
    // BLUE paint never shares a court with WARM-WHITE paint, no matter how
    // close in plain ab distance (IMG_8441: blue b≈-10..-18 set with
    // warm-white b≈+7..+12 at pairwise d≈21, inside kSetAbTol). Blue paint =
    // cyan-blue (b<-8 with a<4) or saturated violet-blue (b<-15); a
    // purple-BLEND white (a≈+15, b≈-10, posterImage-567's contaminated
    // singles) is NOT blue and may still set with its warm siblings.
    bool isBlue(Stripe s) => (s.labB < -8 && s.labA < 4) || s.labB < -15;
    final abOk = List.generate(
        n,
        (i) => List.generate(n, (j) {
              final a = glines[i], b = glines[j];
              if ((isBlue(a) && b.labB > 8) || (isBlue(b) && a.labB > 8)) {
                return false;
              }
              final da = a.labA - b.labA;
              final db = a.labB - b.labB;
              final d = math.sqrt(da * da + db * db);
              if (d <= kSetAbTol) return true;
              // near-neutral (white-ish) lines scatter widely in ab under
              // mixed warm/cool lighting; saturated colors must match tight
              final ca = math.sqrt(a.labA * a.labA + a.labB * a.labB);
              final cb = math.sqrt(b.labA * b.labA + b.labB * b.labB);
              return ca <= 20 && cb <= 20 && d <= 34;
            }));

    double unexplainedPaint(Fit1D fit, Set<int> comboIds, double? ref,
        double comboA, double comboB, List<Stripe> comboLines) {
      // Paint can only contradict a court if it lies ON that court: clip the
      // penalty to the hull of the candidate's own lines. Multi-use halls
      // paint overlay grids right up to the sidelines/baselines (8441
      // t11.6s: apron lines beyond the baseline maxed the penalty and outscored
      // the true court). Aliased same-color sub-grids — the reason this
      // penalty exists — sit BETWEEN the chosen lines, so they stay inside.
      final hullPts = <List<double>>[];
      for (final s in comboLines) {
        hullPts.add([s.p1x, s.p1y]);
        hullPts.add([s.p2x, s.p2y]);
      }
      final hull = _convexHull(hullPts);
      final offSlot = <List<double>>[]; // [xk, weighted px mass]
      for (var k2 = 0; k2 < n; k2++) {
        if (comboIds.contains(k2)) continue;
        final s2 = glines[k2];
        final da = s2.labA - comboA, db = s2.labB - comboB;
        if (math.sqrt(da * da + db * db) > kPenAbTol) continue;
        if (hull.length >= 3 &&
            _signedDistToPoly(
                    hull, 0.5 * (s2.p1x + s2.p2x), 0.5 * (s2.p1y + s2.p2y)) <
                4.0) {
          // off the candidate court (or merely abutting it: apron grids are
          // painted up to the boundary and their ends touch the hull edge —
          // 8441 t11.6s #29). Real aliases have their midpoint deep inside.
          continue;
        }
        double tk;
        if (pa.finite) {
          final dth2 = gth[k2] - ref!;
          if (dth2.abs() > 85 * math.pi / 180) continue;
          tk = math.tan(dth2);
        } else {
          tk = gth[k2];
        }
        final xk = fit.invert(tk);
        if (xk == null || xk <= -0.3 || xk >= 11.27) continue;
        var dslot = double.infinity;
        for (final sx in kModelX) {
          if ((xk - sx).abs() < dslot) dslot = (xk - sx).abs();
        }
        if (dslot > kSlotTolM) {
          offSlot.add([xk, s2.length * math.min(1.0, (dslot - kSlotTolM) / 0.5)]);
        }
      }
      // Charge per distinct off-slot PAINT POSITION (xk-cluster), capped at
      // 1.0 each. The alias this penalty exists for (badminton sub-grids,
      // practice-net fans) leaves paint at SEVERAL distinct non-slot
      // positions; a multi-color court (texflip/15, WTT) legitimately has
      // ONE extra border line per colored box edge — a single position must
      // wound (score +1.0), not kill (the old per-pixel sum let one 499px
      // box border alone max the 2.5 cap).
      offSlot.sort((a, b) => a[0].compareTo(b[0]));
      var pen = 0.0;
      var i = 0;
      while (i < offSlot.length) {
        var mass = offSlot[i][1];
        var j = i + 1;
        while (j < offSlot.length && offSlot[j][0] - offSlot[j - 1][0] <= 0.35) {
          mass += offSlot[j][1];
          j++;
        }
        pen += math.min(1.0, 0.02 * mass);
        i = j;
      }
      return math.min(pen, 2.5);
    }

    // ------- 5-line subsets
    for (final combo in _combinations(n, 5)) {
      final sel = [for (final i in combo) glines[i]];
      var nShort = 0;
      for (final s in sel) {
        if (!s.isLong) nShort++;
      }
      if (nShort > 1 || (nShort == 1 && sel[2].isLong)) continue;
      var abAll = true;
      for (var i = 0; i < 5 && abAll; i++) {
        for (var j = i + 1; j < 5; j++) {
          if (!abOk[combo[i]][combo[j]]) {
            abAll = false;
            break;
          }
        }
      }
      if (!abAll) continue;
      var signOk = true;
      for (final s in sel) {
        if (s.lsign != sel[0].lsign) signOk = false;
      }
      if (!signOk) continue;
      final th5 = [for (final i in combo) gth[i]];
      var avSum5 = 0.0;
      for (final i in combo) {
        avSum5 += segAngleFromVertical(glines[i].dx, glines[i].dy);
      }
      // end-of-court camera: the court reads vertical-ish as a SET in every
      // supported pose; horizontal-ish fans are side-on courts or clutter
      if (avSum5 / 5 > kSetMeanVertDegFlat) continue;
      Float64List t5, w5;
      double? ref5;
      if (pa.finite) {
        // the court fan points DOWNWARD from a horizon VP (ground prior;
        // kills ceiling fans)
        final vpd = math.sqrt(math.pow(v[0] / v[2] - imgW / 2, 2) +
            math.pow(v[1] / v[2] - imgH / 2, 2));
        if (vpd < 3.0 * (imgW + imgH)) {
          var sinSum = 0.0;
          for (final t in th5) {
            sinSum += math.sin(t);
          }
          if (sinSum / 5 < 0.05) continue;
        }
        final lo = th5.reduce(math.min), hi = th5.reduce(math.max);
        ref5 = 0.5 * (lo + hi);
        var tooWide = false;
        for (final t in th5) {
          if ((t - ref5).abs() > 86 * math.pi / 180) tooWide = true;
        }
        if (tooWide) continue;
        t5 = Float64List.fromList([for (final t in th5) math.tan(t - ref5)]);
        w5 = Float64List.fromList([
          for (var i = 0; i < 5; i++)
            math.pow(math.cos(th5[i] - ref5), 2).toDouble() * glev[combo[i]]
        ]);
      } else {
        t5 = Float64List.fromList(th5);
        w5 = Float64List.fromList([for (final i in combo) glev[i]]);
      }
      var spanPx = 0.0, minGap = double.infinity;
      for (var i = 0; i + 1 < 5; i++) {
        final g = (t5[i + 1] - t5[i]) * 0.5 * (w5[i + 1] + w5[i]);
        spanPx += g;
        if (g < minGap) minGap = g;
      }
      if (spanPx < kMinSpanFrac5 * imgW) continue;
      if (minGap < 0.015 * spanPx) continue;
      Fit1D? best;
      var flipped = false;
      for (final mirror in const [false, true]) {
        final x = mirror ? kModelX.reversed.toList() : kModelX;
        final fit = fit1dHomography(x, t5, w5);
        if (fit == null) continue;
        if (best == null || fit.rms < best.rms) {
          best = fit;
          flipped = mirror;
        }
      }
      if (best == null) continue;
      final rms = best.rms, mx = best.maxAbs;
      if (rms > kFitRmsPx || mx > 2.5 * kFitRmsPx) continue;
      final comboA = _median([for (final s in sel) s.labA]);
      final comboB = _median([for (final s in sel) s.labB]);
      final unexp =
          unexplainedPaint(best, combo.toSet(), ref5, comboA, comboB, sel);
      final ordered = flipped ? sel.reversed.toList() : sel;
      if (!commonCrossing(ordered, v)) continue;
      if (linesCrossInterior(ordered)) continue;
      if (!groundPlaneOk(ordered, v, imgW)) continue;
      // a real court is crossed by same-paint transverse lines (baseline /
      // service line); multi-object fans (practice nets + floor lines,
      // IMG_8441) are only crossed by other-colored clutter
      if (allStripes.isNotEmpty &&
          !hasTransversal(ordered, allStripes)) {
        continue;
      }
      final viol = containmentCheck(ordered);
      var totLen = 0.0;
      for (final s in sel) {
        totLen += s.length;
      }
      // evidence bonus is BOUNDED: an unbounded length term let frames full
      // of long overlay lines (badminton) cancel every penalty. The span term
      // prefers the BIGGER court among competing candidates (the camera is
      // focused on the whole court; half-court/sub-grid aliases span less).
      final score = rms +
          0.03 * viol +
          unexp -
          0.5 * math.min(1.0, totLen / (2.0 * imgW)) -
          0.9 * math.min(1.0, spanPx / (0.65 * imgW));
      results.add(CourtCandidate(pi, ordered, rms, mx, viol, unexp, score,
          spanPx, totLen, null, null, null));
    }

    // ------- 4+1: four detected lines + a verified predicted fifth
    final longIdx = <int>[];
    for (var i = 0; i < n; i++) {
      if (glines[i].isLong) longIdx.add(i);
    }
    for (final c4 in _combinations(longIdx.length, 4)) {
      final combo = [for (final i in c4) longIdx[i]];
      final sel = [for (final i in combo) glines[i]];
      var abAll = true;
      for (var i = 0; i < 4 && abAll; i++) {
        for (var j = i + 1; j < 4; j++) {
          if (!abOk[combo[i]][combo[j]]) {
            abAll = false;
            break;
          }
        }
      }
      if (!abAll) continue;
      var signOk = true;
      for (final s in sel) {
        if (s.lsign != sel[0].lsign) signOk = false;
      }
      if (!signOk) continue;
      final th4 = [for (final i in combo) gth[i]];
      var avSum4 = 0.0;
      for (final i in combo) {
        avSum4 += segAngleFromVertical(glines[i].dx, glines[i].dy);
      }
      Float64List t4, w4;
      double? ref;
      if (pa.finite) {
        final vpd = math.sqrt(math.pow(v[0] / v[2] - imgW / 2, 2) +
            math.pow(v[1] / v[2] - imgH / 2, 2));
        if (vpd < 3.0 * (imgW + imgH)) {
          var sinSum = 0.0;
          for (final t in th4) {
            sinSum += math.sin(t);
          }
          if (sinSum / 4 < 0.05) continue;
        }
        final lo = th4.reduce(math.min), hi = th4.reduce(math.max);
        ref = 0.5 * (lo + hi);
        var tooWide = false;
        for (final t in th4) {
          if ((t - ref).abs() > 80 * math.pi / 180) tooWide = true;
        }
        if (tooWide) continue;
        t4 = Float64List.fromList([for (final t in th4) math.tan(t - ref)]);
        w4 = Float64List.fromList([
          for (var i = 0; i < 4; i++)
            math.pow(math.cos(th4[i] - ref), 2).toDouble() * glev[combo[i]]
        ]);
      } else {
        t4 = Float64List.fromList(th4);
        w4 = Float64List.fromList([for (final i in combo) glev[i]]);
      }
      final medAb = [
        _median([for (final s in sel) s.labA]),
        _median([for (final s in sel) s.labB])
      ];
      final expSign = sel[0].lsign;
      for (var drop = 0; drop < 5; drop++) {
        final xr = <double>[];
        for (var i = 0; i < 5; i++) {
          if (i != drop) xr.add(kModelX[i]);
        }
        // mirror twins fit with IDENTICAL residuals but predict DIFFERENT
        // 5th lines -> probe both
        for (final mirror in const [false, true]) {
          final x = mirror ? xr.reversed.toList() : xr;
          final fit = fit1dHomography(x, t4, w4);
          if (fit == null) continue;
          final rms = fit.rms, mx = fit.maxAbs;
          if (rms > kFitRms4Px || mx > 2.0 * kFitRms4Px) continue;
          final tq = fit.predict(kModelX[drop]);
          if (tq == null) continue;
          // materialise the predicted image line
          double p0x, p0y, dqx, dqy, wq;
          double? tmin;
          if (pa.finite) {
            if (tq.abs() > math.tan(84 * math.pi / 180)) continue;
            final thq = ref! + math.atan(tq);
            p0x = v[0] / v[2];
            p0y = v[1] / v[2];
            dqx = math.cos(thq);
            dqy = math.sin(thq);
            final levs = [for (final i in combo) glev[i]]..sort();
            final medLev = 0.5 * (levs[1] + levs[2]);
            wq = math.pow(math.cos(math.atan(tq)), 2).toDouble() * medLev;
            tmin = 0.0;
          } else {
            final un = math.sqrt(v[0] * v[0] + v[1] * v[1]);
            dqx = v[0] / un;
            dqy = v[1] / un;
            p0x = -dqy * tq;
            p0y = dqx * tq;
            wq = 1.0;
            tmin = null;
          }
          // end-of-court camera: vertical-ish as a SET of five — judged
          // including the predicted line: the quartet alone skews flat
          // because the dropped slot is usually the near-vertical centre
          // (true quartets measure ~69-70 deg mean, the full five 57-63)
          if ((avSum4 + segAngleFromVertical(dqx, dqy)) / 5 >
              kSetMeanVertDegFlat) {
            continue;
          }
          // span / gap gates over the full 5 positions
          final tAll = [...t4, tq];
          final wAll = [...w4, wq];
          final ord5 = List<int>.generate(5, (i) => i)
            ..sort((a, b) => tAll[a].compareTo(tAll[b]));
          var spanPx = 0.0, minGap = double.infinity;
          for (var i = 0; i + 1 < 5; i++) {
            final g = (tAll[ord5[i + 1]] - tAll[ord5[i]]) *
                0.5 *
                (wAll[ord5[i + 1]] + wAll[ord5[i]]);
            spanPx += g;
            if (g < minGap) minGap = g;
          }
          if (spanPx < kMinSpanFrac * imgW || minGap < 0.015 * spanPx) {
            continue;
          }
          final probe = probeLineEvidence(
              lab, p0x, p0y, dqx, dqy, medAb[0], medAb[1], expSign,
              tmin: tmin, avoid: sel);
          final okEvidence = probe.ev >= kPredEvFrac &&
              probe.runPx >= kPredRunPx &&
              probe.ridgeX != null &&
              probe.massPx >= kPredMassPx;
          // the CENTRE line is routinely occluded (a player at the T hides
          // almost all of it in rally frames); the four sidelines pin the
          // geometry with one redundancy, so allow the centre slot with only
          // WEAK paint evidence (some stripe response along the prediction +
          // a strong quartet) at a score penalty. Other slots stay strict —
          // a no-evidence exemption was tried and false-accepted widely (the
          // centre-dropped CR pattern is just two tight pairs, common in
          // clutter). A runPx floor here was tried and REVERTED: it killed
          // 8441-t11.6's true court (overlay crossings chop the centre into
          // sub-12px runs). Instead, the evidence-free path must show sober
          // fit geometry (kWeakRatioMax — kills texflip/05's bare-court
          // mirror twin at 44x while t11.6 passes at 15.4).
          final okWeakCentre = drop == 2 &&
              probe.massPx >= 40 &&
              rms <= 0.5 &&
              fitScaleRatio(fit, [...x, kModelX[drop]], [...w4, wq]) <=
                  kWeakRatioMax;
          if (!okEvidence && !okWeakCentre) continue;
          Stripe pred;
          if (okEvidence) {
            // refit the predicted line onto the measured paint ridge
            pred = Stripe(
                probe.ridgeX!, probe.ridgeY!, 0, medAb[0], medAb[1], expSign);
            // REFIT CONSISTENCY: the evidence must support the line AT ITS
            // CLAIMED SLOT. Re-invert the ridge-refit line through the fit:
            // paint that lands at a different court-x belongs to a different
            // line (texflip/05: the "singles" prediction latched onto the
            // doubles line's own paint 12px away — ridge maps to x=0.05, not
            // 1.372; texflip/15's legit pred maps to 1.36 vs claimed 1.372).
            double thRefit;
            if (pa.finite) {
              thRefit = vpConstrainedFit(v, pred)[1];
            } else {
              final un2 = math.sqrt(v[0] * v[0] + v[1] * v[1]);
              final ux2 = v[0] / un2, uy2 = v[1] / un2;
              thRefit =
                  -uy2 * 0.5 * (pred.p1x + pred.p2x) + ux2 * 0.5 * (pred.p1y + pred.p2y);
            }
            final tqRefit =
                pa.finite ? math.tan(thRefit - ref!) : thRefit;
            final xRefit = fit.invert(tqRefit);
            if (xRefit == null || (xRefit - kModelX[drop]).abs() > 0.5) {
              continue;
            }
            // POOL-COINCIDENCE: if the ridge is collinear with a DETECTED
            // long stripe S, the candidate is a 5-set in disguise — and must
            // satisfy S's own measured angle. The 4+1 freedom otherwise
            // resurrects 5-sets the rms gate rejected (texflip/05: quartet +
            // "predicted" line on the left-doubles paint refit to rms 0.11
            // while the honest 5-point fit misses by ~7px).
            final lp = pred.homog();
            final lpn = math.sqrt(lp[0] * lp[0] + lp[1] * lp[1]);
            var coincIdx = -1;
            for (var k2 = 0; k2 < n && coincIdx < 0; k2++) {
              if (combo.contains(k2)) continue;
              final s2 = glines[k2];
              if (!s2.isLong) continue;
              final d1 =
                  (lp[0] * s2.p1x + lp[1] * s2.p1y + lp[2]).abs() / lpn;
              final d2 =
                  (lp[0] * s2.p2x + lp[1] * s2.p2y + lp[2]).abs() / lpn;
              if (d1 <= 4.0 && d2 <= 4.0) coincIdx = k2;
            }
            if (coincIdx >= 0) {
              final x5 = [...x, kModelX[drop]];
              final t5c = Float64List.fromList([...t4, gth[coincIdx]].toList());
              t5c[4] = pa.finite
                  ? math.tan(gth[coincIdx] - ref!)
                  : gth[coincIdx];
              final w5c = Float64List.fromList([
                ...w4,
                pa.finite
                    ? math.pow(math.cos(gth[coincIdx] - ref!), 2).toDouble() *
                        glev[coincIdx]
                    : glev[coincIdx]
              ]);
              final fit5 = fit1dHomography(x5, t5c, w5c);
              if (fit5 == null ||
                  fit5.rms > kCoincRms ||
                  fit5.maxAbs > 2.5 * kCoincRms) {
                continue;
              }
            }
          } else {
            final span = clipLineToHull(sel, p0x, p0y, dqx, dqy);
            if (span == null) continue;
            pred = Stripe(
                Float64List.fromList(
                    [p0x + dqx * span[0], p0x + dqx * span[1]]),
                Float64List.fromList(
                    [p0y + dqy * span[0], p0y + dqy * span[1]]),
                0, medAb[0], medAb[1], expSign);
          }
          pred.id = -1;
          var pos = 0;
          final t4s = List<double>.from(t4)..sort();
          while (pos < 4 && t4s[pos] < tq) {
            pos++;
          }
          final ordered = List<Stripe>.from(sel)..insert(pos, pred);
          if (!commonCrossing(ordered, v)) continue;
          if (linesCrossInterior(ordered)) continue;
          if (!groundPlaneOk(ordered, v, imgW)) continue;
          if (allStripes.isNotEmpty &&
              !hasTransversal(ordered, allStripes)) {
            continue;
          }
          final viol = containmentCheck(ordered);
          final unexp = unexplainedPaint(fit, combo.toSet(),
              pa.finite ? ref : null, medAb[0], medAb[1], ordered);
          var totLen = 0.0;
          for (final s in sel) {
            totLen += s.length;
          }
          final score = rms +
              0.5 +
              0.03 * viol +
              unexp -
              0.5 * math.min(1.0, totLen / (2.0 * imgW)) -
              0.9 * math.min(1.0, spanPx / (0.65 * imgW)) +
              (okEvidence ? -0.4 * probe.ev : 0.35);
          results.add(CourtCandidate(pi, ordered, rms, mx, viol, unexp, score,
              spanPx, totLen, pos, probe.ev, probe.runPx));
        }
      }
    }
  }
  results.sort((a, b) => a.score.compareTo(b.score));
  // NMS: results sharing >=3 detected lines are the same court hypothesis
  final kept = <CourtCandidate>[];
  for (final r in results) {
    final ids = {for (final s in r.lines) if (s.id >= 0) s.id};
    var dup = false;
    for (final k in kept) {
      final kids = {for (final s in k.lines) if (s.id >= 0) s.id};
      if (ids.intersection(kids).length >= 3) {
        dup = true;
        break;
      }
    }
    if (!dup) kept.add(r);
  }
  return kept;
}

// ------------------------------------------------- centreline refinement
/// Drawn lines must sit on the PAINT'S MIDDLE (Majid, 2026-06-12): near-
/// camera lines are 10-25px wide while the stripe profiles centre only
/// bands up to ~12px (kProfT=9, widest band ±5) — on wider paint the
/// support rides whichever edge fits the band grid (8547 t0.0: the red
/// overlay hugged the outer edge of the near doubles line). After a
/// candidate is ACCEPTED, re-find the centre at each sample as the midpoint
/// of the paint's LUMINANCE half-maximum crossings — local L contrast is
/// the one signal that survives every surface (a chroma-run variant was
/// tried first and died on purple courts: thin far lines blend toward the
/// surface tint until the surface itself sits inside chroma tolerance,
/// 8547's far side) — then refit each line on the recentered samples.
/// Gates and scores are NOT re-evaluated: geometry-only polish on the
/// already-chosen court.
/// One perpendicular paint measurement for the post-acceptance passes
/// (centreline refinement, color extension): scan ±[halfScan] across the
/// line at (bx,by), find the luminance peak near the centre (lsign flips
/// dark lines peak-up), demand the peak's chroma still matches the stripe's
/// paint and a minimum local contrast, and return the midpoint of the
/// sub-pixel half-maximum crossings (= the paint's optical centre) plus the
/// paint width. Null when no acceptable paint is present here. The default
/// ±16px handles paint up to ~26px wide (the longitudinal lines); BASELINES
/// run much wider near the camera and use a wider scan.
const double _kPaintStep = 0.5;

(double, double)? paintMidAt(
    LabImage lab, Stripe s, double bx, double by, Float64List scratch,
    {double halfScan = 16.0}) {
  final nSteps = (2 * halfScan / _kPaintStep).round() + 1;
  final mid = (nSteps - 1) ~/ 2;
  final nx = -s.dy, ny = s.dx;
  final sgn = s.lsign.toDouble();
  // scratch: 3 (sample) + nSteps (lum) + 2*nSteps (chroma)
  final lum = Float64List.sublistView(scratch, 3, 3 + nSteps);
  final chA = Float64List.sublistView(scratch, 3 + nSteps, 3 + 2 * nSteps);
  final chB =
      Float64List.sublistView(scratch, 3 + 2 * nSteps, 3 + 3 * nSteps);
  for (var k = 0; k < nSteps; k++) {
    final d = -halfScan + k * _kPaintStep;
    sampleLab(lab, bx + nx * d, by + ny * d, scratch, 0);
    lum[k] = sgn * scratch[0];
    chA[k] = scratch[1];
    chB[k] = scratch[2];
  }
  // paint peak near the current centreline (the line may ride its own
  // edge — that is the very bias being corrected — so search ±4px)
  var kp = mid;
  for (var k = mid - 8; k <= mid + 8; k++) {
    if (lum[k] > lum[kp]) kp = k;
  }
  // the peak must still look like this stripe's paint, not a neighbour
  final da = chA[kp] - s.labA, db = chB[kp] - s.labB;
  if (da * da + db * db > (kAbTol + 6) * (kAbTol + 6)) return null;
  // local baselines: the darkest sample on each side of the peak
  var loL = lum[kp], loR = lum[kp];
  for (var k = 0; k < kp; k++) {
    if (lum[k] < loL) loL = lum[k];
  }
  for (var k = kp + 1; k < nSteps; k++) {
    if (lum[k] < loR) loR = lum[k];
  }
  if (lum[kp] - math.max(loL, loR) < 8.0) return null; // no paint contrast
  // sub-pixel half-maximum crossings -> the paint's two edges
  double? cross(int dir, double lo) {
    final hl = 0.5 * (lum[kp] + lo);
    var prev = lum[kp];
    for (var k = kp + dir; k >= 0 && k < nSteps; k += dir) {
      if (lum[k] <= hl) {
        final f = (prev - hl) / (prev - lum[k]);
        return ((k - dir) + dir * f - mid) * _kPaintStep;
      }
      prev = lum[k];
    }
    return null; // edge beyond the scan
  }

  final eL = cross(-1, loL), eR = cross(1, loR);
  if (eL == null || eR == null) return null;
  final width = eR - eL;
  if (width < 1.0 || width > 2 * halfScan - 6) return null;
  return (0.5 * (eL + eR), width);
}

/// Scratch buffer sized for [paintMidAt] at the given scan width.
Float64List paintScratch({double halfScan = 16.0}) =>
    Float64List(3 + 3 * ((2 * halfScan / _kPaintStep).round() + 1));

void refineCourtLines(List<Stripe> lines, LabImage lab,
    {double halfScan = 16.0}) {
  final scratch = paintScratch(halfScan: halfScan);
  for (final s in lines) {
    final n = (s.length / kSampleStep).floor() + 1;
    if (n < 4) continue;
    final nx = -s.dy, ny = s.dx;
    final newX = <double>[], newY = <double>[];
    for (var i = 0; i < n; i++) {
      final bt = i * s.length / (n - 1);
      final bx = s.p1x + s.dx * bt, by = s.p1y + s.dy * bt;
      final m = paintMidAt(lab, s, bx, by, scratch, halfScan: halfScan);
      if (m == null) continue;
      final dMid = m.$1;
      if (dMid.abs() > halfScan - 3) continue;
      newX.add(bx + nx * dMid);
      newY.add(by + ny * dMid);
    }
    if (newX.length < math.max(6, n ~/ 3)) continue; // occluded/uncertain
    final oldP1x = s.p1x, oldP1y = s.p1y, oldP2x = s.p2x, oldP2y = s.p2y;
    s.sx = Float64List.fromList(newX);
    s.sy = Float64List.fromList(newY);
    s.refit();
    // keep the original visible extent: refit shrinks p1/p2 to the samples
    // that recentered, but skipped samples (occlusions, junctions) are still
    // part of the painted line — project the old endpoints onto the new line
    var t1 = (oldP1x - s.cx) * s.dx + (oldP1y - s.cy) * s.dy;
    var t2 = (oldP2x - s.cx) * s.dx + (oldP2y - s.cy) * s.dy;
    if (t1 > t2) {
      final t = t1;
      t1 = t2;
      t2 = t;
    }
    s.p1x = s.cx + s.dx * t1;
    s.p1y = s.cy + s.dy * t1;
    s.p2x = s.cx + s.dx * t2;
    s.p2y = s.cy + s.dy * t2;
    s.length = t2 - t1;
  }
}

// ------------------------------------------------- color extension
/// Stage-1.5 (Majid's spec, 2026-06-12) — ISOLATED from detection: take the
/// chosen court lines and the image, and grow each line pixel-by-pixel
/// beyond both ends for as long as the paint continues in the line's own
/// color (white, usually). The detector's extents stop where its stripe
/// validator last succeeded — near-camera paint wider than the profile
/// window, worn stretches, junction zones — but the marking should span the
/// painted line's true reach. Each 1px step re-tests paint with the same
/// luminance-half-max measurement as the refinement, requiring the paint's
/// centre within ±4px of the STRAIGHT line (the direction is never changed,
/// so extension cannot bend the marking off the refined centreline).
/// Junctions with transverse paint (baselines, service lines, net tape)
/// read as invalid for a few px and are bridged by the gap allowance; at a
/// true painted end the walk finds nothing further and rolls back to the
/// last confirmed paint sample.
void extendCourtLines(List<Stripe> lines, LabImage lab,
    {double halfScan = 16.0}) {
  const gapPx = 24.0; // bridges junction bands and small worn patches
  final scratch = paintScratch(halfScan: halfScan);
  for (final s in lines) {
    var t1 = (s.p1x - s.cx) * s.dx + (s.p1y - s.cy) * s.dy;
    var t2 = (s.p2x - s.cx) * s.dx + (s.p2y - s.cy) * s.dy;
    if (t1 > t2) {
      final t = t1;
      t1 = t2;
      t2 = t;
    }
    double extend(double t0, double dir) {
      var tGood = t0;
      var gap = 0.0;
      for (var t = t0 + dir; ; t += dir) {
        final bx = s.cx + s.dx * t, by = s.cy + s.dy * t;
        if (bx < 2 || bx > lab.width - 3 || by < 2 || by > lab.height - 3) {
          break;
        }
        final m = paintMidAt(lab, s, bx, by, scratch, halfScan: halfScan);
        if (m != null && m.$1.abs() <= 4.0) {
          tGood = t;
          gap = 0;
        } else {
          gap += 1;
          if (gap > gapPx) break;
        }
      }
      return tGood;
    }

    t1 = extend(t1, -1.0);
    t2 = extend(t2, 1.0);
    s.p1x = s.cx + s.dx * t1;
    s.p1y = s.cy + s.dy * t1;
    s.p2x = s.cx + s.dx * t2;
    s.p2y = s.cy + s.dy * t2;
    s.length = t2 - t1;
  }
}

// ------------------------------------------------- baseline detection
/// Stage 3 (Majid's spec, 2026-06-12) — ISOLATED from detection: take the
/// extended court lines and the image and find the two BASELINES. In the
/// world a baseline runs perpendicular to the tramlines, spanning the court
/// from outer tramline to outer tramline — and the color-extension pass
/// (extendCourtLines) already stops each sideline's endpoint exactly at the
/// baseline's OUTER EDGE, so the four sideline endpoints on each side are
/// collinear anchors for that side's baseline. Per side:
///   1. robust line fit through the 4 anchor endpoints (centre line is
///      excluded — it ends at the service-line T, not the baseline);
///   2. paint verification along the anchor line (stripe probe with the
///      chroma measured AT the anchor corners — baselines blend per surface
///      like all court paint), refit onto the measured ridge, then the same
///      centreline refinement + color extension as the 5 lines;
///   3. fit checks against the 5-line geometry: a baseline must cross BOTH
///      outer tramlines at their ends, must be transverse (>=15 deg from
///      every longitudinal line), and the tramlines must TERMINATE there —
///      collinear sideline paint continuing beyond the crossing means the
///      candidate is interior paint (net band, service line), not a
///      baseline;
///   4. when both sides survive, a perpendicularity plausibility check: the
///      two baselines pin the transverse vanishing point, and for world-
///      perpendicular directions the implied focal length f^2 =
///      -(v_long-c)·(v_trans-c) (principal point at centre) must be
///      positive and sane. 8366's net-tape false far-baseline implies
///      f^2 < 0 and dies here; near-parallel baseline pairs (deep end
///      views) leave f indeterminate and are accepted.
List<Stripe> detectBaselines(List<Stripe> lines, LabImage lab) {
  if (lines.length != 5) return const [];
  // longitudinal VP from the 5 lines (smallest eigenvector refit)
  final m = List<double>.filled(9, 0);
  for (final s in lines) {
    final l = s.homog();
    final nrm = math.sqrt(l[0] * l[0] + l[1] * l[1]);
    final ln = [l[0] / nrm, l[1] / nrm, l[2] / nrm];
    for (var r = 0; r < 3; r++) {
      for (var c = 0; c < 3; c++) {
        m[r * 3 + c] += ln[r] * ln[c];
      }
    }
  }
  final v = smallestEig3(m);

  // endpoint of [s] on the chosen side: near (farther from the VP) or far
  List<double> endOf(Stripe s, bool near) {
    double d1, d2;
    if (v[2].abs() > 1e-9) {
      final vx = v[0] / v[2], vy = v[1] / v[2];
      d1 = math.sqrt(math.pow(s.p1x - vx, 2) + math.pow(s.p1y - vy, 2))
          .toDouble();
      d2 = math.sqrt(math.pow(s.p2x - vx, 2) + math.pow(s.p2y - vy, 2))
          .toDouble();
    } else {
      final un = math.sqrt(v[0] * v[0] + v[1] * v[1]);
      d1 = (s.p1x * v[0] + s.p1y * v[1]) / un;
      d2 = (s.p2x * v[0] + s.p2y * v[1]) / un;
    }
    final p1Near = d1 >= d2;
    return (near == p1Near) ? [s.p1x, s.p1y] : [s.p2x, s.p2y];
  }

  final sidelines = [lines[0], lines[1], lines[3], lines[4]];
  final scratch = paintScratch();
  final smp = Float64List(3);

  // an endpoint ON the image border means the painted corner is OUT OF
  // FRAME — the color extension ran to the edge, not to the baseline. Such
  // endpoints are not baseline anchors; the tramline is instead treated as
  // virtually extended beyond the frame (Majid's spec, 2026-06-12).
  bool atBorder(double x, double y) =>
      x < 6 || x > lab.width - 7 || y < 6 || y > lab.height - 7;

  // does collinear sideline paint continue beyond point (px,py) walking
  // OUTWARD along [s]? A true baseline terminates the sidelines.
  bool paintContinuesBeyond(Stripe s, double px, double py, bool near) {
    final inward = endOf(s, !near);
    var ox = px - inward[0], oy = py - inward[1];
    final on = math.sqrt(ox * ox + oy * oy);
    if (on < 1e-9) return false;
    ox /= on;
    oy /= on;
    var hits = 0;
    for (var t = 8.0; t <= 120.0; t += 4.0) {
      final bx = px + ox * t, by = py + oy * t;
      if (bx < 2 || bx > lab.width - 3 || by < 2 || by > lab.height - 3) {
        break;
      }
      final pm = paintMidAt(lab, s, bx, by, scratch);
      if (pm != null && pm.$1.abs() <= 4.0) {
        if (++hits >= 6) return true; // >=24px CONTIGUOUS continuing paint
      } else {
        hits = 0; // isolated apron/overlay crossings don't count
      }
    }
    return false;
  }

  final out = <Stripe>[];
  for (final near in const [true, false]) {
    // anchors: only endpoints whose painted corner is IN frame
    final anchors = [
      for (final s in sidelines)
        if (!atBorder(endOf(s, near)[0], endOf(s, near)[1])) endOf(s, near)
    ];
    if (anchors.length < 2) continue;

    // expected baseline chroma: measured just inside each in-frame corner.
    // Baseline paint blends per surface like all court paint, so corner
    // samples must NOT be filtered against the sidelines' color (that
    // variant lost texflip/01) — but a sample can land on bare court when
    // the extension over/under-shot a few px. With >=3 samples the median
    // absorbs one such outlier; with exactly 2 disagreeing samples, prefer
    // the one closer to the sidelines' paint as a tie-break.
    final slA = _median([for (final s in sidelines) s.labA]);
    final slB = _median([for (final s in sidelines) s.labB]);
    final aS = <double>[], bS = <double>[];
    for (final s in sidelines) {
      final e = endOf(s, near);
      if (atBorder(e[0], e[1])) continue;
      final inw = endOf(s, !near);
      var ix = inw[0] - e[0], iy = inw[1] - e[1];
      final inorm = math.sqrt(ix * ix + iy * iy);
      if (inorm < 1e-9) continue;
      sampleLab(lab, e[0] + ix / inorm * 3, e[1] + iy / inorm * 3, smp, 0);
      aS.add(smp[1]);
      bS.add(smp[2]);
    }
    // probe color candidates: the corner measurement AND the sidelines'
    // median — marginal frames flip on a single global guess (texflip/01
    // needs corner color, 8441 t6.8 the sideline one), so every hypothesis
    // is probed with both and the one finding more paint wins.
    final expSign = lines[0].lsign;
    final colorCands = <List<double>>[
      if (aS.isNotEmpty) [_median(aS), _median(bS)],
      [slA, slB],
    ];
    if (colorCands.length == 2) {
      final da = colorCands[0][0] - slA, db = colorCands[0][1] - slB;
      if (da * da + db * db < 16.0) colorCands.removeLast(); // same color
    }

    // ---- hypothesis lines: the trimmed fit over all anchors (when they
    // agree) plus every anchor PAIR — sidelines stop at different obstacles
    // (net band, players, frame border), so on the far side often only two
    // endpoints actually sit on the baseline.
    final hyps = <List<double>>[]; // cx, cy, dx, dy
    var pts = List<List<double>>.from(anchors);
    for (var attempt = 0; attempt < 2; attempt++) {
      final xs = Float64List.fromList([for (final p in pts) p[0]]);
      final ys = Float64List.fromList([for (final p in pts) p[1]]);
      final f = tlsFit(xs, ys);
      var worst = -1;
      var worstOff = 0.0;
      for (var i = 0; i < pts.length; i++) {
        final off =
            (-(pts[i][0] - f[0]) * f[3] + (pts[i][1] - f[1]) * f[2]).abs();
        if (off > worstOff) {
          worstOff = off;
          worst = i;
        }
      }
      if (worstOff <= 6.0) {
        hyps.add(f);
        break;
      }
      if (pts.length <= 3) break;
      pts = [for (var i = 0; i < pts.length; i++) if (i != worst) pts[i]];
    }
    for (var i = 0; i < anchors.length; i++) {
      for (var j = i + 1; j < anchors.length; j++) {
        final ax = anchors[i][0], ay = anchors[i][1];
        var dx = anchors[j][0] - ax, dy = anchors[j][1] - ay;
        final dn = math.sqrt(dx * dx + dy * dy);
        if (dn < 40) continue; // too close to define a direction
        dx /= dn;
        dy /= dn;
        hyps.add([0.5 * (ax + anchors[j][0]), 0.5 * (ay + anchors[j][1]), dx, dy]);
      }
    }

    Stripe? bestB;
    var bestMass = 0.0;
    for (final hyp in hyps) {
      // paint ridge along the hypothesis: best color candidate wins
      ProbeResult? probe;
      var expA = 0.0, expB = 0.0;
      for (final cc in colorCands) {
        final p = probeLineEvidence(
            lab, hyp[0], hyp[1], hyp[2], hyp[3], cc[0], cc[1], expSign);
        if (probe == null || p.massPx > probe.massPx) {
          probe = p;
          expA = cc[0];
          expB = cc[1];
        }
      }
      if (probe == null || probe.ridgeX == null || probe.runPx < 40) continue;
      if (probe.massPx <= bestMass) continue;
      final b = Stripe(probe.ridgeX!, probe.ridgeY!, 0, expA, expB, expSign);
      // standard-width refine + extend: wide (28px) variants of either were
      // tried and destabilized proven baselines (301/915/texflip-07 — wide
      // scans pull in adjacent structure); the corner JOIN below covers the
      // thick near stretch the extension cannot traverse, and the straight
      // refit through the measurable sections is the thick paint's
      // centreline too (the paint is straight).
      refineCourtLines([b], lab);
      extendCourtLines([b], lab);

      // ---- fit checks against the 5-line geometry. NOTE: there is
      // deliberately NO image-space angle gate vs the longitudinal lines —
      // in corner/walking poses the off-side sidelines run nearly
      // horizontal and sit <7 deg from the baseline in the IMAGE (8441
      // t5.0 lost a 1182px-evidence baseline to a 15-deg gate); the anchor
      // construction, paint probe and per-tramline crossing semantics
      // below carry the discrimination.
      var crossesBoth = true;
      final crossTs = <double>[]; // tB of each outer-tramline crossing
      for (final s in [lines[0], lines[4]]) {
        final den = b.dx * s.dy - b.dy * s.dx;
        if (den.abs() < 1e-9) {
          crossesBoth = false;
          break;
        }
        final rx = s.p1x - b.p1x, ry = s.p1y - b.p1y;
        final tT = (rx * b.dy - ry * b.dx) / den; // param along the tramline
        final tB = (rx * s.dy - ry * s.dx) / den; // param along the baseline
        crossTs.add(tB);
        final e = endOf(s, near);
        final eT = (e[0] - s.p1x) * s.dx + (e[1] - s.p1y) * s.dy;
        if (!atBorder(e[0], e[1])) {
          // corner in frame: a baseline TERMINATES the tramline — the
          // crossing must sit at this side's END. Tolerance is ASYMMETRIC
          // (Majid's closeby radius): generous BEYOND the endpoint, where
          // worn/faint paint makes the color extension stop short of the
          // true corner and the tramline is virtually extended to meet the
          // baseline; strict INSIDE the extent, where the interior aliases
          // (net band, service lines) cross and must die.
          final eOther = endOf(s, !near);
          final eOtherT =
              (eOther[0] - s.p1x) * s.dx + (eOther[1] - s.p1y) * s.dy;
          final outward = eT >= eOtherT ? 1.0 : -1.0;
          final beyond = (tT - eT) * outward; // px past the detected end
          // outward reach up to 1.2x the visible length: in NET-SIDE views
          // the half-court sidelines stop at the net, a full half-court
          // (~1.0x length) short of the far baseline (texflip/06); the
          // strict INSIDE bound keeps interior aliases dead
          if (beyond > math.max(60.0, 1.2 * s.length) ||
              beyond < -math.max(30.0, 0.15 * s.length)) {
            crossesBoth = false;
            break;
          }
          // the baseline's own paint detection may fall short of the
          // corner by over half its span (texflip/14: a player standing ON
          // the baseline occluded its whole left half, the crossing sat at
          // -1.0x length) — the JOIN below closes the gap and the tight
          // tramline-side proximity gate above already pins the crossing
          // to the true corner, so this extent gate only rejects far-flung
          // intersections
          if (tB < -1.5 * b.length || tB > 2.5 * b.length) {
            crossesBoth = false;
            break;
          }
          // collinear sideline paint must not continue beyond the crossing
          if (paintContinuesBeyond(
              s, s.p1x + s.dx * tT, s.p1y + s.dy * tT, near)) {
            crossesBoth = false;
            break;
          }
        } else {
          // corner OUT OF FRAME (or the extension chained onto the
          // neighbouring court's collinear line and ran to the border —
          // 8547, courts side by side): the tramline is virtually extended
          // and the termination semantics don't apply. The hypothesis is
          // already pinned by the IN-frame corner anchors, so only demand
          // the crossing exists within a sane reach of the visible line —
          // beyond the border end for true cut corners, or back inside the
          // visible extent for chained ones.
          final eOther = endOf(s, !near);
          final eOtherT =
              (eOther[0] - s.p1x) * s.dx + (eOther[1] - s.p1y) * s.dy;
          final outward = eT >= eOtherT ? 1.0 : -1.0;
          final beyond = (tT - eT) * outward; // px past the border end
          if (beyond > 2.0 * s.length || beyond < -0.9 * s.length) {
            crossesBoth = false;
            break;
          }
          // the baseline may equally be border-clipped before this virtual
          // corner: allow the crossing beyond its extent within reason
          if (tB < -1.5 * b.length || tB > 2.5 * b.length) {
            crossesBoth = false;
            break;
          }
        }
      }
      if (!crossesBoth) continue;
      // join the baseline to the tramline crossings (Majid's spec): where
      // its paint detection fell short of a corner — worn paint, the corner
      // out of frame — the drawn baseline still meets the (virtually
      // extended) tramlines exactly
      if (crossTs.length == 2) {
        final tLo = math.min(0.0, math.min(crossTs[0], crossTs[1]));
        final tHi = math.max(b.length, math.max(crossTs[0], crossTs[1]));
        if (tLo < 0 || tHi > b.length) {
          final p1x = b.p1x + b.dx * tLo, p1y = b.p1y + b.dy * tLo;
          final p2x = b.p1x + b.dx * tHi, p2y = b.p1y + b.dy * tHi;
          b.p1x = p1x;
          b.p1y = p1y;
          b.p2x = p2x;
          b.p2y = p2y;
          b.length = tHi - tLo;
        }
      }
      bestB = b;
      bestMass = probe.massPx;
    }
    if (bestB != null) out.add(bestB);
  }

  // ---- 4. both sides found: cross-checks on the PAIR
  if (out.length == 2 && v[2].abs() > 1e-9) {
    // (a) perpendicularity plausibility via the implied focal length
    var pairOk = true;
    final vt = _cross(out[0].homog(), out[1].homog());
    if (vt[2].abs() > 1e-9) {
      final cxI = lab.width / 2.0, cyI = lab.height / 2.0;
      final v1x = v[0] / v[2] - cxI, v1y = v[1] / v[2] - cyI;
      final v2x = vt[0] / vt[2] - cxI, v2y = vt[1] / vt[2] - cyI;
      final v2n = math.sqrt(v2x * v2x + v2y * v2y);
      if (v2n < 20.0 * lab.width) {
        // transverse VP near enough that f is determined
        final f2 = -(v1x * v2x + v1y * v2y);
        pairOk = f2 > 0 &&
            math.sqrt(f2) > 0.3 * lab.width &&
            math.sqrt(f2) < 5.0 * lab.width;
      }
    }
    // (b) court-model consistency: near baseline (y=0), far candidate
    // (y=23.77) and the longitudinal VP (y=inf) pin the 1D projectivity
    // along the court — so each centre-service-line endpoint can be
    // INVERTED to its implied court-y, which must land on a service line
    // (y=5.485 / 18.285, the centre line's painted ends; +-0.8m for the
    // T-junction overshoot of the color extension). Interior transverse
    // paint claimed as the far baseline (net tape at 11.885, far service
    // line at 18.285 — 8366 produced the latter, fused with the net band)
    // warps the map and the endpoints invert off the service lines (4.3m /
    // 26.4m there). Model-space tolerance, not pixels: the far field is
    // compressed. One endpoint match suffices — the other may be player-
    // occluded or extension-chained onto a baseline.
    if (pairOk) {
      final c = lines[2];
      double tAlong(double x, double y) =>
          (x - c.p1x) * c.dx + (y - c.p1y) * c.dy;
      double? crossT(Stripe b) {
        final den = b.dx * c.dy - b.dy * c.dx;
        if (den.abs() < 1e-9) return null;
        final rx = c.p1x - b.p1x, ry = c.p1y - b.p1y;
        return (rx * b.dy - ry * b.dx) / den;
      }

      final t0 = crossT(out[0]), t1 = crossT(out[1]);
      if (t0 != null && t1 != null) {
        final tvp = tAlong(v[0] / v[2], v[1] / v[2]);
        final gamma = (t0 - t1) / (23.77 * (t1 - tvp));
        double? invertY(double t) {
          final den = gamma * (t - tvp);
          if (den.abs() < 1e-12) return null;
          return (t0 - t) / den;
        }

        // orient: which centre endpoint belongs to which baseline side; a
        // border-clipped centre endpoint is unmeasurable (its painted end
        // is out of frame) and cannot vote either way
        final e1 = tAlong(c.p1x, c.p1y), e2 = tAlong(c.p2x, c.p2y);
        final nearIs1 = (e1 - t0).abs() < (e2 - t0).abs();
        final eNear = nearIs1 ? e1 : e2;
        final eFar = nearIs1 ? e2 : e1;
        final nearMeas = !atBorder(nearIs1 ? c.p1x : c.p2x, nearIs1 ? c.p1y : c.p2y);
        final farMeas = !atBorder(nearIs1 ? c.p2x : c.p1x, nearIs1 ? c.p2y : c.p1y);
        final yNear = invertY(eNear), yFar = invertY(eFar);
        final nearOk =
            nearMeas && yNear != null && (yNear - 5.485).abs() <= 0.8;
        final farOk = farMeas && yFar != null && (yFar - 18.285).abs() <= 0.8;
        if ((nearMeas || farMeas) && !nearOk && !farOk) pairOk = false;
      }
    }
    if (!pairOk) out.removeLast(); // keep the near side, drop the far
  }
  return out;
}

// ------------------------------------------------- service line detection
/// Stage 4 (Majid's spec, 2026-06-12) — ISOLATED: find the NEAR (camera-
/// side) service line, the easiest transverse anchor after the baseline —
/// bold paint close to the camera — and the second anchor that pins the
/// court's depth projectivity (with it + the near baseline + the VP, the
/// net ground line, far service line and far baseline all follow by
/// cross-ratio).
///
/// Anchoring: the centre service line's near END is the T junction sitting
/// ON the near service line. With both baselines detected the pivot comes
/// from the model projection of y=5.485 instead (immune to a worn/occluded
/// centre end), and the result is metrically verified. Hypotheses sweep
/// the direction through the pivot around the reference baseline's
/// direction; the paint probe picks the strongest and the ridge refit
/// snaps it. Semantics gates: a service line must cross BOTH singles
/// sidelines INSIDE their extents, well clear of the baseline crossing,
/// and its paint must TERMINATE at those crossings — the net tape
/// continues past the singles lines toward the posts and the baseline
/// continues to the doubles corners, so both aliases die there.
List<Stripe> detectServiceLines(
    List<Stripe> lines, List<Stripe> baselines, LabImage lab) {
  if (lines.length != 5 || baselines.isEmpty) return const [];
  final c = lines[2];
  // longitudinal VP
  final m = List<double>.filled(9, 0);
  for (final s in lines) {
    final l = s.homog();
    final nrm = math.sqrt(l[0] * l[0] + l[1] * l[1]);
    final ln = [l[0] / nrm, l[1] / nrm, l[2] / nrm];
    for (var r = 0; r < 3; r++) {
      for (var c2 = 0; c2 < 3; c2++) {
        m[r * 3 + c2] += ln[r] * ln[c2];
      }
    }
  }
  final v = smallestEig3(m);
  if (v[2].abs() < 1e-9) return const [];
  double tAlong(double x, double y) =>
      (x - c.p1x) * c.dx + (y - c.p1y) * c.dy;
  double? crossT(Stripe b) {
    final den = b.dx * c.dy - b.dy * c.dx;
    if (den.abs() < 1e-9) return null;
    final rx = c.p1x - b.p1x, ry = c.p1y - b.p1y;
    return (rx * b.dy - ry * b.dx) / den;
  }

  final tvp = tAlong(v[0] / v[2], v[1] / v[2]);
  // classify baselines: NEAR = crossing farthest from the VP along centre
  Stripe? bNear, bFar;
  double tNearB = 0, tFarB = 0;
  for (final b in baselines) {
    final t = crossT(b);
    if (t == null) continue;
    if (bNear == null || (t - tvp).abs() > (tNearB - tvp).abs()) {
      if (bNear != null) {
        bFar = bNear;
        tFarB = tNearB;
      }
      bNear = b;
      tNearB = t;
    } else {
      bFar = b;
      tFarB = t;
    }
  }
  if (bNear == null) return const [];

  bool atBorder(double x, double y) =>
      x < 6 || x > lab.width - 7 || y < 6 || y > lab.height - 7;

  // candidate pivots on the centre line: the model projection when both
  // baselines pin the depth map; otherwise the centre's endpoints — the
  // far-from-VP end first (the near T), then the VP-side end: net-side
  // views expose only the FAR half of the centre line, whose VP-side end
  // is the far T (posterImage-928).
  double gamma = 0;
  var haveMap = false;
  final pivots = <double>[];
  if (bFar != null) {
    gamma = (tNearB - tFarB) / (23.77 * (tFarB - tvp));
    haveMap = true;
    pivots.add((tvp * gamma * 5.485 + tNearB) / (gamma * 5.485 + 1.0));
  } else {
    final e1 = tAlong(c.p1x, c.p1y), e2 = tAlong(c.p2x, c.p2y);
    final isE1 = (e1 - tvp).abs() > (e2 - tvp).abs();
    for (final nearEndFirst in const [true, false]) {
      final useE1 = nearEndFirst == isE1;
      var tPivot = useE1 ? e1 : e2;
      final ex = useE1 ? c.p1x : c.p2x, ey = useE1 ? c.p1y : c.p2y;
      if (atBorder(ex, ey)) continue; // painted end out of frame: no anchor
      // CHAINED-CENTRE GUARD (8440): the color extension can bridge from
      // the T through the collinear CENTRE MARK on the baseline, putting
      // the detected endpoint ON the baseline — where every sweep
      // hypothesis re-finds the baseline and dies. Walk from the baseline
      // crossing toward the VP; the centre's true T is the first paint
      // after the first real gap (T-to-mark is bare court).
      final tBase = crossT(bNear);
      if (tBase != null && (tPivot - tBase).abs() < 30) {
        final scr = paintScratch();
        final dir = (tvp - tBase).sign;
        var gapRun = 0.0;
        var sawGap = false;
        double? newPivot;
        for (var d = 6.0; d <= (tvp - tBase).abs() - 20; d += 3.0) {
          final t = tBase + dir * d;
          final bx = c.p1x + c.dx * t, by = c.p1y + c.dy * t;
          if (bx < 2 || bx > lab.width - 3 || by < 2 || by > lab.height - 3) {
            break;
          }
          final pm = paintMidAt(lab, c, bx, by, scr);
          final hit = pm != null && pm.$1.abs() <= 4.0;
          if (hit) {
            if (sawGap) {
              newPivot = t;
              break;
            }
            gapRun = 0;
          } else {
            gapRun += 3;
            if (gapRun >= 30) sawGap = true;
          }
        }
        if (newPivot == null) continue; // no T past the mark: no anchor
        tPivot = newPivot;
      }
      pivots.add(tPivot);
    }
  }
  if (pivots.isEmpty) return const [];

  final smp = Float64List(3);
  final baseAng = math.atan2(bNear.dy, bNear.dx);
  Stripe? bestSvc;
  var bestMass = 0.0;
  for (final tPivot in pivots) {
    if (bestSvc != null) break; // first pivot that yields a line wins
    final pivotX = c.p1x + c.dx * tPivot, pivotY = c.p1y + c.dy * tPivot;

    // direction sweep around the near baseline's direction
    sampleLab(lab, pivotX, pivotY, smp, 0);
    final colorCands = <List<double>>[
      [c.labA, c.labB],
      if (math.pow(smp[1] - c.labA, 2) + math.pow(smp[2] - c.labB, 2) > 16)
        [smp[1], smp[2]],
    ];

    for (var dDeg = -10.0; dDeg <= 10.0; dDeg += 1.0) {
    final ang = baseAng + dDeg * math.pi / 180.0;
    final dx = math.cos(ang), dy = math.sin(ang);
    ProbeResult? probe;
    var expA = 0.0, expB = 0.0;
    for (final cc in colorCands) {
      final p = probeLineEvidence(
          lab, pivotX, pivotY, dx, dy, cc[0], cc[1], c.lsign);
      if (probe == null || p.massPx > probe.massPx) {
        probe = p;
        expA = cc[0];
        expB = cc[1];
      }
    }
    if (probe == null || probe.ridgeX == null || probe.runPx < 40) continue;
    if (probe.massPx <= bestMass) continue;
    final svc = Stripe(probe.ridgeX!, probe.ridgeY!, 0, expA, expB, c.lsign);
    refineCourtLines([svc], lab);
    extendCourtLines([svc], lab);

    // must still pass near the pivot (the ridge can snap onto other paint)
    final lh = svc.homog();
    final lnrm = math.sqrt(lh[0] * lh[0] + lh[1] * lh[1]);
    if ((lh[0] * pivotX + lh[1] * pivotY + lh[2]).abs() / lnrm > 10) {
      continue;
    }
    // gates vs the singles sidelines
    var ok = true;
    final crossTs = <double>[];
    for (final s in [lines[1], lines[3]]) {
      final den = svc.dx * s.dy - svc.dy * s.dx;
      if (den.abs() < 1e-9) {
        ok = false;
        break;
      }
      final rx = s.p1x - svc.p1x, ry = s.p1y - svc.p1y;
      final tT = (rx * svc.dy - ry * svc.dx) / den; // along the singles line
      final tS = (rx * s.dy - ry * s.dx) / den; // along the service line
      crossTs.add(tS);
      // interior crossing, clear of this side's baseline corner
      if (tT < -12 || tT > s.length + 12) {
        ok = false;
        break;
      }
      final eN = (bNear.dx * s.dy - bNear.dy * s.dx).abs() < 1e-9
          ? null
          : (((s.p1x - bNear.p1x) * bNear.dy -
                  (s.p1y - bNear.p1y) * bNear.dx) /
              (bNear.dx * s.dy - bNear.dy * s.dx));
      if (eN != null && (tT - eN).abs() < 25) {
        ok = false; // re-found the baseline
        break;
      }
      if (tS < -0.5 * svc.length || tS > 1.5 * svc.length) {
        ok = false;
        break;
      }
      // NOTE: no termination/alley test here — both variants tried and
      // REVERTED: "paint must stop beyond the singles" dies on aligned
      // multi-court halls (the extension chains onto the neighbouring
      // court's collinear service line, 8440), and "the doubles alley must
      // be clean" dies on multi-sport overlay halls (badminton paint in
      // the alley, 8440 again). The aliases those tests targeted are
      // already pinned: a re-found baseline by the >=25px gate above, the
      // net tape by the 10px pivot constraint (it cannot pass through the
      // T), and wrong-angle junk by the ridge-refit converging onto the
      // dominant paint through the pivot.
    }
    if (!ok || crossTs.length != 2) continue;
    // ORDERING: the service line lies strictly BETWEEN the baseline and
    // the VP along the centre line — the net tape sits on the camera side
    // of a far baseline (928's net-side view: the tape passed every other
    // gate and inverted the projection quad into a bowtie)
    final tCrossC = crossT(svc);
    final tB0 = crossT(bNear);
    if (tCrossC == null || tB0 == null) continue;
    if ((tCrossC - tB0) * (tvp - tB0) <= 0 ||
        (tCrossC - tB0).abs() >= (tvp - tB0).abs()) {
      continue;
    }
    // metric verification when the depth map exists
    if (haveMap) {
      final den = gamma * (tCrossC - tvp);
      if (den.abs() < 1e-12) continue;
      final y = (tNearB - tCrossC) / den;
      if ((y - 5.485).abs() > 0.6) continue;
    }
    // join the service line to the singles crossings
    final tLo = math.min(0.0, math.min(crossTs[0], crossTs[1]));
    final tHi = math.max(svc.length, math.max(crossTs[0], crossTs[1]));
    if (tLo < 0 || tHi > svc.length) {
      final p1x = svc.p1x + svc.dx * tLo, p1y = svc.p1y + svc.dy * tLo;
      final p2x = svc.p1x + svc.dx * tHi, p2y = svc.p1y + svc.dy * tHi;
      svc.p1x = p1x;
      svc.p1y = p1y;
      svc.p2x = p2x;
      svc.p2y = p2y;
      svc.length = tHi - tLo;
    }
    bestSvc = svc;
    bestMass = probe.massPx;
  }
  }
  return bestSvc == null ? const [] : [bestSvc];
}

// ------------------------------------------------- court-span completion
/// Stage 5 (Majid's spec, 2026-06-12) — ISOLATED: virtually extend the
/// longitudinal lines that fall short so the marking spans the ENTIRE
/// court: sidelines from the near baseline (y=0) to the far baseline
/// (y=23.77), the centre service line between the two service lines
/// (y=5.485 / 18.285). Paint detection routinely stops at the net band or
/// where the far half fades; with TWO transverse anchors (near baseline +
/// far baseline, or near baseline + the near service line) plus the
/// longitudinal VP, each line's depth projectivity is pinned and the
/// missing stretch follows by cross-ratio. Completion only ever LENGTHENS:
/// a line already reaching (or chained past) a target keeps its extent.
/// FAR-side completion requires the DETECTED far baseline (the target is
/// then its actual crossing — pure interpolation): extrapolating y=23.77
/// from the (0, 5.485) anchor pair was measured 3x off on low cameras
/// (8366: net-stopped ends inverted to 33-51m), so the service-line anchor
/// only serves the centre line's near target and the metric checks.
void completeCourtLines(List<Stripe> lines, List<Stripe> baselines,
    List<Stripe> serviceLines, int imgW, int imgH) {
  if (lines.length != 5 || baselines.isEmpty) return;
  final m = List<double>.filled(9, 0);
  for (final s in lines) {
    final l = s.homog();
    final nrm = math.sqrt(l[0] * l[0] + l[1] * l[1]);
    final ln = [l[0] / nrm, l[1] / nrm, l[2] / nrm];
    for (var r = 0; r < 3; r++) {
      for (var c2 = 0; c2 < 3; c2++) {
        m[r * 3 + c2] += ln[r] * ln[c2];
      }
    }
  }
  final v = smallestEig3(m);
  if (v[2].abs() < 1e-9) return;
  final vx = v[0] / v[2], vy = v[1] / v[2];

  // classify the near baseline along the centre line (far things sit near
  // the VP), and pick the second depth anchor
  final c = lines[2];
  double tAlongC(double x, double y) =>
      (x - c.p1x) * c.dx + (y - c.p1y) * c.dy;
  double? crossOnC(Stripe b) {
    final den = b.dx * c.dy - b.dy * c.dx;
    if (den.abs() < 1e-9) return null;
    final rx = c.p1x - b.p1x, ry = c.p1y - b.p1y;
    return (rx * b.dy - ry * b.dx) / den;
  }

  final tvpC = tAlongC(vx, vy);
  Stripe? bNear, bFar;
  var tNearC = 0.0;
  for (final b in baselines) {
    final t = crossOnC(b);
    if (t == null) continue;
    if (bNear == null || (t - tvpC).abs() > (tNearC - tvpC).abs()) {
      if (bNear != null) bFar = bNear;
      bNear = b;
      tNearC = t;
    } else {
      bFar = b;
    }
  }
  if (bNear == null) return;
  Stripe? second;
  var ySecond = 0.0;
  if (bFar != null) {
    second = bFar;
    ySecond = 23.77;
  } else if (serviceLines.isNotEmpty) {
    second = serviceLines.first;
    ySecond = 5.485;
  }

  final diag = math.sqrt((imgW * imgW + imgH * imgH).toDouble());
  for (var i = 0; i < 5; i++) {
    final s = lines[i];
    double? crossOnS(Stripe b) {
      final den = b.dx * s.dy - b.dy * s.dx;
      if (den.abs() < 1e-9) return null;
      final rx = s.p1x - b.p1x, ry = s.p1y - b.p1y;
      return (rx * b.dy - ry * b.dx) / den; // param along s from p1
    }

    final t0 = crossOnS(bNear);
    if (t0 == null) continue;
    final tvp = (vx - s.p1x) * s.dx + (vy - s.p1y) * s.dy;
    double? predict(double y) {
      if (second == null) return null;
      final ta = crossOnS(second);
      if (ta == null) return null;
      final gamma = (t0 - ta) / (ySecond * (ta - tvp));
      final den = gamma * y + 1.0;
      if (den.abs() < 1e-9) return null;
      final t = (tvp * gamma * y + t0) / den;
      // sanity: deeper targets sit closer to the VP than the near baseline
      if ((t - tvp).abs() > (t0 - tvp).abs() + 1) return null;
      return t;
    }

    // target extent in this line's own parameterization; far targets only
    // from the detected far baseline (interpolation, never extrapolation)
    final yLo = i == 2 ? 5.485 : 0.0;
    final yHi = i == 2 ? 18.285 : 23.77;
    final tLoTarget = i == 2 ? predict(yLo) : t0;
    final tHiTarget = bFar == null ? null : predict(yHi);
    var t1 = 0.0, t2 = s.length; // p1/p2 params
    var lo = math.min(t1, t2), hi = math.max(t1, t2);
    for (final target in [tLoTarget, tHiTarget]) {
      if (target == null) continue;
      if ((target - lo).abs() > 2.5 * diag || (target - hi).abs() > 2.5 * diag) {
        continue; // degenerate map: don't draw to absurd reaches
      }
      lo = math.min(lo, target);
      hi = math.max(hi, target);
    }
    if (lo < 0 || hi > s.length) {
      final p1x = s.p1x + s.dx * lo, p1y = s.p1y + s.dy * lo;
      final p2x = s.p1x + s.dx * hi, p2y = s.p1y + s.dy * hi;
      s.p1x = p1x;
      s.p1y = p1y;
      s.p2x = p2x;
      s.p2y = p2y;
      s.length = hi - lo;
    }
  }

  // EQUAL-REACH far completion when the far baseline was NOT detected
  // (Majid, 2026-06-12): the metric far target is then unknowable — a world
  // y-scaling is invisible to EVERY available constraint (pencil, near
  // baseline, even the zero-roll transverse VP; measured: a horizon-DLT
  // predicted far corners 50-900px off) — but the marking can still be
  // EQUALIZED: far-reaching sidelines stop at a common physical feature
  // (the net band, or the far baseline itself), so the chord through two
  // such far endpoints is a genuine transverse cut. Extend the sidelines
  // that fall short of it (centre excluded: its painted span ends at the
  // service line). Verified transfer accuracy of a feature chord across
  // the court: sub-px to ~13px on the both-baseline frames.
  if (bFar == null) {
    const idx = [0, 1, 3, 4];
    final fx = <double>[], fy = <double>[], ft = <double>[];
    final outw = <double>[];
    for (final i in idx) {
      final s = lines[i];
      final tvp = (vx - s.p1x) * s.dx + (vy - s.p1y) * s.dy;
      final farIsP2 = (s.length - tvp).abs() < (0 - tvp).abs();
      ft.add(farIsP2 ? s.length : 0.0);
      outw.add(farIsP2 ? 1.0 : -1.0);
      fx.add(farIsP2 ? s.p2x : s.p1x);
      fy.add(farIsP2 ? s.p2y : s.p1y);
    }
    List<double>? bestT;
    var bestScore = -1.0;
    for (var a = 0; a < 4; a++) {
      for (var b = a + 1; b < 4; b++) {
        var ddx = fx[b] - fx[a], ddy = fy[b] - fy[a];
        final dn = math.sqrt(ddx * ddx + ddy * ddy);
        if (dn < 30) continue;
        ddx /= dn;
        ddy /= dn;
        final ts = <double>[];
        var valid = true;
        var score = 0.0;
        for (var k = 0; k < 4; k++) {
          final s = lines[idx[k]];
          final den = ddx * s.dy - ddy * s.dx;
          if (den.abs() < 1e-9) {
            valid = false;
            break;
          }
          final rx = s.p1x - fx[a], ry = s.p1y - fy[a];
          final tT = (rx * ddy - ry * ddx) / den; // param along s from p1
          final beyond = (tT - ft[k]) * outw[k];
          // the cut must sit at-or-beyond every far end (it equalizes,
          // never truncates) and within a sane ABSOLUTE reach — a relative
          // cap (1.2x length) was tried and self-defeating: the shortest
          // lines need the longest extensions (301's right tramlines)
          if (beyond < -25 || beyond > 1.5 * diag) {
            valid = false;
            break;
          }
          ts.add(tT);
          score += math.max(0.0, beyond);
        }
        if (valid && score > bestScore) {
          bestScore = score;
          bestT = ts;
        }
      }
    }
    if (bestT != null) {
      for (var k = 0; k < 4; k++) {
        final s = lines[idx[k]];
        final tT = bestT[k];
        if ((tT - ft[k]) * outw[k] <= 0) continue;
        if (outw[k] > 0) {
          s.p2x = s.p1x + s.dx * tT;
          s.p2y = s.p1y + s.dy * tT;
          s.length = tT;
        } else {
          s.p1x = s.p1x + s.dx * tT;
          s.p1y = s.p1y + s.dy * tT;
          s.length = s.length - tT;
        }
      }
    }
  }

  // MUTUAL-CROSSING TRIM: world-parallel lines can only meet at the VP,
  // beyond any real extent — when two drawn segments intersect INSIDE both
  // far halves, that is color-extension CHAINING onto a neighbouring
  // court's collinear paint (8441 t8.0: the right sidelines crossed each
  // other mid-air). Trim both far ends to the crossing; only ever shortens.
  for (var i = 0; i < 5; i++) {
    for (var j = i + 1; j < 5; j++) {
      final a = lines[i], b = lines[j];
      final den = a.dx * b.dy - a.dy * b.dx;
      if (den.abs() < 1e-9) continue;
      final rx = b.p1x - a.p1x, ry = b.p1y - a.p1y;
      final ta = (rx * b.dy - ry * b.dx) / den;
      final tb = (rx * a.dy - ry * a.dx) / den;
      if (ta <= 0 || ta >= a.length || tb <= 0 || tb >= b.length) continue;
      // crossing inside both segments: identify each line's far side
      void trim(Stripe s, double t) {
        final tvpS = (vx - s.p1x) * s.dx + (vy - s.p1y) * s.dy;
        final farIsP2 = (s.length - tvpS).abs() < (0 - tvpS).abs();
        if (farIsP2 && t > 0.5 * s.length) {
          s.p2x = s.p1x + s.dx * t;
          s.p2y = s.p1y + s.dy * t;
          s.length = t;
        } else if (!farIsP2 && t < 0.5 * s.length) {
          s.p1x = s.p1x + s.dx * t;
          s.p1y = s.p1y + s.dy * t;
          s.length = s.length - t;
        }
      }

      trim(a, ta);
      trim(b, tb);
    }
  }
}

// ------------------------------------------------- full-court projection
/// Stage 6 (Majid's spec, 2026-06-12): the final marking is the PROJECTED
/// court model — all painted ITF lines mapped through the world->image
/// homography pinned by the detected anchors — instead of the raw detected
/// segments.
class CourtProjection {
  /// The 9 painted court lines ([x1,y1,x2,y2] image px): 4 sidelines,
  /// 2 baselines, 2 service lines, centre service line.
  final List<List<double>> segments;

  /// Whether the far field is pinned by DETECTED/verified paint (far
  /// baseline) rather than extrapolated from the service-line anchor.
  final bool farAnchored;
  CourtProjection(this.segments, this.farAnchored);
}

/// 3x3 homography (row-major, world->image) from 4 finite point
/// correspondences via the projective basis; null when degenerate.
List<double>? homographyFrom4(List<List<double>> w, List<List<double>> q) {
  List<double>? basis(List<List<double>> p) {
    final a = [
      p[0][0], p[1][0], p[2][0],
      p[0][1], p[1][1], p[2][1],
      p[0][2], p[1][2], p[2][2],
    ];
    final c = solve3(a, [p[3][0], p[3][1], p[3][2]]);
    if (c == null) return null;
    return [
      c[0] * p[0][0], c[1] * p[1][0], c[2] * p[2][0],
      c[0] * p[0][1], c[1] * p[1][1], c[2] * p[2][1],
      c[0] * p[0][2], c[1] * p[1][2], c[2] * p[2][2],
    ];
  }

  final mw = basis(w), mq = basis(q);
  if (mw == null || mq == null) return null;
  double det(List<double> m) =>
      m[0] * (m[4] * m[8] - m[5] * m[7]) -
      m[1] * (m[3] * m[8] - m[5] * m[6]) +
      m[2] * (m[3] * m[7] - m[4] * m[6]);
  final d = det(mw);
  if (d.abs() < 1e-15) return null;
  final inv = [
    (mw[4] * mw[8] - mw[5] * mw[7]) / d,
    -(mw[1] * mw[8] - mw[2] * mw[7]) / d,
    (mw[1] * mw[5] - mw[2] * mw[4]) / d,
    -(mw[3] * mw[8] - mw[5] * mw[6]) / d,
    (mw[0] * mw[8] - mw[2] * mw[6]) / d,
    -(mw[0] * mw[5] - mw[2] * mw[3]) / d,
    (mw[3] * mw[7] - mw[4] * mw[6]) / d,
    -(mw[0] * mw[7] - mw[1] * mw[6]) / d,
    (mw[0] * mw[4] - mw[1] * mw[3]) / d,
  ];
  final h = List<double>.filled(9, 0);
  for (var r = 0; r < 3; r++) {
    for (var c = 0; c < 3; c++) {
      for (var k = 0; k < 3; k++) {
        h[r * 3 + c] += mq[r * 3 + k] * inv[k * 3 + c];
      }
    }
  }
  return h;
}

double d2Of(Stripe s, double vx, double vy) =>
    (s.p2x - vx) * (s.p2x - vx) + (s.p2y - vy) * (s.p2y - vy);

/// Build the projection. [verifiedFar] receives a far baseline that was
/// PREDICTED from the service anchor and then confirmed on paint (so the
/// caller can publish it alongside the detected baselines).
CourtProjection? projectCourt(List<Stripe> lines, List<Stripe> baselines,
    List<Stripe> serviceLines, LabImage lab, List<Stripe> verifiedFar) {
  if (lines.length != 5 || baselines.isEmpty) return null;
  // longitudinal VP + near/far baseline classification along the centre
  final m = List<double>.filled(9, 0);
  for (final s in lines) {
    final l = s.homog();
    final nrm = math.sqrt(l[0] * l[0] + l[1] * l[1]);
    final ln = [l[0] / nrm, l[1] / nrm, l[2] / nrm];
    for (var r = 0; r < 3; r++) {
      for (var c2 = 0; c2 < 3; c2++) {
        m[r * 3 + c2] += ln[r] * ln[c2];
      }
    }
  }
  final v = smallestEig3(m);
  if (v[2].abs() < 1e-9) return null;
  final c = lines[2];
  double tAlongC(double x, double y) =>
      (x - c.p1x) * c.dx + (y - c.p1y) * c.dy;
  double? crossOnC(Stripe b) {
    final den = b.dx * c.dy - b.dy * c.dx;
    if (den.abs() < 1e-9) return null;
    final rx = c.p1x - b.p1x, ry = c.p1y - b.p1y;
    return (rx * b.dy - ry * b.dx) / den;
  }

  final tvpC = tAlongC(v[0] / v[2], v[1] / v[2]);
  Stripe? bNear, bFar;
  var tNearC = 0.0;
  for (final b in baselines) {
    final t = crossOnC(b);
    if (t == null) continue;
    if (bNear == null || (t - tvpC).abs() > (tNearC - tvpC).abs()) {
      if (bNear != null) bFar = bNear;
      bNear = b;
      tNearC = t;
    } else {
      bFar = b;
    }
  }
  if (bNear == null) return null;

  List<double>? meet(Stripe a, Stripe b) {
    final la = a.homog(), lb = b.homog();
    final p = [
      la[1] * lb[2] - la[2] * lb[1],
      la[2] * lb[0] - la[0] * lb[2],
      la[0] * lb[1] - la[1] * lb[0],
    ];
    return p[2].abs() < 1e-12 ? null : [p[0] / p[2], p[1] / p[2]];
  }

  List<double>? hFromQuad(Stripe transLo, double yLo, Stripe transHi, double yHi) {
    final p00 = meet(transLo, lines[0]), p10 = meet(transLo, lines[4]);
    final p01 = meet(transHi, lines[0]), p11 = meet(transHi, lines[4]);
    if (p00 == null || p10 == null || p01 == null || p11 == null) return null;
    return homographyFrom4(
      [
        [0, yLo, 1],
        [10.97, yLo, 1],
        [0, yHi, 1],
        [10.97, yHi, 1],
      ],
      [
        [p00[0], p00[1], 1],
        [p10[0], p10[1], 1],
        [p01[0], p01[1], 1],
        [p11[0], p11[1], 1],
      ],
    );
  }

  var far = bFar;
  // tier 2: predict the far baseline from the service anchor and VERIFY it
  // on paint — far ends often stop at the net so stage 3 had no anchors
  // there, but the prediction supplies the hypothesis directly.
  if (far == null && serviceLines.isNotEmpty) {
    final h2 = hFromQuad(bNear, 0, serviceLines.first, 5.485);
    if (h2 != null) {
      List<double> map(double x, double y) {
        final px = h2[0] * x + h2[1] * y + h2[2];
        final py = h2[3] * x + h2[4] * y + h2[5];
        final pw = h2[6] * x + h2[7] * y + h2[8];
        return [px / pw, py / pw];
      }

      final f0 = map(0, 23.77), f1 = map(10.97, 23.77);
      var ddx = f1[0] - f0[0], ddy = f1[1] - f0[1];
      final dn = math.sqrt(ddx * ddx + ddy * ddy);
      if (dn > 60) {
        ddx /= dn;
        ddy /= dn;
        final slA = _median([for (final s in lines) s.labA]);
        final slB = _median([for (final s in lines) s.labB]);
        final probe = probeLineEvidence(lab, 0.5 * (f0[0] + f1[0]),
            0.5 * (f0[1] + f1[1]), ddx, ddy, slA, slB, lines[0].lsign);
        if (probe.ridgeX != null && probe.runPx >= 0.35 * dn) {
          final b = Stripe(
              probe.ridgeX!, probe.ridgeY!, 0, slA, slB, lines[0].lsign);
          refineCourtLines([b], lab);
          extendCourtLines([b], lab);
          // sanity: transverse-ish vs the prediction and consistent with
          // the model — re-anchor the depth map with the snapped line and
          // the service crossing must invert to ~5.485
          final dirOk =
              (b.dx * ddx + b.dy * ddy).abs().clamp(0.0, 1.0) > 0.995;
          final tS = crossOnC(serviceLines.first);
          final t0 = crossOnC(bNear);
          final tF = crossOnC(b);
          var modelOk = false;
          if (dirOk && tS != null && t0 != null && tF != null) {
            final gamma = (t0 - tF) / (23.77 * (tF - tvpC));
            final den = gamma * (tS - tvpC);
            if (den.abs() > 1e-12) {
              final y = (t0 - tS) / den;
              modelOk = (y - 5.485).abs() <= 0.8;
            }
          }
          if (modelOk) {
            far = b;
            verifiedFar.add(b);
          }
        }
      }
    }
  }

  List<double>? h;
  var farAnchored = true;
  Stripe? second;
  var ySecond = 23.77;
  if (far != null) {
    h = hFromQuad(bNear, 0, far, 23.77);
    second = far;
  } else if (serviceLines.isNotEmpty) {
    h = hFromQuad(bNear, 0, serviceLines.first, 5.485);
    second = serviceLines.first;
    ySecond = 5.485;
    farAnchored = false; // far field extrapolated: approximate on low cams
  }
  if (h == null || second == null) return null;
  assert(ySecond > 0);
  // anchor sanity along BOTH outer tramlines: the second anchor must sit
  // strictly between the near baseline and the VP, well separated — a
  // mis-ordered anchor (net tape on the camera side of a far baseline,
  // 928) inverts the quad and explodes the projection into a bowtie
  for (final s in [lines[0], lines[4]]) {
    double? crossT2(Stripe b) {
      final den = b.dx * s.dy - b.dy * s.dx;
      if (den.abs() < 1e-9) return null;
      final rx = s.p1x - b.p1x, ry = s.p1y - b.p1y;
      return (rx * b.dy - ry * b.dx) / den;
    }

    final tN = crossT2(bNear), tA = crossT2(second);
    if (tN == null || tA == null) return null;
    final tvpS =
        (v[0] / v[2] - s.p1x) * s.dx + (v[1] / v[2] - s.p1y) * s.dy;
    if ((tA - tN) * (tvpS - tN) <= 0 ||
        (tA - tN).abs() < 8 ||
        (tA - tN).abs() >= (tvpS - tN).abs()) {
      return null;
    }
  }

  List<double> map(double x, double y) {
    final px = h![0] * x + h[1] * y + h[2];
    final py = h[3] * x + h[4] * y + h[5];
    final pw = h[6] * x + h[7] * y + h[8];
    return [px / pw, py / pw];
  }

  // ---- HYBRID assembly (Majid, 2026-06-12: "projected lines must sit on
  // the white paint"): a corner-quad homography propagates its anchors'
  // error into every inner line and ignores lens distortion, while the
  // DETECTED lines are already sub-pixel centred — so detected geometry is
  // used wherever it exists and H only places the lines nothing detected.
  // Those purely-projected lines get a tight paint SNAP (±6px refine onto
  // the luminance mid) where their paint is actually visible. All extents
  // are then cut from mutual intersections, closing the court exactly.
  final slA = _median([for (final s in lines) s.labA]);
  final slB = _median([for (final s in lines) s.labB]);
  final scratch = paintScratch();

  // line through two image points -> homog
  List<double> through(List<double> a, List<double> b) =>
      [a[1] - b[1], b[0] - a[0], a[0] * b[1] - a[1] * b[0]];

  // tight paint snap of a projected infinite line between two model
  // anchors; falls back to the projection where paint isn't visible
  List<double> snap(List<double> pA, List<double> pB) {
    final proj = through(pA, pB);
    var dx = pB[0] - pA[0], dy = pB[1] - pA[1];
    final dn = math.sqrt(dx * dx + dy * dy);
    if (dn < 40) return proj;
    dx /= dn;
    dy /= dn;
    final n = (dn / kSampleStep).floor() + 1;
    final probe = Stripe(Float64List.fromList([pA[0], pB[0]]),
        Float64List.fromList([pA[1], pB[1]]), 0, slA, slB, lines[0].lsign);
    final sx = <double>[], sy = <double>[];
    for (var i = 0; i < n; i++) {
      final bx = pA[0] + dx * (i * dn / (n - 1));
      final by = pA[1] + dy * (i * dn / (n - 1));
      final pm = paintMidAt(lab, probe, bx, by, scratch);
      if (pm == null || pm.$1.abs() > 6.0) continue;
      sx.add(bx + -dy * pm.$1);
      sy.add(by + dx * pm.$1);
    }
    if (sx.length < math.max(6, n ~/ 3)) return proj;
    final st = Stripe(Float64List.fromList(sx), Float64List.fromList(sy), 0,
        slA, slB, lines[0].lsign);
    return st.homog();
  }

  // the 9 final infinite lines
  final long = [for (final s in lines) s.homog()];
  final lbNear = bNear.homog();
  final List<double> lbFar = far != null
      ? far.homog()
      : snap(map(0, 23.77), map(10.97, 23.77));
  final List<double> lsvcNear = serviceLines.isNotEmpty
      ? serviceLines.first.homog()
      : snap(map(1.372, 5.485), map(9.598, 5.485));
  final List<double> lsvcFar = snap(map(1.372, 18.285), map(9.598, 18.285));

  List<double>? cross(List<double> a, List<double> b) {
    final p = [
      a[1] * b[2] - a[2] * b[1],
      a[2] * b[0] - a[0] * b[2],
      a[0] * b[1] - a[1] * b[0],
    ];
    if (p[2].abs() < 1e-12) return null;
    final x = p[0] / p[2], y = p[1] / p[2];
    return x.isFinite && y.isFinite ? [x, y] : null;
  }

  List<double>? seg(List<double> l, List<double> bound1, List<double> bound2) {
    final a = cross(l, bound1), b = cross(l, bound2);
    if (a == null || b == null) return null;
    return [a[0], a[1], b[0], b[1]];
  }

  // full court: sidelines baseline-to-baseline, centre service-to-service,
  // plus the net GROUND line (y=11.885 — the line under the net; the
  // visible tape hangs ~1m above it and will sit higher in the image).
  // On T2 the far structure comes from the service-anchor extrapolation,
  // snapped onto paint where it shows through — farAnchored=false flags
  // the approximation.
  final lNet = snap(map(0, 11.885), map(10.97, 11.885));
  // ORDER CONTRACT (relied on by courtMarking / _singlesFromProjected for the
  // singles view): [0] doubles_L, [1] singles_L, [2] centre, [3] singles_R,
  // [4] doubles_R, [5] near baseline, [6] far baseline, [7] near service,
  // [8] far service, [9] net — keep this order if you add/reorder lines.
  final segments = <List<double>>[];
  for (var i = 0; i < 5; i++) {
    final s = i == 2
        ? seg(long[i], lsvcNear, lsvcFar)
        : seg(long[i], lbNear, lbFar);
    if (s == null) return null;
    segments.add(s);
  }
  for (final t in [
    seg(lbNear, long[0], long[4]),
    seg(lbFar, long[0], long[4]),
    seg(lsvcNear, long[1], long[3]),
    seg(lsvcFar, long[1], long[3]),
    seg(lNet, long[0], long[4]),
  ]) {
    if (t == null) return null;
    segments.add(t);
  }
  // bounded output: a near-degenerate quad explodes the far extrapolation
  // far outside any sane reach of the frame
  for (final s in segments) {
    for (var k = 0; k < 4; k += 2) {
      if (s[k] < -3.0 * lab.width ||
          s[k] > 4.0 * lab.width ||
          s[k + 1] < -3.0 * lab.height ||
          s[k + 1] > 4.0 * lab.height) {
        return null;
      }
    }
  }
  return CourtProjection(segments, farAnchored);
}

// -------------------------------------------------- singles/doubles marking
// The detector always finds the full DOUBLES court (it anchors the homography
// on the outer tramlines), so singles vs doubles is purely a drawing choice:
// derive the singles marking from the full-court output at paint time.

/// Image-space intersection of the infinite lines through segments [a] and
/// [b] (each [x1,y1,x2,y2]); null when the two lines are parallel.
List<double>? _lineMeet(List<double> a, List<double> b) {
  // homogeneous line A*x+B*y+C=0 through a segment's two endpoints
  List<double> ln(List<double> s) =>
      [s[1] - s[3], s[2] - s[0], s[0] * s[3] - s[2] * s[1]];
  final la = ln(a), lb = ln(b);
  final w = la[0] * lb[1] - la[1] * lb[0];
  if (w.abs() < 1e-9) return null;
  return [
    (la[1] * lb[2] - la[2] * lb[1]) / w,
    (la[2] * lb[0] - la[0] * lb[2]) / w,
  ];
}

/// Singles view of the full-court [projected] segments (the 10 lines from
/// [projectCourt], IN THAT ORDER): keep the two singles sidelines, the centre
/// service line and both service lines (all already singles-width), drop the
/// two doubles sidelines, and clip the baselines + net ground line in to the
/// singles sidelines. Returns [projected] unchanged when it is not the
/// expected 10-segment court (degrade to the full marking rather than draw
/// garbage if projectCourt's output ever changes shape).
List<List<double>> _singlesFromProjected(List<List<double>> projected) {
  if (projected.length != 10) return projected;
  final singlesL = projected[1], centre = projected[2], singlesR = projected[3];
  final out = <List<double>>[singlesL, centre, singlesR, projected[7], projected[8]];
  // near baseline (5), far baseline (6) and net (9) span the doubles width —
  // pull each in to where it crosses the singles sidelines.
  for (final t in [projected[5], projected[6], projected[9]]) {
    final a = _lineMeet(t, singlesL), b = _lineMeet(t, singlesR);
    if (a != null && b != null) out.add([a[0], a[1], b[0], b[1]]);
  }
  return out;
}

/// Singles view of the RAW detected fallback (drawn only when the full
/// projection is unavailable): the 5 detected longitudinals are ordered
/// [doubles_L, singles_L, centre, singles_R, doubles_R] — keep the inner
/// three, drop the outer pair, clip the detected baselines to the singles
/// sidelines, and keep the (already singles-width) service lines.
List<List<double>> _singlesFromDetected(List<List<double>> lines,
    List<List<double>> baselines, List<List<double>> serviceLines) {
  if (lines.length != 5) return [...lines, ...baselines, ...serviceLines];
  final singlesL = lines[1], singlesR = lines[3];
  final out = <List<double>>[singlesL, lines[2], singlesR];
  for (final b in baselines) {
    final a = _lineMeet(b, singlesL), c = _lineMeet(b, singlesR);
    out.add(a != null && c != null ? [a[0], a[1], c[0], c[1]] : b);
  }
  out.addAll(serviceLines);
  return out;
}

/// The court lines to PAINT for the chosen format (image px). [projected] is
/// [projectCourt]'s full-court output when present; the others are the raw
/// detected fallbacks. Doubles draws the full court; singles drops the doubles
/// tramlines (see [_singlesFromProjected] / [_singlesFromDetected]).
List<List<double>> courtMarking({
  required bool doubles,
  required List<List<double>> projected,
  required List<List<double>> lines,
  required List<List<double>> baselines,
  required List<List<double>> serviceLines,
}) {
  if (projected.isNotEmpty) {
    return doubles ? projected : _singlesFromProjected(projected);
  }
  final raw = [...lines, ...baselines, ...serviceLines];
  return doubles ? raw : _singlesFromDetected(lines, baselines, serviceLines);
}

// ------------------------------------------------ manual corner adjustment
// The "Adjust court" screen lets the user drag the 4 court corners; the whole
// court re-projects from them through a fresh homography (the inner lines are
// interpolated, so the marking stays a geometrically consistent court).

/// World->image homography from the 4 court corners in image px — [nl]/[nr]/
/// [fl]/[fr] = near-left, near-right, far-left, far-right. [doubles] picks the
/// corner x-positions (doubles 0..10.97 m, singles 1.372..9.598 m); the court
/// is the full 23.77 m baseline-to-baseline either way. Null on a degenerate
/// (collinear / self-crossed) quad.
List<double>? courtHomographyFromCorners(
    List<double> nl, List<double> nr, List<double> fl, List<double> fr,
    {required bool doubles}) {
  final xl = doubles ? 0.0 : 1.372, xr = doubles ? 10.97 : 9.598;
  return homographyFrom4(
    [
      [xl, 0.0, 1],
      [xr, 0.0, 1],
      [xl, 23.77, 1],
      [xr, 23.77, 1],
    ],
    [
      [nl[0], nl[1], 1],
      [nr[0], nr[1], 1],
      [fl[0], fl[1], 1],
      [fr[0], fr[1], 1],
    ],
  );
}

/// The 10 canonical ITF court segments (projectCourt's ORDER CONTRACT) mapped
/// through a world->image homography [h] — re-draws the full court live as the
/// corners move. Feed the result to [courtMarking] for the singles/doubles
/// view.
List<List<double>> courtSegmentsFromHomography(List<double> h) {
  List<double> map(double x, double y) {
    final pw = h[6] * x + h[7] * y + h[8];
    return [
      (h[0] * x + h[1] * y + h[2]) / pw,
      (h[3] * x + h[4] * y + h[5]) / pw,
    ];
  }

  List<double> seg(List<double> a, List<double> b) => [a[0], a[1], b[0], b[1]];
  const yN = 0.0, yF = 23.77, svcN = 5.485, svcF = 18.285, net = 11.885;
  const dL = 0.0, sL = 1.372, ctr = 5.485, sR = 9.598, dR = 10.97;
  return [
    seg(map(dL, yN), map(dL, yF)), // 0 doubles_L
    seg(map(sL, yN), map(sL, yF)), // 1 singles_L
    seg(map(ctr, svcN), map(ctr, svcF)), // 2 centre (service-to-service)
    seg(map(sR, yN), map(sR, yF)), // 3 singles_R
    seg(map(dR, yN), map(dR, yF)), // 4 doubles_R
    seg(map(dL, yN), map(dR, yN)), // 5 near baseline
    seg(map(dL, yF), map(dR, yF)), // 6 far baseline
    seg(map(sL, svcN), map(sR, svcN)), // 7 near service
    seg(map(sL, svcF), map(sR, svcF)), // 8 far service
    seg(map(dL, net), map(dR, net)), // 9 net ground
  ];
}

// ---------------------------------------------------------------- entry
class VlineResult {
  final List<Stripe> stripes;
  final List<Pencil> pencils;
  final List<CourtCandidate> candidates;
  final int procWidth, procHeight;

  /// Stage-3 output: 0..2 detected baselines (near first when both).
  List<Stripe> baselines = const [];

  /// Stage-4 output: the near (camera-side) service line, when found.
  List<Stripe> serviceLines = const [];

  /// Stage-6 output: the full projected court (the final marking when
  /// available — drawn INSTEAD of the raw detected lines).
  CourtProjection? projection;

  VlineResult(this.stripes, this.pencils, this.candidates, this.procWidth,
      this.procHeight);

  /// Best accepted candidate, or null (score gate -> honest "no court").
  CourtCandidate? get best => candidates.isNotEmpty &&
          candidates.first.score <= kScoreAccept
      ? candidates.first
      : null;
}

/// Multi-scale result: [scale] maps result coordinates onto the input frame.
class VlineAuto {
  final VlineResult result;
  final double scale;
  VlineAuto(this.result, this.scale);
}

/// Run stage-1 detection on an already-normalized Lab image with the given
/// line-segment seeds (native: cv Canny+HoughLinesP via vline_court.dart;
/// web: the pure-Dart seeder in vline_seeds.dart — seeds only need to land
/// NEAR lines, the stripe validator re-finds the exact centreline).
VlineResult runVlineDetectionLab(LabImage lab, List<List<double>> seeds) {
  final diag =
      math.sqrt((lab.width * lab.width + lab.height * lab.height).toDouble());
  final minLen = 0.05 * diag;
  final stripes = detectStripes(lab, minLen, seeds);
  final pencils = findPencils(stripes);
  final candidates =
      matchCourt(pencils, lab, lab.width, lab.height, stripes);
  final result = VlineResult(stripes, pencils, candidates, lab.width, lab.height);
  final best = result.best;
  if (best != null) {
    // pose flatness BEFORE the post-passes mutate the lines
    var meanAv = 0.0;
    for (final s in best.lines) {
      meanAv += segAngleFromVertical(s.dx, s.dy);
    }
    meanAv /= best.lines.length;
    refineCourtLines(best.lines, lab);
    extendCourtLines(best.lines, lab);
    result.baselines = detectBaselines(best.lines, lab);
    result.serviceLines =
        detectServiceLines(best.lines, result.baselines, lab);
    completeCourtLines(best.lines, result.baselines, result.serviceLines,
        lab.width, lab.height);
    final verifiedFar = <Stripe>[];
    result.projection = projectCourt(
        best.lines, result.baselines, result.serviceLines, lab, verifiedFar);
    if (verifiedFar.isNotEmpty) {
      // a prediction-verified far baseline is a detected baseline
      result.baselines = [...result.baselines, ...verifiedFar];
    }
    // NET-SIDE band (66-76 deg mean): such fans are accepted ONLY when the
    // court projects FAR-ANCHORED (two detected/verified baselines passing
    // every ordering and model-inversion gate) — 8441's walking junk fans
    // (badminton overlay / practice nets, 66-75) fabricated single-baseline
    // T2 projections from overlay paint when mere projection was required
    // (t0.0-t1.8 re-armed), but a consistent SECOND baseline is beyond
    // them. End-of-court poses (<=66) keep their normal gates.
    if (meanAv > kSetMeanVertDeg &&
        (result.projection == null || !result.projection!.farAnchored)) {
      return VlineResult(
          stripes, pencils, const [], lab.width, lab.height);
    }
  }
  return result;
}

/// RGBA resize (pure Dart) — the platform-free stand-in for cv.resize where
/// OpenCV is unavailable (web). Mirrors the native path's interpolation
/// choices: bicubic for upscaling (cv INTER_CUBIC, a=-0.75 kernel — thin
/// court lines blur away under bilinear, the texflip/09 class) and box
/// averaging for downscaling (cv INTER_AREA).
Uint8List resizeRgba(Uint8List src, int w, int h, int nw, int nh) {
  if (nw == w && nh == h) return src;
  return nw > w ? _resizeCubic(src, w, h, nw, nh) : _resizeArea(src, w, h, nw, nh);
}

double _cubicW(double t) {
  // OpenCV's bicubic kernel, a = -0.75
  const a = -0.75;
  final x = t.abs();
  if (x <= 1) return ((a + 2) * x - (a + 3)) * x * x + 1;
  if (x < 2) return ((a * x - 5 * a) * x + 8 * a) * x - 4 * a;
  return 0;
}

Uint8List _resizeCubic(Uint8List src, int w, int h, int nw, int nh) {
  // separable: horizontal pass into a float buffer, then vertical
  final mid = Float32List(nw * h * 4);
  final fx = w / nw;
  final wxs = Float32List(nw * 4);
  final x0s = Int32List(nw);
  for (var x = 0; x < nw; x++) {
    final sx = (x + 0.5) * fx - 0.5;
    final x0 = sx.floor();
    x0s[x] = x0;
    for (var k = 0; k < 4; k++) {
      wxs[x * 4 + k] = _cubicW(sx - (x0 - 1 + k));
    }
  }
  for (var y = 0; y < h; y++) {
    final row = y * w * 4;
    for (var x = 0; x < nw; x++) {
      final x0 = x0s[x];
      for (var c = 0; c < 4; c++) {
        var v = 0.0;
        for (var k = 0; k < 4; k++) {
          var xx = x0 - 1 + k;
          if (xx < 0) xx = 0;
          if (xx >= w) xx = w - 1;
          v += src[row + xx * 4 + c] * wxs[x * 4 + k];
        }
        mid[(y * nw + x) * 4 + c] = v;
      }
    }
  }
  final out = Uint8List(nw * nh * 4);
  final fy = h / nh;
  for (var y = 0; y < nh; y++) {
    final sy = (y + 0.5) * fy - 0.5;
    final y0 = sy.floor();
    final wy = [for (var k = 0; k < 4; k++) _cubicW(sy - (y0 - 1 + k))];
    for (var x = 0; x < nw; x++) {
      for (var c = 0; c < 4; c++) {
        var v = 0.0;
        for (var k = 0; k < 4; k++) {
          var yy = y0 - 1 + k;
          if (yy < 0) yy = 0;
          if (yy >= h) yy = h - 1;
          v += mid[(yy * nw + x) * 4 + c] * wy[k];
        }
        out[(y * nw + x) * 4 + c] = v.round().clamp(0, 255);
      }
    }
  }
  return out;
}

Uint8List _resizeArea(Uint8List src, int w, int h, int nw, int nh) {
  final out = Uint8List(nw * nh * 4);
  final fx = w / nw, fy = h / nh;
  for (var y = 0; y < nh; y++) {
    final sy0 = y * fy, sy1 = (y + 1) * fy;
    final iy0 = sy0.floor(), iy1 = (sy1.ceil()).clamp(0, h);
    for (var x = 0; x < nw; x++) {
      final sx0 = x * fx, sx1 = (x + 1) * fx;
      final ix0 = sx0.floor(), ix1 = (sx1.ceil()).clamp(0, w);
      final acc = [0.0, 0.0, 0.0, 0.0];
      var wsum = 0.0;
      for (var yy = iy0; yy < iy1; yy++) {
        final wy = (yy + 1 < sy1 ? yy + 1 : sy1) - (yy > sy0 ? yy : sy0);
        if (wy <= 0) continue;
        for (var xx = ix0; xx < ix1; xx++) {
          final wx = (xx + 1 < sx1 ? xx + 1 : sx1) - (xx > sx0 ? xx : sx0);
          if (wx <= 0) continue;
          final ww = wx * wy;
          final i = (yy * w + xx) * 4;
          acc[0] += src[i] * ww;
          acc[1] += src[i + 1] * ww;
          acc[2] += src[i + 2] * ww;
          acc[3] += src[i + 3] * ww;
          wsum += ww;
        }
      }
      final o = (y * nw + x) * 4;
      for (var c = 0; c < 4; c++) {
        out[o + c] = (acc[c] / wsum).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// Platform-free detection entry over raw RGBA pixels: normalize to the
/// processing width, seed with the pure-Dart Canny+Hough, run detection —
/// with the same coarse-scale retry as the native path (texflip/09 class:
/// upscaled small sources blur at 1400, are crisp at 800).
VlineAuto runVlineDetectionAutoRgba(Uint8List rgba, int w, int h) {
  var px = rgba;
  var pw = w, ph = h;
  if (w != kProcW) {
    ph = (h * kProcW / w).round();
    px = resizeRgba(rgba, w, h, kProcW, ph);
    pw = kProcW;
  }
  final lab = labFromRgba(px, pw, ph);
  final r1 = runVlineDetectionLab(lab, pureSeeds(lab));
  if (r1.best != null || pw <= 800) return VlineAuto(r1, 1.0);
  final h2 = (ph * 800 / pw).round();
  final small = resizeRgba(px, pw, ph, 800, h2);
  final lab2 = labFromRgba(small, 800, h2);
  final r2 = runVlineDetectionLab(lab2, pureSeeds(lab2));
  if (r2.best != null) return VlineAuto(r2, pw / 800.0);
  return VlineAuto(r1, 1.0);
}
