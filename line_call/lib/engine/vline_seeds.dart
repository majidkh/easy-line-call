// =============================================================================
// LINE CALLING — pure-Dart line-segment seeder (web path).
//
// Ports of OpenCV's Canny (aperture 3, L1 gradient) and probabilistic
// HoughLinesP, used where dartcv cannot go (Flutter web has no dart:ffi).
// Seeds only need to land NEAR court lines — the stripe validator in
// vline_court_core.dart re-finds the exact centreline — so this seeder does
// not have to be bit-identical to OpenCV's; it must only surface roughly
// the same segments. Fixed-seed RNG keeps it deterministic per frame.
// =============================================================================
import 'dart:math' as math;
import 'dart:typed_data';

import 'vline_court_core.dart';

/// Line-segment seeds from the pure Canny+Hough on the three Lab channels —
/// the platform-free twin of vline_court.dart's houghSeeds.
List<List<double>> pureSeeds(LabImage lab) {
  final w = lab.width, h = lab.height;
  final segs = <List<double>>[];
  for (var ch = 0; ch < 3; ch++) {
    final buf = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      final v = lab.data[i * 3 + ch];
      final u = ch == 0 ? v * 2.55 : v + 128.0;
      buf[i] = u < 0 ? 0 : (u > 255 ? 255 : u.round());
    }
    final edges = _canny(buf, w, h, 30, 90);
    segs.addAll(_houghLinesP(edges, w, h,
        threshold: 26, minLineLength: 22, maxLineGap: 3));
  }
  segs.removeWhere((s) {
    final l = math.sqrt(
        (s[2] - s[0]) * (s[2] - s[0]) + (s[3] - s[1]) * (s[3] - s[1]));
    return l < 22;
  });
  segs.sort((a, b) {
    double len(List<double> s) =>
        (s[2] - s[0]) * (s[2] - s[0]) + (s[3] - s[1]) * (s[3] - s[1]);
    return len(b).compareTo(len(a));
  });
  if (segs.length > 700) segs.length = 700;
  return segs;
}

/// Test hook: the pure Canny, exposed for parity diagnostics against cv.
Uint8List debugCanny(Uint8List src, int w, int h, int low, int high) =>
    _canny(src, w, h, low, high);

/// Canny on an 8-bit single-channel image: Sobel-3 (replicated border),
/// L1 gradient magnitude, 4-sector non-maximum suppression, double-threshold
/// hysteresis with 8-connectivity.
Uint8List _canny(Uint8List src, int w, int h, int low, int high) {
  final dx = Int32List(w * h), dy = Int32List(w * h), mag = Int32List(w * h);
  int px(int x, int y) {
    final xx = x < 0 ? 0 : (x >= w ? w - 1 : x);
    final yy = y < 0 ? 0 : (y >= h ? h - 1 : y);
    return src[yy * w + xx];
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p00 = px(x - 1, y - 1), p01 = px(x, y - 1), p02 = px(x + 1, y - 1);
      final p10 = px(x - 1, y), p12 = px(x + 1, y);
      final p20 = px(x - 1, y + 1), p21 = px(x, y + 1), p22 = px(x + 1, y + 1);
      final gx = (p02 + 2 * p12 + p22) - (p00 + 2 * p10 + p20);
      final gy = (p20 + 2 * p21 + p22) - (p00 + 2 * p01 + p02);
      final i = y * w + x;
      dx[i] = gx;
      dy[i] = gy;
      mag[i] = gx.abs() + gy.abs();
    }
  }

  // NMS: 1 = survived suppression and above low, 2 = also above high
  final state = Uint8List(w * h);
  const tg22 = 0.4142135623730951; // tan(22.5 deg)
  const tg67 = 2.414213562373095; // tan(67.5 deg)
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final m = mag[i];
      if (m <= low) continue;
      final ax = dx[i].abs(), ay = dy[i].abs();
      int n1, n2;
      if (ay < tg22 * ax) {
        n1 = mag[i - 1];
        n2 = mag[i + 1];
      } else if (ay > tg67 * ax) {
        n1 = mag[i - w];
        n2 = mag[i + w];
      } else if (dx[i].sign == dy[i].sign) {
        n1 = mag[i - w - 1];
        n2 = mag[i + w + 1];
      } else {
        n1 = mag[i - w + 1];
        n2 = mag[i + w - 1];
      }
      if (m > n1 && m >= n2) state[i] = m > high ? 2 : 1;
    }
  }

  // hysteresis: BFS from strong pixels across NMS survivors
  final out = Uint8List(w * h);
  final stack = Int32List(w * h);
  var top = 0;
  for (var i = 0; i < w * h; i++) {
    if (state[i] == 2 && out[i] == 0) {
      out[i] = 255;
      stack[top++] = i;
      while (top > 0) {
        final j = stack[--top];
        final jy = j ~/ w, jx = j - jy * w;
        for (var ny = jy - 1; ny <= jy + 1; ny++) {
          if (ny < 0 || ny >= h) continue;
          for (var nx = jx - 1; nx <= jx + 1; nx++) {
            if (nx < 0 || nx >= w) continue;
            final k = ny * w + nx;
            if (state[k] != 0 && out[k] == 0) {
              out[k] = 255;
              stack[top++] = k;
            }
          }
        }
      }
    }
  }
  return out;
}

