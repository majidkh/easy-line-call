// Tracking screen (landscape).
//
// Video: playback and analysis run together — the video plays from the
// start while the reader feeds the engine, paced to the analysis frontier
// so playback never shows frames the engine hasn't analyzed yet, with ball
// dots/trails, bounce rings and the calibrated court drawn over it live.
// Live: the camera preview processes in real time into the same display.
//
// Right side, floating over the video: Challenge button, then the bounce
// list with timestamps. Tapping a bounce opens the challenge review for it.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:tennis_core/types.dart'
    show BounceCall, MuseUpdate;
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../engine/muse_bridge.dart';
import '../engine/muse_court.dart';
import '../engine/video_frames.dart';
import '../engine/vline_calibrate_types.dart';
import '../live/camera_convert.dart';
import '../live/frame_buffer.dart';
import 'challenge_page.dart';
import 'track_overlay.dart';
import 'court_overlay.dart';

class TrackPage extends StatefulWidget {
  final VlineCalibration calibration;
  final String? videoPath; // null → live camera feed
  final bool doubles; // which lines calls are judged on
  final CameraDescription? initialCamera; // live: chosen camera
  const TrackPage(
      {super.key,
      required this.calibration,
      this.videoPath,
      this.doubles = true,
      this.initialCamera});
  bool get live => videoPath == null;

  @override
  State<TrackPage> createState() => _TrackPageState();
}

class _TrackPageState extends State<TrackPage> {
  // Scan passes frames at most this often (clips above ~60 fps are thinned).
  static const int _readIntervalMs = 15;
  // Right overlay column geometry (also the court-tap exclusion zone).
  static const double _panelW = 264;
  static const double _panelM = 10;

  MuseScan? _scan;
  StreamSubscription<MuseUpdate>? _scanSub;
  List<double>? _hImg2Court;
  List<double>? _hCourt2Img;
  final int _procW = kMuseProcW;
  int _procH = 720;
  double _scanFps = 30;

  // Scan frame index → video/live time (ms). Grows during the scan.
  final List<double> _scanMs = [];
  MuseUpdate? _latest;
  bool _scanDone = false;
  double _scanProgress = 0; // video only (ms / duration)
  String? _error;

  // Video playback.
  VideoPlayerController? _player;
  double _videoDurMs = 0;
  double _playMs = 0;
  Timer? _playTimer;
  // Playback leads/lags the analysis frontier (ms). The player pauses
  // within [_pauseLeadMs] of unanalyzed video and resumes once the
  // engine is [_resumeLeadMs] ahead — hysteresis against flutter.
  static const double _pauseLeadMs = 400;
  static const double _resumeLeadMs = 1200;
  bool _waitingForScan = false;

