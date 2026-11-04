// Blind-gap recovery orchestration — port of muse2 tennis_ai/recover.py.
//
// After global (heatmap) detection derives tracks, confident tracks still
// carry blind gaps (filled/dotted). Each filled point is a physics-aware
// prediction of where the ball was — collect them as ROI re-detection
// targets, plus short inter-tracklet voids (linear predictions). Found
// balls merge back as real candidates and the session re-derives.
//
// Kept line-for-line with the Python (same iteration and sort orders), so
// candidate order per frame — which the linker sees — is identical.
import 'dart:math' as math;

import 'core.dart';
import 'types.dart';

const int trailWindow = 64; // densify/recovery look this far past the chunk seam
const int headLag = 120; // chains followed while their head is this near the frontier
const int ringKeep = 160; // gray frames retained (heads + window + margins)

/// Recovery window start: past the seam, following live chain heads.
int trailStart(int f0, int lo, int hi, List<Track> tracks) {
  var wlo = math.max(f0, lo - trailWindow);
  final heads = [
    for (final t in tracks)
      if (t.start >= hi - headLag) t.start
  ];
  if (heads.isNotEmpty) {
    wlo = math.max(f0, math.min(wlo, heads.reduce(math.min) - 24));
  }
  return wlo;
}

/// Trailing gray-frame buffer so seams heal across chunk calls. Owns the
/// native gray buffers it holds.
class GrayRing {
  final int keep;
  final Map<int, NativeImage> _buf = {};
  GrayRing({int keep = ringKeep}) : keep = math.max(8, keep);

  void add(int frame, NativeImage gray) {
    _buf.remove(frame)?.free();
    _buf[frame] = gray;
    while (_buf.length > keep) {
      final k = _buf.keys.reduce(math.min);
      _buf.remove(k)!.free();
    }
  }

  void evictBefore(int fmin) {
    for (final f in [
      for (final k in _buf.keys)
        if (k < fmin) k
    ]) {
      _buf.remove(f)!.free();
    }
  }

  NativeImage? call(int frame) => _buf[frame];

  void clear() {
    for (final g in _buf.values) {
      g.free();
    }
    _buf.clear();
  }
}

int _cmpPair((double, double) a, (double, double) b) {
  final c = a.$1.compareTo(b.$1);
  return c != 0 ? c : a.$2.compareTo(b.$2);
}

/// Median per-frame velocity from ≤8 observed end points, or null.
(double, double)? _endVelocity(List<TrackPoint> pts, bool atEnd) {
  List<TrackPoint> window() => atEnd
      ? pts.sublist(math.max(0, pts.length - 8))
      : pts.sublist(0, math.min(8, pts.length));
  var obs = [
    for (final p in window())
      if (p.observed) p
  ];
  if (obs.length < 2) obs = window();
  final steps = <(double, double)>[];
  for (var i = 0; i + 1 < obs.length; i++) {
    final a = obs[i], b = obs[i + 1];
    final df = b.frame - a.frame;
    if (df > 0) steps.add(((b.x - a.x) / df, (b.y - a.y) / df));
  }
  if (steps.isEmpty) return null;
  steps.sort(_cmpPair);
  return steps[steps.length ~/ 2];
}

typedef Target = (int, double, double);

int _cmpTarget(Target a, Target b) {
  var c = a.$1.compareTo(b.$1);
  if (c != 0) return c;
  c = a.$2.compareTo(b.$2);
  return c != 0 ? c : a.$3.compareTo(b.$3);
}

