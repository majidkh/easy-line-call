// Dart container over the muse2 core — a port of tennis_ai/core_bind.py.
// It only marshals data across the C ABI; every decision (detection,
// linking, stitching, bounces, rallies, court fit) happens in the core.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'types.dart';

class TennisCoreException implements Exception {
  final String message;
  TennisCoreException(this.message);
  @override
  String toString() => message;
}

TennisCoreLib _lib() {
  final l = TennisCoreLib.instance;
  if (l == null) throw TennisCoreException(TennisCoreLib.loadError);
  return l;
}

String _lastError(TennisCoreLib l) => l.lastError().cast<Utf8>().toDartString();

Object? _takeJson(TennisCoreLib l, Pointer<Char> p) {
  if (p == nullptr) return null;
  try {
    return jsonDecode(p.cast<Utf8>().toDartString());
  } finally {
    l.free(p.cast());
  }
}

/// A malloc'd pixel buffer (BGR w*h*3 or gray w*h) owned by Dart.
class NativeImage {
  final Pointer<Uint8> ptr;
  final int w, h, channels;
  NativeImage._(this.ptr, this.w, this.h, this.channels);

  factory NativeImage.alloc(int w, int h, int channels) =>
      NativeImage._(malloc<Uint8>(w * h * channels), w, h, channels);

  bool _freed = false;
  void free() {
    if (_freed) return;
    _freed = true;
    malloc.free(ptr);
  }
}

/// RGBA bytes -> BGR at [outW] x [outH] (bilinear resize via the core when
/// the size differs, the same op the core uses internally).
NativeImage bgrFromRgba(Uint8List rgba, int w, int h, int outW, int outH) {
  final l = _lib();
  final src = malloc<Uint8>(rgba.length);
  src.asTypedList(rgba.length).setAll(0, rgba);
  final bgr = NativeImage.alloc(w, h, 3);
  try {
    final conv = l.rgbaToBgr;
    if (conv != null) {
      conv(src, w, h, bgr.ptr);
    } else {
      final d = bgr.ptr.asTypedList(w * h * 3);
      for (var i = 0, j = 0; i < w * h; i++, j += 3) {
        d[j] = rgba[4 * i + 2];
        d[j + 1] = rgba[4 * i + 1];
        d[j + 2] = rgba[4 * i];
      }
    }
  } finally {
    malloc.free(src);
  }
  if (w == outW && h == outH) return bgr;
  final resize = l.resizeBgr;
  if (resize == null) {
    bgr.free();
    throw TennisCoreException('resize unavailable in this core build');
  }
  final out = NativeImage.alloc(outW, outH, 3);
  resize(bgr.ptr, w, h, out.ptr, outW, outH);
  bgr.free();
  return out;
}

/// BGR -> gray, bit-exact with cv2.cvtColor(COLOR_BGR2GRAY) (15-bit fixed point).
NativeImage grayFromBgr(NativeImage bgr) {
  final l = _lib();
  final g = NativeImage.alloc(bgr.w, bgr.h, 1);
  final conv = l.bgrToGray;
  if (conv != null) {
    conv(bgr.ptr, bgr.w, bgr.h, g.ptr);
  } else {
    final s = bgr.ptr.asTypedList(bgr.w * bgr.h * 3);
    final d = g.ptr.asTypedList(bgr.w * bgr.h);
    for (var i = 0, j = 0; i < d.length; i++, j += 3) {
      d[i] = (s[j] * 3735 + s[j + 1] * 19235 + s[j + 2] * 9798 + 16384) >> 15;
    }
  }
  return g;
}

/// Incremental tracks + rallies from the core (core_bind.CoreSession).
class CoreSession {
  final TennisCoreLib _l;
  final double fps;
  final int width;
  final List<double>? hImg2Court, hCourt2Img;
  final bool courtFilter;
  (int, double)? _stitch;
  int? _minLength;
  Pointer<Void> _h = nullptr;
  final _keep = <Pointer<Double>>[];

  List<Track> tracks = const [];
  List<Rally> rallies = const [];