  // Live camera.
  CameraController? _cam;
  List<CameraDescription> _cams = const [];
  int _camIdx = 0;
  bool _liveStreaming = false;
  final LiveBuffer _buffer = LiveBuffer();
  double _liveT0 = DateTime.now().millisecondsSinceEpoch.toDouble();

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    if (!museSupported) {
      setState(() => _error = museUnavailableReason);
      return;
    }
    final h = museHomographies(widget.calibration.projected,
        kMuseProcW / widget.calibration.frameW);
    if (h == null) {
      setState(() => _error = 'Court geometry is degenerate.');
      return;
    }
    // Both directions: the engine drops the court entirely unless it
    // gets the pair, and then every bounce comes back unjudged at 0,0 —
    // which the overlay reads as court center, i.e. all green.
    _hImg2Court = h.$1;
    _hCourt2Img = h.$2;
    if (widget.live) {
      _startLive();
    } else {
      _startVideo(widget.videoPath!);
    }
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    _player?.dispose();
    _stopLive();
    _scanSub?.cancel();
    _scan?.close();
    closeVideoReader();
    WakelockPlus.disable();
    super.dispose();
  }

  // ------------------------------------------------------------ video
  // Playback and analysis run together: the video plays from the start
  // while the reader feeds the engine as fast as it decodes, paced to the
  // analysis frontier (the player holds when it would outrun analyzed
  // frames, and resumes once the engine pulls ahead). Overlays show
  // everything analyzed up to the frame on screen, so balls, bounces and
  // trajectories appear live as the play reaches them.
  Future<void> _startVideo(String path) async {
    final t0 = DateTime.now();
    void mark(String m) => debugPrint(
        '[track] ${DateTime.now().difference(t0).inMilliseconds}ms $m');
    mark('open $path');
    _videoDurMs = await videoDurationMs(path);
    mark('duration ${_videoDurMs.round()}ms');
    if (!mounted) return;
    final player = createVideoController(path);
    try {
      await player.initialize();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not play this video.');
      return;
    }
    mark('player ready');
    if (!mounted) {
      player.dispose();
      return;
    }
    setState(() => _player = player);
    player.play();
    mark('playing');
    _playTimer = Timer.periodic(const Duration(milliseconds: 66), (_) {
      if (!mounted) return;
      final pos = player.value.position.inMilliseconds.toDouble();
      if (_videoDurMs > 0 && pos >= _videoDurMs) {
        player.pause(); // freeze on the last frame, overlays intact
      }
      // Pace playback to the analysis frontier: never show frames the
      // engine hasn't analyzed yet, so balls, bounces and trajectories
      // render live as the play reaches them.
      if (!_scanDone && _videoDurMs > 0 && pos < _videoDurMs) {
        final frontier = _frontierMs;
        if (player.value.isPlaying && pos > frontier - _pauseLeadMs) {
          player.pause();
          _waitingForScan = true;
        } else if (_waitingForScan && frontier - pos > _resumeLeadMs) {
          player.play();
          _waitingForScan = false;
        }
      } else if (_scanDone && _waitingForScan) {
        player.play();
        _waitingForScan = false;
      }
      setState(() {
        _playMs = pos;
      });
    });
    // The scan runs alongside playback — never blocks it.
    unawaited(_scanLoop(path, mark));
  }

  Future<void> _scanLoop(String path, void Function(String) mark) async {
    // cvColor: OpenCV-equivalent pixels (BT.601 from the raw YUV) instead
    // of colour-managed display frames, which the CoreImage BGRA path
    // renders video-range dark (~40/255 level shift), starving recovery.
    // The engine is tuned on OpenCV-equivalent pixels, same as
    // calibration. Exact parity is decoder-bound (VideoToolbox decodes
    // 10-bit HLG slightly cleaner than the dithered FFmpeg pixels the
    // recovery thresholds were tuned on), so adversarial clips can still
    // under-recover on the native path; bundling an FFmpeg reader would
    // close the remainder.
    final ok = await openVideoReader(path,
        startMs: 0,
        maxWidth: 1280,
        minIntervalMs: _readIntervalMs,
        cvColor: true);
    mark('reader open ok=$ok');
    if (!ok) {
      if (mounted) setState(() => _error = 'Could not decode this video.');
      return;
    }
    // Buffer the first frames to measure the real frame rate before the
    // engine (which needs fps up front) starts.
    final buffered = <(Uint8List, int, int, double)>[];
    try {
      while (buffered.length < 3) {
        final rf = await nextVideoFrame();
        if (rf == null) break;
        buffered.add(rf);
      }
      if (buffered.isEmpty) {
        if (mounted) setState(() => _error = 'No frames in this video.');
        return;
      }
      final b0 = buffered.first, b1 = buffered.last;
      if (buffered.length >= 3 && b1.$4 > b0.$4) {
        _scanFps = 2000 / (b1.$4 - b0.$4);
      }
      _procH = b0.$3 * _procW ~/ b0.$2;
      mark('first frames ${_scanFps.toStringAsFixed(1)}fps ${_procW}x$_procH');
      _scan = await museStartScan(
        fps: _scanFps,
        procW: _procW,
        procH: _procH,
        hImg2Court: _hImg2Court,
        hCourt2Img: _hCourt2Img,
      );
      mark('engine ready');
      var nUpdates = 0;
      _scanSub = _scan!.updates.listen((u) {
        if (!mounted) return;
        if (nUpdates == 0) {
          mark('first update frontier=${u.frontier} '
              'tracks=${u.tracks.length} rallies=${u.rallies.length}');
        }
        nUpdates++;
        setState(() => _latest = u);
      }, onError: (Object e) {
        if (!mounted) return;
        setState(() => _error = '$e');
      });
      for (final rf in buffered) {
        _pushScanFrame(rf.$1, rf.$2, rf.$3, rf.$4);
      }
      var lastProgress = 0;
      while (true) {
        final rf = await nextVideoFrame();
        if (rf == null || !mounted) break;
        _pushScanFrame(rf.$1, rf.$2, rf.$3, rf.$4);
        // Throttled progress — the header % ticks ~4×/s, not per frame.
        final now = DateTime.now().millisecondsSinceEpoch;
        if (_videoDurMs > 0 && now - lastProgress > 250) {
          lastProgress = now;
          if (mounted) {
            setState(() => _scanProgress =
                (_scanMs.isEmpty ? 0 : _scanMs.last / _videoDurMs)
                    .clamp(0.0, 1.0)
                    .toDouble());
          }
        }
      }
      _scan?.flush();
      // Wait for the engine's final (done) update.
      await _scan?.updates.firstWhere((u) => u.done);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      await closeVideoReader();
    }
    if (!mounted) return;
    setState(() {
      _scanProgress = 1;
      _scanDone = true;
    });
  }

  void _pushScanFrame(Uint8List raw, int w, int h, double ms) {
    _scanMs.add(ms < 0 ? _scanMs.length * 1000 / _scanFps : ms);
    _scan?.push(raw, w, h);
  }

  // ------------------------------------------------------------ live camera
  Future<void> _startLive() async {
    if (kIsWeb) {
      setState(() => _error = 'Live tracking is not supported on web.');
      return;
    }
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw StateError('no camera');
      _cams = cams;
      // Prefer the camera chosen upstream (matched by name); else back.
      final want = widget.initialCamera?.name;
      _camIdx = want == null ? -1 : cams.indexWhere((c) => c.name == want);
      if (_camIdx < 0) {
        _camIdx = cams.indexWhere(
            (c) => c.lensDirection == CameraLensDirection.back);
      }
      if (_camIdx < 0) _camIdx = 0;
      final controller = CameraController(_cams[_camIdx],
          ResolutionPreset.high,
          enableAudio: false,
          imageFormatGroup: ImageFormatGroup.yuv420);
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      final preview = controller.value.previewSize ?? const Size(1280, 720);
      _procH = preview.height.toInt() * _procW ~/ preview.width.toInt();
      _scan = await museStartScan(
        fps: _scanFps,
        procW: _procW,
        procH: _procH,
        hImg2Court: _hImg2Court,
        hCourt2Img: _hCourt2Img,
      );
      _scanSub = _scan!.updates.listen((u) {
        if (!mounted) return;
        setState(() => _latest = u);
      }, onError: (Object e) {
        if (!mounted) return;
        setState(() => _error = '$e');
      });
      setState(() {
        _cam = controller;
        _liveStreaming = true;
      });
      _liveN = 0;
      _liveT0wall = 0;
      await controller.startImageStream(_onLiveImage);
    } catch (e) {
      if (mounted) setState(() => _error = 'Live camera is not available.');
    }
  }

  int _liveN = 0;
  double _liveT0wall = 0;

  void _onLiveImage(CameraImage img) {
    if (!mounted || !_liveStreaming) return;
    final conv = convertCameraImage(img);
    if (conv == null) return;
    final now = DateTime.now().millisecondsSinceEpoch.toDouble();
    if (_liveN == 0) {
      _liveT0 = now;
      _liveT0wall = now;
    }
    final stamp = now - _liveT0;
    _scanMs.add(stamp);
    _scan?.push(conv.bytes, conv.width, conv.height);
    // The challenge buffer keeps every 3rd frame (~10 fps) downscaled.
    if (_liveN % 3 == 0) {
      _buffer.add(conv.bytes, conv.width, conv.height, stamp);
    }
    _liveN++;
    if (_liveN % 30 == 0) {
      final dt = now - _liveT0wall;
      if (dt > 0) _scanFps = 30000 / dt;
      _liveT0wall = now;
    }
  }

  /// Swap front/back camera mid-stream. The scan clock, buffer and bounces
  /// keep running — only the frame source changes.
  Future<void> _switchCamera() async {
    if (!widget.live || _cams.length < 2) return;
    final next = (_camIdx + 1) % _cams.length;
    final controller = CameraController(_cams[next], ResolutionPreset.high,
        enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
    try {
      await controller.initialize();
    } catch (_) {
      return;
    }
    if (!mounted) {
      controller.dispose();
      return;
    }
    final old = _cam;
    _liveStreaming = false;
    try {
      await old?.stopImageStream();
    } catch (_) {}
    await old?.dispose();
    setState(() {
      _cam = controller;
      _camIdx = next;
      _liveStreaming = true;
    });
    try {
      await controller.startImageStream(_onLiveImage);
    } catch (_) {
      if (mounted) setState(() => _error = 'Live camera is not available.');
    }
  }

  Future<void> _stopLive() async {
    _liveStreaming = false;
    try {
      await _cam?.stopImageStream();
    } catch (_) {}
    await _cam?.dispose();
    _cam = null;
  }

  // ------------------------------------------------------------ derived data
  /// Video time (ms) analyzed so far — the scan frontier — or 0 before
  /// the first engine update. Playback never runs past this.
  double get _frontierMs {
    final u = _latest;
    if (u == null || u.frontier <= 0 || _scanMs.isEmpty) return 0;
    return _scanMs[math.min(u.frontier, _scanMs.length) - 1];
  }

  /// Scan index currently shown (playback position, or the live frontier).
  int get _shownIdx {
    if (_scanMs.isEmpty) return 0;
    if (widget.live) return _scanMs.length - 1;
    var lo = 0, hi = _scanMs.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_scanMs[mid] <= _playMs) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  List<BounceCall> get _bounces {
    final u = _latest;
    if (u == null) return const [];
    final out = <BounceCall>[];
    for (final r in u.rallies) {
      out.addAll(r.bounces);
    }
    out.sort((a, b) => a.frame.compareTo(b.frame));
    return out;
  }

  double _bounceMs(BounceCall b) =>
      (b.frame >= 0 && b.frame < _scanMs.length)
          ? _scanMs[b.frame]
          : b.frame * 1000 / _scanFps;

  bool _bounceIn(BounceCall b) =>
      bounceIsIn(b, doubles: widget.doubles);

  Offset _bounceNorm(BounceCall b) =>
      Offset((b.x / _procW).clamp(0.0, 1.0), (b.y / _procH).clamp(0.0, 1.0));

  void _openChallenge({BounceCall? bounce}) {
    if (bounce != null) {
      // A tapped bounce reviews directly (magnified + AI-upscaled replay).
      final ms = _bounceMs(bounce), norm = _bounceNorm(bounce);
      final label =
          bounceReviewLabel(bounce, isIn: _bounceIn(bounce));
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => widget.live
              ? ChallengeReviewPage.live(
                  buffer: _buffer, ms: ms, norm: norm, callLabel: label)
              : ChallengeReviewPage.video(
                  videoPath: widget.videoPath!,
                  ms: ms,
                  norm: norm,
                  callLabel: label),
        ),
      );
      return;
    }
    // The Challenge button browses the last two minutes of footage; tapping
    // the footage reviews that moment for calls the detector missed.
    final entryMs =
        widget.live ? (_scanMs.isEmpty ? 0.0 : _scanMs.last) : _playMs;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => widget.live
            ? ChallengePage.live(buffer: _buffer, entryMs: entryMs)
            : ChallengePage.video(
                videoPath: widget.videoPath!, entryMs: entryMs),
      ),
    );
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.live ? 'Live tracking' : 'Video tracking',
            style: const TextStyle(fontSize: 17)),
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
            : _mainView(),
      ),
    );
  }

  void _tapCourt(
      Offset local, Size size, List<(BounceCall, int)> court) {
    // The right panel handles its own taps.
    if (local.dx > size.width - _panelW - _panelM) return;
    final hit = tapBounce(local, size, _procW, _procH,
        [for (final e in court) e.$1]);
    if (hit != null) _openChallenge(bounce: hit);
  }

  Widget _mainView() {
    final idx = _shownIdx;
    final bounces = _bounces;
    // Numbered rings on the court (1 = newest, last 10) — tappable.
    // Live calls older than the 2-minute challenge window expire.
    final nowMs = widget.live && _scanMs.isNotEmpty ? _scanMs.last : null;
    final court = numberedBounces(bounces, idx, 10,
        widget.live ? _scanMs : null, nowMs);
    // Full-bleed video for small phone screens; the Challenge button and
    // bounce list float over it, half transparent.
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.live) _livePicture() else _filePicture(),
        // Court lines under the ball overlay.
        Positioned.fill(
          child: CourtOverlay(widget.calibration,
              cover: true, doubles: widget.doubles),
        ),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (d) => _tapCourt(d.localPosition, size, court),
                child: CustomPaint(
                    painter: TrackOverlayPainter(_latest, idx, _procW, _procH,
                        court, _bounceIn)),
              );
            },
          ),
        ),
        Positioned(
          top: _panelM,
          right: _panelM,
          bottom: _panelM,
          width: _panelW,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 40,
                child: ElevatedButton.icon(
                  onPressed: () => _openChallenge(),
                  icon:
                      const Icon(Icons.flag_outlined, size: 18),
                  label: const Text('Challenge',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                ),
              ),
              // No bounce list under Challenge — the numbered court rings
              // are the bounce UI (tap a ring to review). Only the
              // analysis progress shows, while a video scan is running.
              if (_scanStatus() != null)
                Padding(
                  padding:
                      const EdgeInsets.only(left: 8, top: 6),
                  child: Text(_scanStatus()!,
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          shadows: [_shadow])),
                ),
              const Spacer(flex: 1),
            ],
          ),
        ),
        // Front/back camera switch (live, when the device has both).
        if (widget.live && _cams.length >= 2)
          Positioned(
            left: _panelM,
            bottom: _panelM,
            child: FloatingActionButton.small(
              heroTag: 'camSwitch',
              tooltip: 'Switch camera',
              onPressed: _switchCamera,
              child: const Icon(Icons.cameraswitch_outlined),
            ),
          ),
      ],
    );
  }

  Widget _livePicture() {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    final preview = cam.value.previewSize;
    final aspect =
        preview == null || preview.height == 0 ? 16 / 9 : preview.width / preview.height;
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: aspect * 100,
        height: 100,
        child: CameraPreview(cam),
      ),
    );
  }

  Widget _filePicture() {
    final player = _player;
    if (player == null || !player.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: player.value.size.width,
        height: player.value.size.height,
        child: VideoPlayer(player),
      ),
    );
  }

  // Over bare video, so everything gets a shadow for readability.
  static const _shadow = Shadow(
      color: Colors.black, blurRadius: 4, offset: Offset(0, 1));

  // Analysis progress line (video scans only), or null when there is
  // nothing to report — the panel otherwise holds just the Challenge
  // button. Before the engine exists the scan hasn't started (model
  // still loading) — say so instead of a stuck "analyzing 0%".
  String? _scanStatus() {
    if (widget.live || _scanDone) return null;
    var s = _scan == null
        ? 'Loading ball model…'
        : 'Analyzing ${(_scanProgress * 100).round()}%';
    if (_waitingForScan) s += ' · holding…';
    return s;
  }
}


/// Nearest bounce ring to a court tap (screen px), within [slop], or null.
/// [size] is the full-bleed view ([coverMap] mapping).
BounceCall? tapBounce(Offset tap, Size size, int procW, int procH,
    List<BounceCall> bounces, [double slop = 28]) {
  if (procW <= 0 || procH <= 0) return null;
  BounceCall? best;
  var bestD = slop;
  for (final b in bounces) {
    final d = (coverMap(b.x, b.y, size, procW, procH) - tap).distance;
    if (d < bestD) {
      bestD = d;
      best = b;
    }
  }
  return best;
}