/// Targets (frame, px, py) for ROI search within [lo, hi).
List<Target> collectTargets(List<Track> tracks, int lo, int hi,
    {int maxVoid = 16, int maxOpenGap = 45, int maxExtend = 20}) {
  final targets = <Target>[];
  final observedFrames = <int>{
    for (final t in tracks)
      for (final p in t.points)
        if (p.observed) p.frame
  };
  for (final t in tracks) {
    if (t.points.length < 6) continue;
    for (final p in t.points) {
      if (!p.observed && lo <= p.frame && p.frame < hi) {
        targets.add((p.frame, p.x, p.y));
      }
    }
    final pts = List.of(t.points);
    _stableSortBy(pts, (p) => p.frame);
    for (var i = 0; i + 1 < pts.length; i++) {
      final a = pts[i], b = pts[i + 1];
      final gap = b.frame - a.frame - 1;
      if (gap < 1 || gap > maxOpenGap) continue;
      for (var f = a.frame + 1; f < b.frame; f++) {
        if (!(lo <= f && f < hi)) continue;
        final u = (f - a.frame) / (b.frame - a.frame);
        targets.add((f, a.x + u * (b.x - a.x), a.y + u * (b.y - a.y)));
      }
    }
    var v = _endVelocity(pts, true);
    if (v != null) {
      final e = pts.last;
      for (var f = e.frame + 1; f < e.frame + 1 + maxExtend; f++) {
        if (lo <= f && f < hi && !observedFrames.contains(f)) {
          targets.add(
              (f, e.x + v.$1 * (f - e.frame), e.y + v.$2 * (f - e.frame)));
        }
      }
    }
    v = _endVelocity(pts, false);
    if (v != null) {
      final s = pts.first;
      for (var f = s.frame - maxExtend; f < s.frame; f++) {
        if (lo <= f && f < hi && !observedFrames.contains(f)) {
          targets.add(
              (f, s.x + v.$1 * (f - s.frame), s.y + v.$2 * (f - s.frame)));
        }
      }
    }
  }
  // Inter-tracklet voids: consecutive-in-time pairs only.
  final ordered = List.of(tracks);
  _stableSortBy(ordered, (t) => t.start);
  for (var i = 0; i + 1 < ordered.length; i++) {
    final a = ordered[i], b = ordered[i + 1];
    final gap = b.start - a.end - 1;
    if (gap < 1 || gap > maxVoid) continue;
    final x0 = a.points.last.x, y0 = a.points.last.y;
    final x1 = b.points.first.x, y1 = b.points.first.y;
    for (var f = a.end + 1; f < b.start; f++) {
      if (!(lo <= f && f < hi) || observedFrames.contains(f)) continue;
      final u = (f - a.end) / (b.start - a.end);
      targets.add((f, x0 + u * (x1 - x0), y0 + u * (y1 - y0)));
    }
  }
  targets.sort(_cmpTarget);
  return targets;
}

/// Python's sort is stable; Dart's List.sort is not guaranteed to be.
void _stableSortBy<T>(List<T> xs, int Function(T) key) {
  final idx = List<int>.generate(xs.length, (i) => i);
  idx.sort((a, b) {
    final c = key(xs[a]).compareTo(key(xs[b]));
    return c != 0 ? c : a.compareTo(b);
  });
  final copy = List.of(xs);
  for (var i = 0; i < idx.length; i++) {
    xs[i] = copy[idx[i]];
  }
}

/// Merge recovered (x, y, conf) per frame into fc. Returns count.
int mergeFound(
    Map<int, List<Candidate>> fc, Map<int, List<(double, double, double)>> found) {
  var n = 0;
  found.forEach((f, cs) {
    final cur = fc.putIfAbsent(f, () => []);
    for (final c in cs) {
      // Repeat finds of one ghost/ball (overlapping targets across
      // tracks and rounds) stay a single candidate: duplicates fragment
      // linking and shift fires instead of adding information.
      var dup = false;
      for (final e in cur) {
        final dx = c.$1 - e.x, dy = c.$2 - e.y;
        if (dx * dx + dy * dy < 4.0) {
          dup = true;
          break;
        }
      }
      if (dup) continue;
      cur.add(Candidate(c.$1, c.$2, c.$3));
      n++;
    }
  });
  return n;
}

typedef GrayAt = NativeImage? Function(int frame);

/// ROI-fill small gaps between consecutive sparse sightings (pre-link
/// densifier for strided detection).
Map<int, List<Candidate>> densifyGaps(Map<int, List<Candidate>> newCands,
    GrayAt grayAt, int lo, int hi, RoiFinder roi,
    {int maxGap = 8, double maxDist = 80.0, double radius = 80.0}) {
  final out = <int, List<Candidate>>{};
  final frames = [
    for (final f in newCands.keys)
      if (lo <= f && f < hi) f
  ]..sort();
  for (var i = 0; i + 1 < frames.length; i++) {
    final f1 = frames[i], f2 = frames[i + 1];
    final gap = f2 - f1 - 1;
    if (gap < 1 || gap > maxGap) continue;
    for (final c1 in newCands[f1]!) {
      for (final c2 in newCands[f2]!) {
        final dx = c2.x - c1.x, dy = c2.y - c1.y;
        if (math.sqrt(dx * dx + dy * dy) > maxDist) continue;
        for (var f = f1 + 1; f < f2; f++) {
          if (newCands.containsKey(f) || out.containsKey(f)) continue;
          final u = (f - f1) / (f2 - f1);
          final px = c1.x + u * (c2.x - c1.x);
          final py = c1.y + u * (c2.y - c1.y);
          final g0 = grayAt(f - 1), g1 = grayAt(f), g2 = grayAt(f + 1);
          if (g1 == null) continue;
          final hit = roi.find(g0 ?? g1, g1, g2 ?? g1, px, py, radius);
          if (hit != null) {
            out.putIfAbsent(f, () => []).add(Candidate(hit.$1, hit.$2, hit.$3));
          }
        }
      }
    }
  }
  return out;
}