  CoreSession(this.fps, this.width,
      {this.hImg2Court, this.hCourt2Img, this.courtFilter = true})
      : _l = _lib() {
    _h = _create();
  }

  Pointer<Void> _create() {
    Pointer<Double> a = nullptr, b = nullptr;
    final h1 = hImg2Court, h2 = hCourt2Img;
    if (h1 != null && h2 != null) {
      if (_keep.isEmpty) {
        a = malloc<Double>(9);
        b = malloc<Double>(9);
        for (var i = 0; i < 9; i++) {
          a[i] = h1[i];
          b[i] = h2[i];
        }
        _keep.addAll([a, b]);
      } else {
        a = _keep[0];
        b = _keep[1];
      }
    }
    final h = _l.sessionCreate(fps, width, a, b, courtFilter ? 1 : 0);
    if (h == nullptr) throw TennisCoreException(_lastError(_l));
    return h;
  }

  void setStitch(int gap, double resid) {
    _stitch = (gap, resid);
    _l.sessionSetStitch(_h, gap, resid);
  }

  void setMinLength(int n) {
    _minLength = n;
    _l.sessionSetMinLength(_h, n);
  }

  int get coverage => _l.sessionCoverage(_h);

  /// Forget everything (for rebuild-from-merged-candidates).
  void reset() {
    _l.sessionDestroy(_h);
    _h = _create();
    final s = _stitch;
    if (s != null) _l.sessionSetStitch(_h, s.$1, s.$2);
    final m = _minLength;
    if (m != null) _l.sessionSetMinLength(_h, m);
    tracks = const [];
    rallies = const [];
  }

  /// Merge one more frame batch (any key order — sorted here, like the
  /// Python wrapper) and re-derive tracks + rallies. Empty input is a no-op.
  void ingest(Map<int, List<Candidate>> frameCands) {
    if (frameCands.isEmpty) return;
    final frames = frameCands.keys.toList()..sort();
    var n = 0;
    for (final f in frames) {
      n += frameCands[f]!.length;
    }
    final fa = malloc<Int32>(frames.length);
    final na = malloc<Int32>(frames.length);
    final xa = malloc<Double>(n == 0 ? 1 : n);
    final ya = malloc<Double>(n == 0 ? 1 : n);
    final ca = malloc<Double>(n == 0 ? 1 : n);
    try {
      var k = 0;
      for (var i = 0; i < frames.length; i++) {
        final cs = frameCands[frames[i]]!;
        fa[i] = frames[i];
        na[i] = cs.length;
        for (final c in cs) {
          xa[k] = c.x;
          ya[k] = c.y;
          ca[k] = c.conf;
          k++;
        }
      }
      if (_l.sessionIngest(_h, frames.length, fa, xa, ya, ca, na) != 0) {
        throw TennisCoreException(_lastError(_l));
      }
    } finally {
      malloc
        ..free(fa)
        ..free(na)
        ..free(xa)
        ..free(ya)
        ..free(ca);
    }
    final jt = _takeJson(_l, _l.sessionTracksJson(_h)) as List? ?? const [];
    final jr = _takeJson(_l, _l.sessionRalliesJson(_h)) as List? ?? const [];
    tracks = [for (final t in jt) Track.fromJson(t as Map<String, dynamic>)];
    rallies = [for (final r in jr) Rally.fromJson(r as Map<String, dynamic>)];
  }

  void close() {
    if (_h != nullptr) {
      _l.sessionDestroy(_h);
      _h = nullptr;
    }
    for (final p in _keep) {
      malloc.free(p);
    }
    _keep.clear();
  }
}

/// In-core Core ML ball detector (core_bind.CoreDetector), Apple only.
class CoreDetector {
  final TennisCoreLib _l;
  Pointer<Void> _h;
  CoreDetector._(this._l, this._h);

  /// [modelPath] is an .mlpackage directory; it is compiled once into
  /// [compileCache] and reused on later runs.
  static CoreDetector create(String modelPath, String compileCache) {
    final l = _lib();
    final mp = modelPath.toNativeUtf8();
    final cp = compileCache.toNativeUtf8();
    try {
      final h = l.detectorCreate(mp.cast(), cp.cast());
      if (h == nullptr) throw TennisCoreException(_lastError(l));
      return CoreDetector._(l, h);
    } finally {
      malloc
        ..free(mp)
        ..free(cp);
    }
  }

