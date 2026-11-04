// Challenge screens (landscape).
//
// ChallengePage: full-screen footage browser over the two minutes before
// the challenge moment — a full-width slider overlaid at the bottom scrubs
// the cached footage; tapping the footage opens a ChallengeReviewPage for
// that moment (magnified + AI-upscaled replay, as if a bounce were there),
// for calls the detector missed. Back returns to tracking.
//
// ChallengeReviewPage: the zoomed review player — half a second before to
// half a second after the challenged moment, magnified around the point so
// the call can be verified by eye, with scrub and slow motion down to 1/16x.
// Playback always starts half a second before the moment at 1/16×, and
// only after every clip frame is upscaled on-device behind an
// "Upscaling… NN%" gate: one MetalFX GPU pass to 2× per frame (about a
// second for the whole review), shown at 4× with a bicubic second step —
// display magnification stays capped at 4× everywhere, since magnifying
// past the tile's real detail turns reviews black/dark. Where the
// device upscaler is unavailable the review falls back to bicubic. Back
// returns to the footage browser (manual reviews) or to tracking
// (bounce taps).
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../engine/fx_upscale.dart';
import '../engine/video_frames.dart';
import '../live/frame_buffer.dart';

// ---------------------------------------------------------------------------
// Footage browser: full-screen footage, two-minute slider, tap to review.
// ---------------------------------------------------------------------------
class ChallengePage extends StatefulWidget {
  final String? videoPath; // null → live buffer
  final LiveBuffer? buffer;
  final double entryMs; // footage time when Challenge was tapped

  const ChallengePage.video({
    super.key,
    required String this.videoPath,
    required this.entryMs,
  }) : buffer = null;

  const ChallengePage.live({
    super.key,
    required LiveBuffer this.buffer,
    required this.entryMs,
  }) : videoPath = null;

  bool get live => videoPath == null;

  @override
  State<ChallengePage> createState() => _ChallengePageState();
}

class _ChallengePageState extends State<ChallengePage> {
  static const double _windowMs = 120000; // last two minutes
  static const int _stillWidth = 1280; // scrub stills (video path)

  double _ms = 0; // slider position (footage time)
  ui.Image? _still; // decoded frame nearest the slider (both paths)
  double _stillMs = 0;
  bool _decoding = false;
  double? _queuedMs;
  String? _error;

  double get _minMs =>
      widget.entryMs - _windowMs < 0 ? 0 : widget.entryMs - _windowMs;
  double get _maxMs => widget.entryMs;

  @override
  void initState() {
    super.initState();
    _ms = widget.entryMs;
    _showStill(_ms);
  }

  @override
  void dispose() {
    _still?.dispose();
    super.dispose();
  }

  Future<void> _seekTo(double ms) async {
    setState(() => _ms = ms);
    _showStill(ms);
  }

  // Frame-by-frame scrub over decoded stills (no player seeks): every
  // slider position shows its exact frame — from the live buffer on the
  // live path, grabbed from the file on the video path. One decode in
  // flight, always to the latest request: slider drags fire faster than
  // frames decode, and coalescing keeps scrubbing smooth.
  Future<void> _showStill(double ms) async {
    if (_decoding) {
      _queuedMs = ms;
      return;
    }
    _decoding = true;
    try {
      var target = ms;
      while (mounted) {
        Uint8List? bytes;
        double atMs = target;
        if (widget.live) {
          final f = _nearestBuffered(target);
          if (f == null) break;
          bytes = f.jpeg;
          atMs = f.ms;
        } else {
          bytes = await grabVideoFrame(widget.videoPath!, target,
              maxWidth: _stillWidth);
          if (bytes == null) break;
        }
        final img = await _decode(bytes);
        if (!mounted) {
          img.dispose();
          return;
        }
        setState(() {
          _still?.dispose();
          _still = img;
          _stillMs = atMs;
        });
        if (_queuedMs == null) break;
        target = _queuedMs!;
        _queuedMs = null;
      }
    } catch (_) {
      if (mounted && _still == null) {
        setState(() => _error = 'Could not load this footage.');
      }
    } finally {
      _decoding = false;
    }
  }

  BufferedFrame? _nearestBuffered(double ms) {
    final f = widget.buffer?.frames;
    if (f == null || f.isEmpty) return null;
    var best = f.first;
    var bestD = (best.ms - ms).abs();
    for (final c in f) {
      final d = (c.ms - ms).abs();
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }

  Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    return (await codec.getNextFrame()).image;
  }