/// Deterministic xorshift32 — OpenCV's PPHT consumes points in random order;
/// the exact generator does not matter, stability per frame does.
class _Rng {
  int _s = 0x12345678;
  int next(int bound) {
    var x = _s;
    x ^= (x << 13) & 0xffffffff;
    x ^= x >>> 17;
    x ^= (x << 5) & 0xffffffff;
    _s = x;
    return x % bound;
  }
}

/// Progressive probabilistic Hough transform, after OpenCV's
/// HoughLinesProbabilistic: random edge points vote in a rho-theta
/// accumulator; when a bin crosses [threshold], walk the image along that
/// angle gathering contiguous edge pixels (gaps <= [maxLineGap]), emit the
/// segment if its dominant-axis extent reaches [minLineLength], and retract
/// the votes of every consumed pixel.
List<List<double>> _houghLinesP(Uint8List edges, int w, int h,
    {required int threshold,
    required int minLineLength,
    required int maxLineGap}) {
  const numAngle = 180;
  final numRho = (w + h) * 2 + 1;
  final halfRho = (numRho - 1) ~/ 2;
  final cosT = Float64List(numAngle), sinT = Float64List(numAngle);
  for (var n = 0; n < numAngle; n++) {
    cosT[n] = math.cos(n * math.pi / 180);
    sinT[n] = math.sin(n * math.pi / 180);
  }
  final accum = Int32List(numAngle * numRho);
  final mask = Uint8List(w * h);
  var nPts = 0;
  for (var i = 0; i < w * h; i++) {
    if (edges[i] != 0) {
      mask[i] = 1;
      nPts++;
    }
  }
  final ptX = Int32List(nPts), ptY = Int32List(nPts);
  var pi = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (edges[y * w + x] != 0) {
        ptX[pi] = x;
        ptY[pi] = y;
        pi++;
      }
    }
  }

  final rng = _Rng();
  final out = <List<double>>[];
  const shift = 16;
  for (var count = nPts; count > 0; count--) {
    final idx = rng.next(count);
    final x0 = ptX[idx], y0 = ptY[idx];
    ptX[idx] = ptX[count - 1];
    ptY[idx] = ptY[count - 1];
    ptX[count - 1] = x0;
    ptY[count - 1] = y0;
    if (mask[y0 * w + x0] == 0) continue; // consumed by an earlier segment

    var maxVal = threshold - 1, maxN = 0;
    for (var n = 0; n < numAngle; n++) {
      final r = (x0 * cosT[n] + y0 * sinT[n]).round() + halfRho;
      final v = ++accum[n * numRho + r];
      if (v > maxVal) {
        maxVal = v;
        maxN = n;
      }
    }
    if (maxVal < threshold) continue;

    // walk both directions along the line direction (-sin, cos)
    final a = -sinT[maxN], b = cosT[maxN];
    int dx0, dy0, fx0, fy0;
    bool xDominant;
    if (a.abs() > b.abs()) {
      xDominant = true;
      dx0 = a > 0 ? 1 : -1;
      dy0 = (b * (1 << shift) / a.abs()).round();
      fx0 = x0;
      fy0 = (y0 << shift) + (1 << (shift - 1));
    } else {
      xDominant = false;
      dy0 = b > 0 ? 1 : -1;
      dx0 = (a * (1 << shift) / b.abs()).round();
      fy0 = y0;
      fx0 = (x0 << shift) + (1 << (shift - 1));
    }
    // The walk RE-CENTERS by +-1px across the line when the exact pixel
    // misses but a lateral neighbour is set: the accumulator's 1-degree bins
    // leave the walk direction slightly off the true paint direction, and on
    // thin (1-2px) lines a strict single-pixel walk falls off after ~100px
    // of accumulated drift, fragmenting exactly the long seeds the court
    // needs (texflip/09's baseline region). Re-centering follows the actual
    // chain; the consume pass retraces the identical recentered path so the
    // chain is fully cleared (a non-recentering lateral variant under-cleared
    // and flooded the pool with +-1px duplicate stripes).
    int lateral(int j1, int i1) {
      if (mask[i1 * w + j1] != 0) return 0;
      if (xDominant) {
        if (i1 > 0 && mask[(i1 - 1) * w + j1] != 0) return -1;
        if (i1 < h - 1 && mask[(i1 + 1) * w + j1] != 0) return 1;
      } else {
        if (j1 > 0 && mask[i1 * w + j1 - 1] != 0) return -1;
        if (j1 < w - 1 && mask[i1 * w + j1 + 1] != 0) return 1;
      }
      return -2; // miss
    }

    final endX = Int32List(2), endY = Int32List(2);
    for (var k = 0; k < 2; k++) {
      var gap = 0;
      var x = fx0, y = fy0;
      final dx = k == 0 ? dx0 : -dx0, dy = k == 0 ? dy0 : -dy0;
      endX[k] = x0;
      endY[k] = y0;
      while (true) {
        final j1 = xDominant ? x : x >> shift;
        final i1 = xDominant ? y >> shift : y;
        if (j1 < 0 || j1 >= w || i1 < 0 || i1 >= h) break;
        final lat = lateral(j1, i1);
        if (lat != -2) {
          gap = 0;
          if (xDominant) {
            endX[k] = j1;
            endY[k] = i1 + lat;
            y += lat << shift; // re-center onto the chain
          } else {
            endX[k] = j1 + lat;
            endY[k] = i1;
            x += lat << shift;
          }
        } else if (++gap > maxLineGap) {
          break;
        }
        x += dx;
        y += dy;
      }
    }
    final goodLine = (endX[1] - endX[0]).abs() >= minLineLength ||
        (endY[1] - endY[0]).abs() >= minLineLength;

    // second pass: retrace the identical recentered path, consuming the
    // segment's pixels (and retracting their votes)
    for (var k = 0; k < 2; k++) {
      var x = fx0, y = fy0;
      final dx = k == 0 ? dx0 : -dx0, dy = k == 0 ? dy0 : -dy0;
      while (true) {
        final j1 = xDominant ? x : x >> shift;
        final i1 = xDominant ? y >> shift : y;
        if (j1 < 0 || j1 >= w || i1 < 0 || i1 >= h) break;
        final lat = lateral(j1, i1);
        if (lat != -2) {
          final jj = xDominant ? j1 : j1 + lat;
          final ii = xDominant ? i1 + lat : i1;
          if (goodLine) {
            for (var n = 0; n < numAngle; n++) {
              final r = (jj * cosT[n] + ii * sinT[n]).round() + halfRho;
              accum[n * numRho + r]--;
            }
          }
          mask[ii * w + jj] = 0;
          if (xDominant) {
            y += lat << shift;
          } else {
            x += lat << shift;
          }
        }
        if ((xDominant && j1 == endX[k]) || (!xDominant && i1 == endY[k])) {
          break;
        }
        x += dx;
        y += dy;
      }
    }
    if (goodLine) {
      out.add([
        endX[0].toDouble(),
        endY[0].toDouble(),
        endX[1].toDouble(),
        endY[1].toDouble()
      ]);
      if (out.length >= 2000) break;
    }
  }
  return out;
}

/// Test hook: the pure probabilistic Hough, exposed for parity diagnostics.
List<List<double>> debugHough(Uint8List edges, int w, int h,
        {required int threshold,
        required int minLineLength,
        required int maxLineGap}) =>
    _houghLinesP(edges, w, h,
        threshold: threshold,
        minLineLength: minLineLength,
        maxLineGap: maxLineGap);