  /// Heat maps for [frames] (the first two are always zero, as in
  /// heatmaps_for), turned into candidates per frame via the core's
  /// extractor at the frames' own size. Index i of the result belongs to
  /// frames[i].
  List<List<Candidate>> candidatesFor(List<NativeImage> frames) {
    final n = frames.length;
    final w = frames.first.w, h = frames.first.h;
    final arr = malloc<Pointer<Uint8>>(n);
    final out = malloc<Pointer<Uint8>>();
    final ow = malloc<Int32>(), oh = malloc<Int32>(), nc = malloc<Int32>();
    try {
      for (var i = 0; i < n; i++) {
        arr[i] = frames[i].ptr;
      }
      final rc = _l.detectorInfer(_h, arr, n, w, h, out, ow, oh, nullptr);
      if (rc != 0) throw TennisCoreException(_lastError(_l));
      final mw = ow.value, mh = oh.value;
      final maps = out.value;
      try {
        return [
          for (var i = 0; i < n; i++)
            _extract(_l, maps + i * mw * mh, mw, mh, w, h, nc)
        ];
      } finally {
        _l.free(maps.cast());
      }
    } finally {
      malloc
        ..free(arr)
        ..free(out)
        ..free(ow)
        ..free(oh)
        ..free(nc);
    }
  }

  void close() {
    if (_h != nullptr) {
      _l.detectorDestroy(_h);
      _h = nullptr;
    }
  }
}

List<Candidate> _extract(TennisCoreLib l, Pointer<Uint8> heat, int hw, int hh,
    int fw, int fh, Pointer<Int32> n) {
  final p = l.extractCandidates(heat, hw, hh, fw, fh, n);
  final k = n.value;
  if (k == 0) {
    if (p != nullptr) l.free(p.cast());
    return const [];
  }
  if (p == nullptr) throw TennisCoreException(_lastError(l));
  final out = [
    for (var i = 0; i < k; i++) Candidate(p[3 * i], p[3 * i + 1], p[3 * i + 2])
  ];
  l.free(p.cast());
  return out;
}

/// Foveal re-detection (core_bind.roi_find) on gray frames -> (x, y, conf).
class RoiFinder {
  final TennisCoreLib _l;
  final Pointer<Double> _o = malloc<Double>(3);
  RoiFinder() : _l = _lib();

  (double, double, double)? find(NativeImage prev, NativeImage curr,
      NativeImage next, double px, double py, double radius) {
    final got = _l.roiFind(prev.ptr, curr.ptr, next.ptr, curr.w, curr.h, px,
        py, radius, _o, _o + 1, _o + 2);
    if (got == 0) return null;
    return (_o[0], _o[1], _o[2]);
  }

  void close() => malloc.free(_o);
}

/// Court calibration from one BGR frame (core_bind.core_detect_court).
CourtCalib detectCourt(NativeImage bgr) {
  final l = _lib();
  final j = _takeJson(l, l.detectCourt(bgr.ptr, bgr.w, bgr.h));
  if (j == null) throw TennisCoreException(_lastError(l));
  return CourtCalib.fromJson(j as Map<String, dynamic>);
}

/// Court calibration from several static-camera frames (median background,
/// players removed) — core_bind.core_calibrate_frames.
CourtCalib calibrateFrames(List<NativeImage> frames) {
  final l = _lib();
  final arr = malloc<Pointer<Uint8>>(frames.length);
  try {
    for (var i = 0; i < frames.length; i++) {
      arr[i] = frames[i].ptr;
    }
    final j = _takeJson(l,
        l.calibrateFrames(arr, frames.length, frames.first.w, frames.first.h));
    if (j == null) throw TennisCoreException(_lastError(l));
    return CourtCalib.fromJson(j as Map<String, dynamic>);
  } finally {
    malloc.free(arr);
  }
}