  void _tapFootage(TapDownDetails d, Size view, Size content) {
    final norm = coverNorm(d.localPosition, view, content);
    final ms = _stillMs; // the frame on screen (both paths decode it)
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => widget.live
            ? ChallengeReviewPage.live(
                buffer: widget.buffer!, ms: ms, norm: norm)
            : ChallengeReviewPage.video(
                videoPath: widget.videoPath!, ms: ms, norm: norm),
      ),
    );
  }

  String _fmtClock(double ms) {
    final t = (ms / 1000).floor();
    final d = ((ms % 1000) / 100).floor();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}.$d';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Challenge', style: TextStyle(fontSize: 17)),
      ),
      body: SafeArea(
        child: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70)),
                ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  _footage(),
                  Positioned(left: 0, right: 0, bottom: 0, child: _slider()),
                ],
              ),
      ),
    );
  }

  Widget _footage() {
    final still = _still;
    if (still == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final content = Size(still.width.toDouble(), still.height.toDouble());
    return LayoutBuilder(
      builder: (context, constraints) {
        final view = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _tapFootage(d, view, content),
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: content.width,
              height: content.height,
              child: RawImage(image: still, fit: BoxFit.cover),
            ),
          ),
        );
      },
    );
  }

  Widget _slider() {
    final lo = _minMs, hi = _maxMs > lo ? _maxMs : lo + 1;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.purpleAccent,
              thumbColor: Colors.purpleAccent,
              inactiveTrackColor: Colors.white24,
            ),
            child: Slider(
              value: _ms.clamp(lo, hi),
              min: lo,
              max: hi,
              onChanged: _seekTo,
            ),
          ),
          Text(
            'Tap the footage to review · ${_fmtClock(_ms)} · last 2 min',
            style:
                const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Review player: magnified + AI-upscaled replay of one challenged moment.
// ---------------------------------------------------------------------------
class ChallengeReviewPage extends StatefulWidget {
  final String? videoPath; // null → live buffer
  final LiveBuffer? buffer;
  final double ms; // challenged moment (footage time)
  final Offset norm; // challenged point (normalized footage coords)
  final String? callLabel; // 'IN'/'OUT'/'UNCERTAIN' for a tap review

  const ChallengeReviewPage.video({
    super.key,
    required String this.videoPath,
    required this.ms,
    required this.norm,
    this.callLabel,
  }) : buffer = null;

  const ChallengeReviewPage.live({
    super.key,
    required LiveBuffer this.buffer,
    required this.ms,
    required this.norm,
    this.callLabel,
  }) : videoPath = null;

  bool get live => videoPath == null;

  @override
  State<ChallengeReviewPage> createState() => _ChallengeReviewPageState();
}

class _ChallengeReviewPageState extends State<ChallengeReviewPage> {
  static const double _windowMs = 500; // ± this around the moment
  static const int _reviewW = 1100; // review extraction width
  static const int _stepReview = 33; // ~30 fps spacing
  static const int _maxFrames = 32;
  // Display magnification is capped at 4× everywhere (near and far
  // court alike): the SR tile carries 4× real detail, and magnifying
  // past it over-stretches the tile and turns reviews black/dark.
  static const double _zoomNear = 4;
  static const double _zoomFar = 4;
  double _zoom = _zoomNear;
  static const _speeds = [1.0, 0.5, 0.25, 0.125, 0.0625];
  static const _speedLabels = ['1×', '1/2×', '1/4×', '1/8×', '1/16×'];
  // Largest SR input crop (px, pre-margin). At 4× zoom an 1100px review
  // frame needs a ~275px crop, so the gate sits above that.
  static const double _kSrMaxCrop = 320;

  final List<ui.Image> _frames = [];
  final List<double> _frameMs = [];
  int _idx = 0;
  int _speedIdx = 4;
  bool _playing = false;
  bool _loading = false;
  bool _hasClip = false;
  // Upscale gate: the review shows only after every clip frame is
  // AI-upscaled (or SR proves unavailable), with a % indicator meanwhile.
  bool _upscaling = false;
  double _upscalePct = 0;
  Timer? _timer;

  final List<ui.Image?> _srTiles = [];
  ui.Rect? _srSrc;
  bool _srRunning = false;

  @override
  void initState() {
    super.initState();
    _zoom = _zoomForY(widget.norm.dy);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadClip();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final t in _srTiles) {
      t?.dispose();
    }
    for (final f in _frames) {
      f.dispose();
    }
    super.dispose();
  }

  /// Magnification for a point at normalized image height [y], capped
  /// at 4× (see [_zoomNear]): never past the SR tile's real detail.
  static double _zoomForY(double y) =>
      challengeZoomForY(y, _zoomNear, _zoomFar);

  Future<void> _loadClip() async {
    _timer?.cancel();
    for (final t in _srTiles) {
      t?.dispose();
    }
    for (final f in _frames) {
      f.dispose();
    }
    setState(() {
      _frames.clear();
      _frameMs.clear();
      _srTiles.clear();
      _srSrc = null;
      _idx = 0;
      _playing = false;
      _loading = true;
      _hasClip = false;
      _upscaling = false;
      _upscalePct = 0;
    });
    try {
      if (widget.live) {
        await _loadLive(widget.ms);
      } else {
        await _loadVideo(widget.videoPath!, widget.ms);
      }
    } catch (_) {}
    if (!mounted) return;
    if (_frames.isEmpty) {
      setState(() {
        _loading = false;
        _hasClip = false;
      });
      return;
    }
    _srTiles.addAll(List<ui.Image?>.filled(_frames.length, null));
    // Every review starts half a second before the moment (frame 0 of the
    // ±0.5 s clip) at the slowest speed.
    setState(() {
      _idx = 0;
      _speedIdx = _speeds.length - 1;
    });
    // Upscale first, show after: the review never plays bicubic frames
    // while SR catches up. Unavailable SR (web, failed model, oversize
    // crop) skips the wait and the magnifier falls back to bicubic.
    await _upscaleAll();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _upscaling = false;
      _hasClip = true;
    });
    _play();
  }

  Future<void> _loadVideo(String path, double ms) async {
    final start = ms - _windowMs < 0 ? 0.0 : ms - _windowMs;
    final endMs = ms + _windowMs;
    final ok = await openVideoReader(path,
        startMs: start, maxWidth: _reviewW, minIntervalMs: _stepReview);
    try {
      if (ok) {
        while (_frames.length < _maxFrames) {
          final rf = await nextVideoFrame();
          if (rf == null || !mounted) break;
          _frames.add(await _imageFromRaw(rf.$1, rf.$2, rf.$3));
          _frameMs.add(rf.$4);
          if (rf.$4 >= 0 && rf.$4 >= endMs) break;
        }
      } else {
        for (var t = start;
            t <= endMs && _frames.length < _maxFrames;
            t += _stepReview) {
          final jb = await grabVideoFrame(path, t, maxWidth: _reviewW);
          if (jb != null && mounted) {
            _frames.add(await _decode(jb));
            _frameMs.add(t);
          }
          if (!mounted) break;
        }
      }
    } finally {
      await closeVideoReader();
    }
  }

  Future<void> _loadLive(double ms) async {
    final buf = widget.buffer;
    if (buf == null) return;
    final slice = buf.window(ms, _windowMs);
    for (final f in slice.take(_maxFrames)) {
      if (!mounted) break;
      _frames.add(await _decode(f.jpeg));
      _frameMs.add(f.ms);
    }
  }

  Future<ui.Image> _imageFromRaw(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    return (await codec.getNextFrame()).image;
  }

  // ------------------------------------------------------------ SR upscale
  ui.Rect? _srCropRect(ui.Image frame) {
    final iw = frame.width.toDouble(), ih = frame.height.toDouble();
    if (iw / _zoom > _kSrMaxCrop) return null;
    var side = iw / _zoom * 1.1;
    if (side < 50) side = 50;
    if (side > iw) side = iw;
    if (side > ih) side = ih;
    var cx = widget.norm.dx * iw, cy = widget.norm.dy * ih;
    cx = cx.clamp(side / 2, iw - side / 2);
    cy = cy.clamp(side / 2, ih - side / 2);
    return ui.Rect.fromCenter(
        center: ui.Offset(cx, cy), width: side, height: side);
  }

  // 2× device-built-in upscale (MetalFX, one GPU pass per frame) of
  // every clip frame, in playback order from the half-second lead-in,
  // driving the "Upscaling… NN%" gate — the whole review upscales in
  // about a second. The magnifier shows each 2× tile at 4× with a
  // bicubic second step. Frames whose tile fails stay null and the
  // magnifier draws them bicubic.
  Future<void> _upscaleAll() async {
    if (_srRunning || !mounted || _frames.isEmpty) return;
    final n = _frames.length;
    final src = _srCropRect(_frames[0]);
    // Oversize crop (past the 4× display cap's real detail): skip the
    // wait, the magnifier falls back to bicubic for the whole review.
    if (src == null) return;
    _srSrc = src;
    _srRunning = true;
    setState(() {
      _upscaling = true;
      _upscalePct = 0;
    });
    try {
      for (var i = 0; i < n; i++) {
        if (!mounted) return;
        if (i < _srTiles.length && _srTiles[i] != null) {
          setState(() => _upscalePct = upscaleProgress(i + 1, n, 0));
          continue;
        }
        final patch = await _cropImage(_frames[i], src);
        ui.Image? up;
        final bd =
            await patch.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (bd != null) {
          final out = await fxUpscale2x(
              bd.buffer.asUint8List(), patch.width, patch.height);
          if (out != null && out.w > 0 && out.h > 0 && mounted) {
            up = await _imageFromBgra(out.bgra, out.w, out.h);
          }
        }
        patch.dispose();
        if (!mounted) {
          up?.dispose();
          return;
        }
        setState(() {
          if (up != null && i < _srTiles.length) _srTiles[i] = up;
          _upscalePct = upscaleProgress(i + 1, n, 0);
        });
      }
    } catch (_) {
    } finally {
      _srRunning = false;
    }
  }

  Future<ui.Image> _imageFromBgra(Uint8List bgra, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(bgra, w, h, ui.PixelFormat.bgra8888, c.complete);
    return c.future;
  }

  Future<ui.Image> _cropImage(ui.Image src, ui.Rect r) async {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawImageRect(
      src,
      r,
      ui.Rect.fromLTWH(0, 0, r.width, r.height),
      ui.Paint()..filterQuality = ui.FilterQuality.none,
    );
    final pic = rec.endRecording();
    try {
      return await pic.toImage(r.width.round(), r.height.round());
    } finally {
      pic.dispose();
    }
  }

  // ------------------------------------------------------------ playback
  void _play() {
    if (_frames.isEmpty) return;
    _timer?.cancel();
    final intervalMs = (_stepReview / _speeds[_speedIdx]).round();
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      if (!mounted) return;
      setState(() => _idx = (_idx + 1) % _frames.length);
    });
    setState(() => _playing = true);
  }

  void _pause() {
    _timer?.cancel();
    setState(() => _playing = false);
  }

  void _step(int d) {
    _pause();
    if (_frames.isNotEmpty) {
      setState(() => _idx = (_idx + d).clamp(0, _frames.length - 1));
    }
  }

  void _cycleSpeed() {
    setState(() => _speedIdx = (_speedIdx + 1) % _speeds.length);
    if (_playing) _play();
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Challenge', style: TextStyle(fontSize: 17)),
      ),
      body: SafeArea(child: _reviewView()),
    );
  }

  Widget _reviewView() {
    if (_loading) {
      // Two gated phases: clip extraction, then the 4× on-device upscale
      // with a live percentage — playback starts only after both.
      final upscaling = _upscaling;
      final pct = (_upscalePct * 100).round().clamp(0, 100);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(
                color: Colors.purpleAccent),
            const SizedBox(height: 14),
            Text(
              upscaling ? 'Upscaling… $pct%' : 'Loading clip…',
              style: const TextStyle(
                  color: Colors.white70, fontSize: 16),
            ),
            if (upscaling) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: 220,
                child: LinearProgressIndicator(
                  value: _upscalePct.clamp(0.0, 1.0),
                  color: Colors.purpleAccent,
                  backgroundColor: Colors.white24,
                ),
              ),
            ],
          ],
        ),
      );
    }
    if (!_hasClip) {
      return const Center(
        child: Text('Could not load a clip for this moment.',
            style: TextStyle(color: Colors.white38)),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _Magnifier(
                _frames[_idx],
                widget.norm,
                _zoom,
                srTile:
                    _idx < _srTiles.length ? _srTiles[_idx] : null,
                srSrc: _srSrc,
              ),
            ),
            if (_idx < _srTiles.length && _srTiles[_idx] != null)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text('AI ×2',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70)),
                ),
              ),
            if (widget.callLabel != null)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(widget.callLabel!,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: callChipColor(widget.callLabel))),
                ),
              ),
            Positioned(left: 0, right: 0, bottom: 0, child: _controls()),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.purpleAccent,
              thumbColor: Colors.purpleAccent,
              inactiveTrackColor: Colors.white24,
            ),
            child: Slider(
              value: _idx.toDouble(),
              min: 0,
              max: (_frames.length - 1).toDouble(),
              onChanged: (v) {
                _pause();
                setState(() => _idx = v.round());
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                  onPressed: () => _step(-100000),
                  icon: const Icon(Icons.first_page, color: Colors.white)),
              IconButton(
                  onPressed: () => _step(-1),
                  icon:
                      const Icon(Icons.chevron_left, color: Colors.white)),
              IconButton(
                onPressed: _playing ? _pause : _play,
                icon: Icon(_playing ? Icons.pause : Icons.play_arrow,
                    color: Colors.white, size: 34),
              ),
              IconButton(
                  onPressed: () => _step(1),
                  icon: const Icon(Icons.chevron_right,
                      color: Colors.white)),
              IconButton(
                  onPressed: () => _step(100000),
                  icon:
                      const Icon(Icons.last_page, color: Colors.white)),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _cycleSpeed,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: Colors.purpleAccent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color:
                            Colors.purpleAccent.withValues(alpha: 0.5)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.slow_motion_video,
                        size: 16, color: Colors.purpleAccent),
                    const SizedBox(width: 6),
                    Text(_speedLabels[_speedIdx],
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text('frame ${_idx + 1}/${_frames.length}',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
    );
  }
}