/// ROI-search one chunk's blind gaps; merge + rebuild if found. Iterates up
/// to [maxRounds] so a dropped ball is chased across consecutive extensions.
/// Returns the recovered-ball count.
int recoverChunk(Map<int, List<Candidate>> fc, StreamSession session,
    GrayAt grayAt, int lo, int hi, RoiFinder roi,
    {double radius = 80.0, int maxRounds = 4}) {
  var total = 0;
  // frame -> last searched prediction, or null value = HIT
  final searched = <int, (double, double)?>{};
  for (var round = 0; round < math.max(1, maxRounds); round++) {
    final fresh = <Target>[];
    for (final t in collectTargets(session.tracks, lo, hi)) {
      final (f, px, py) = t;
      if (!searched.containsKey(f)) {
        fresh.add(t);
        continue;
      }
      final prev = searched[f];
      if (prev == null) continue; // HIT: never re-searched
      final ox = prev.$1, oy = prev.$2;
      if ((px - ox) * (px - ox) + (py - oy) * (py - oy) > 64.0) fresh.add(t);
    }
    if (fresh.isEmpty) break;
    final found = <int, List<(double, double, double)>>{};
    for (final (f, px, py) in fresh) {
      final g0 = grayAt(f - 1), g1 = grayAt(f), g2 = grayAt(f + 1);
      if (g1 == null) continue;
      final hit = roi.find(g0 ?? g1, g1, g2 ?? g1, px, py, radius);
      if (hit != null) {
        searched[f] = null;
        found.putIfAbsent(f, () => []).add(hit);
      } else {
        searched[f] = (px, py);
      }
    }
    final n = mergeFound(fc, found);
    total += n;
    if (n == 0) break;
    session.reset();
    session.ingest(sortedCands(fc));
  }
  return total;
}

/// `{i: fc[i] for i in sorted(fc)}`.
Map<int, List<Candidate>> sortedCands(Map<int, List<Candidate>> fc) {
  final keys = fc.keys.toList()..sort();
  return {for (final k in keys) k: fc[k]!};
}

/// StreamSession (streaming.py) on the core engine: the incremental
/// tracks + rallies the driver feeds.
class StreamSession {
  final double fps;
  final int width;
  final List<double>? hImg2Court, hCourt2Img;
  final bool courtFilter;
  final CoreSession _core;
  int nCands = 0;

  StreamSession(this.fps, this.width,
      {this.hImg2Court,
      this.hCourt2Img,
      this.courtFilter = true,
      TrackerConfig cfg = const TrackerConfig()})
      : _core = CoreSession(fps, width,
            hImg2Court: hImg2Court,
            hCourt2Img: hCourt2Img,
            courtFilter: courtFilter) {
    const d = TrackerConfig();
    if (cfg.stitchGap != d.stitchGap || cfg.stitchResid != d.stitchResid) {
      _core.setStitch(cfg.stitchGap, cfg.stitchResid);
    }
    if (cfg.minLength != d.minLength) _core.setMinLength(cfg.minLength);
  }

  List<Track> get tracks => _core.tracks;
  List<Rally> get rallies => _core.rallies;
  int get coverage => _core.coverage;

  void reset() {
    _core.reset();
    nCands = 0;
  }

  void ingest(Map<int, List<Candidate>> newCands) {
    if (newCands.isEmpty) return;
    _core.ingest(newCands);
    for (final cs in newCands.values) {
      nCands += cs.length;
    }
  }

  void close() => _core.close();
}

/// The stitch/confirmation knobs of tracker.TrackerConfig the core exposes.
class TrackerConfig {
  final int stitchGap;
  final double stitchResid;
  final int minLength;
  const TrackerConfig(
      {this.stitchGap = 30, this.stitchResid = 5.0, this.minLength = 8});

  /// tracker.fast_config(): sparse (ANE, stride-3) candidates.
  /// minLength 3 (not 6): short occlusion-exit chains (3-5 takes) must
  /// survive as stitch inputs; the UI hides sub-6 tracks from display.
  static const fast =
      TrackerConfig(stitchGap: 45, stitchResid: 8.0, minLength: 3);
}
