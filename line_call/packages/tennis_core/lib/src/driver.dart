// Source-agnostic detection driver: frames in, tracks/rallies out — port of
// muse2 umpire/driver.py ChunkDriver (== streaming.py StreamAnalyzer.step
// in film mode): triplet tail, strided inference, densify, session ingest,
// blind-gap recovery. Runs synchronously; the engine isolate drives it.
import 'dart:collection';
import 'dart:math' as math;

import 'core.dart';
import 'recover.dart';
import 'types.dart';

class ChunkDriver {
  final double fps;
  final int width, height; // processing size (frames must arrive at this size)
  final int chunk;
  final int stride;
  final bool recover;
  final CoreDetector detector;
  StreamSession session;

  /// Every candidate so far (frame -> candidates), detection + recovery.
  final Map<int, List<Candidate>> fc = {};

  final Queue<(int, NativeImage)> _q = Queue();
  List<NativeImage> _tail = [];
  int _next = 0;
  final GrayRing _ring = GrayRing();
  final RoiFinder _roi = RoiFinder();

  ChunkDriver({
    required this.fps,
    required this.width,
    required this.height,
    required this.detector,
    List<double>? hImg2Court,
    List<double>? hCourt2Img,
    TrackerConfig cfg = TrackerConfig.fast,
    this.chunk = 24,
    int stride = 3,
    this.recover = true,
    bool courtFilter = true,
  })  : stride = math.max(1, stride),
        session = StreamSession(fps, width,
            hImg2Court: hImg2Court,
            hCourt2Img: hCourt2Img,
            courtFilter: courtFilter,
            cfg: cfg);

  /// Append one processing-size BGR frame (ownership passes to the driver);
  /// returns its global index.
  int push(NativeImage bgr) {
    final f = _next + _q.length;
    _q.add((f, bgr));
    return f;
  }

  /// First frame not yet detected.
  int get frontier => _next;
  int get pending => _q.length;

  /// Detect up to one chunk of queued frames. False if starved.
  bool step() {
    if (_q.isEmpty) return false;
    final take = math.min(_q.length, chunk);
    if (_next == 0 && take + _tail.length < 3) return false; // need a triplet
    final lo = _next;
    final frames = [for (var i = 0; i < take; i++) _q.removeFirst().$2];
    final hi = lo + take;
    final chunkImgs = [..._tail, ...frames];
    final base = lo - _tail.length;
    final newCands = <int, List<Candidate>>{};
    if (stride > 1) {
      for (var k = 0; k < chunkImgs.length; k++) {
        final fno = base + k;
        if (fno < lo || fno >= hi) continue;
        if (fno % stride != 0 || k < 2) continue;
        final cs = detector.candidatesFor(chunkImgs.sublist(k - 2, k + 1))[2];
        if (cs.isNotEmpty) {
          newCands[fno] = cs;
          fc[fno] = cs;
        }
      }
    } else {
      final all = detector.candidatesFor(chunkImgs);
      for (var k = 0; k < all.length; k++) {
        if (_tail.isNotEmpty && k < 2) continue;
        if (base + k >= hi) break;
        final cs = all[k];
        if (cs.isNotEmpty) {
          newCands[base + k] = cs;
          fc[base + k] = cs;
        }
      }
    }
    final got = take;
    _next = lo + got;
    final wlo = trailStart(0, lo, hi, session.tracks);
    if (recover) {
      for (var f = lo; f < lo + got; f++) {
        _ring.add(f, grayFromBgr(chunkImgs[f - base]));
      }
      _ring.evictBefore(wlo - 1);
    }
    // Free BGR frames that leave the 2-frame triplet tail.
    final newTail = chunkImgs.sublist(math.max(0, chunkImgs.length - 2));
    for (final img in chunkImgs) {
      if (!newTail.contains(img)) img.free();
    }
    _tail = newTail;
    // Every chunk frame is in the ring (added above, never evicted: they are
    // the newest and >= wlo), so the ring alone serves both lookups exactly
    // like the Python's chunk-dict-then-ring two-tier lookup.
    NativeImage? grayAt(int f) => _ring(f);
    var denseOld = false;
    if (stride > 1 && recover) {
      final subset = <int, List<Candidate>>{
        for (var f = wlo; f < hi; f++)
          if (fc.containsKey(f)) f: fc[f]!
      };
      final dense = densifyGaps(subset, grayAt, wlo, hi, _roi);
      dense.forEach((f, cs) {
        fc[f] = cs;
        if (f < lo) {
          denseOld = true;
        } else {
          newCands[f] = cs;
        }
      });
    }
    if (denseOld) {
      session.reset();
      session.ingest(sortedCands(fc));
    } else {
      session.ingest(newCands);
    }
    if (recover) {
      recoverChunk(fc, session, grayAt, wlo, hi, _roi);
    }
    return true;
  }

  /// End of footage: detect what's left (a final partial chunk).
  void flush() {
    while (pending >= 3) {
      if (!step()) break;
    }
  }

  void close() {
    for (final (_, img) in _q) {
      img.free();
    }
    _q.clear();
    for (final img in _tail) {
      img.free();
    }
    _tail = [];
    _ring.clear();
    _roi.close();
    session.close();
  }
}