/// Tap position under a BoxFit.cover render of [content] in [view], as a
/// normalized (0..1) footage point (edges crop under cover, so the mapping
/// accounts for the centered overdraw instead of dividing by the view).
Offset coverNorm(Offset local, Size view, Size content) {
  if (content.width <= 0 ||
      content.height <= 0 ||
      view.width <= 0 ||
      view.height <= 0) {
    return const Offset(0.5, 0.5);
  }
  final s =
      math.max(view.width / content.width, view.height / content.height);
  final dw = content.width * s, dh = content.height * s;
  final ox = (view.width - dw) / 2, oy = (view.height - dh) / 2;
  return Offset(
    ((local.dx - ox) / dw).clamp(0.0, 1.0),
    ((local.dy - oy) / dh).clamp(0.0, 1.0),
  );
}

/// Review magnification for a point at normalized image height [y],
/// lerped between [zoomNear] (low in frame) and [zoomFar] (high in
/// frame, far court) across the 0.35..0.75 pivots.
double challengeZoomForY(double y, double zoomNear, double zoomFar) {
  const lo = 0.35, hi = 0.75; // far .. near pivots
  final t = (hi - y.clamp(lo, hi)) / (hi - lo);
  return zoomNear + (zoomFar - zoomNear) * t;
}

/// Aggregated upscale progress for the review gate: [done] of [total]
/// clip frames fully upscaled plus the in-flight frame's [current] 0..1
/// tile fraction — the "Upscaling… NN%" indicator. Clamps instead of
/// throwing on degenerate input.
double upscaleProgress(int done, int total, double current) {
  if (total <= 0) return 1;
  return ((done + current.clamp(0.0, 1.0)) / total).clamp(0.0, 1.0);
}

/// Call-chip color for a review [label]: IN green, OUT red, anything
/// else ('UNCERTAIN') amber — never red for undecided calls.
Color callChipColor(String? label) => label == 'IN'
    ? Colors.greenAccent
    : (label == 'OUT' ? Colors.redAccent : Colors.amberAccent);

/// [zoom]x magnified view around [norm] (normalized). Draws from the
/// AI-upscaled [srTile] when it covers the crop, else bicubic.
class _Magnifier extends CustomPainter {
  final ui.Image img;
  final Offset norm;
  final double zoom;
  final ui.Image? srTile;
  final Rect? srSrc;
  _Magnifier(this.img, this.norm, this.zoom, {this.srTile, this.srSrc});

  @override
  void paint(Canvas canvas, Size size) {
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    var cw = iw / zoom;
    var ch = cw * size.height / size.width;
    if (ch > ih) {
      ch = ih;
      cw = ch * size.width / size.height;
    }
    var l = norm.dx * iw - cw / 2;
    var t = norm.dy * ih - ch / 2;
    l = l.clamp(0.0, iw - cw);
    t = t.clamp(0.0, ih - ch);
    final paint = Paint()..filterQuality = FilterQuality.high;
    final tile = srTile, src = srSrc;
    if (tile != null &&
        src != null &&
        l >= src.left - 0.5 &&
        t >= src.top - 0.5 &&
        l + cw <= src.right + 0.5 &&
        t + ch <= src.bottom + 0.5) {
      final s = tile.width / src.width;
      canvas.drawImageRect(
        tile,
        Rect.fromLTWH((l - src.left) * s, (t - src.top) * s, cw * s, ch * s),
        Offset.zero & size,
        paint,
      );
    } else {
      canvas.drawImageRect(
          img, Rect.fromLTWH(l, t, cw, ch), Offset.zero & size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _Magnifier old) =>
      old.img != img ||
      old.norm != norm ||
      old.zoom != zoom ||
      old.srTile != srTile ||
      old.srSrc != srSrc;
}
