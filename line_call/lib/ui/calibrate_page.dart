// Calibration screen (landscape).
//
// Video: scrub to a frame with the slider, tap Calibrate — the court is
// fitted (muse2 engine, or the classical fallback where the engine isn't
// built) and drawn over the frame, then Confirm or Recalibrate.
// Live: the camera preview fills the frame view; Calibrate freezes the
// current frame and fits the court on it, then Confirm or Recalibrate.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../engine/muse_bridge.dart';
import '../engine/muse_court.dart';
import '../engine/video_frames.dart';
import '../engine/vline_calibrate.dart';
import 'court_overlay.dart';
import 'track_page.dart';

enum _Stage { pick, busy, result }

class CalibratePage extends StatefulWidget {
  final String? videoPath; // null → live camera feed
  final bool doubles; // which lines calls are judged on downstream
  final CameraDescription? camera; // live: chosen camera (null → back)
  const CalibratePage.video(
      {super.key, required String this.videoPath, this.doubles = true})
      : camera = null;
  const CalibratePage.live(
      {super.key, this.doubles = true, this.camera})
      : videoPath = null;
  bool get live => videoPath == null;

  @override
  State<CalibratePage> createState() => _CalibratePageState();
}

class _CalibratePageState extends State<CalibratePage> {
  CameraController? _cam;
  CameraDescription? _activeCamera;
  bool _cameraReady = false;
  String? _cameraError;

  _Stage _stage = _Stage.pick;
  Uint8List? _frameBytes; // frame shown in the view (scrub / frozen / still)
  VlineCalibration? _result;
  String _message = '';

  // Video scrub state.
  double _videoDurMs = 0;
  double _posMs = 0;
  double? _pendingMs; // coalesces slider drags into one grab at a time
  bool _grabbing = false;

  final _picker = ImagePicker();

  bool get _accepted => (_result?.projected.length ?? 0) == 10;

  @override
  void initState() {
    super.initState();
    if (widget.live) {
      _initCamera();
    } else {
      _startScrub(widget.videoPath!);
    }
  }

  @override
  void dispose() {
    _cam?.dispose();
    releaseVideoFrameResources();
    super.dispose();
  }

  // ------------------------------------------------------------ camera/live
  Future<void> _initCamera() async {
    if (kIsWeb) {
      setState(() =>
          _cameraError = 'Live camera is not supported on web in this build.');
      return;
    }
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _cameraError = 'No camera found on this device.');
        return;
      }
      // Prefer the camera chosen on the home screen (matched by name,
      // since descriptions don't survive rebuilds); fall back to back.
      final want = widget.camera?.name;
      final pick = cams.firstWhere(
        (c) => want != null && c.name == want,
        orElse: () => cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first,
        ),
      );
      final controller = CameraController(pick, ResolutionPreset.high,
          enableAudio: false);
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _cam = controller;
        _activeCamera = pick;
        _cameraReady = true;
        _cameraError = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() =>
            _cameraError = 'Live camera is not available on this device.');
      }
    }
  }

  // ------------------------------------------------------------ video scrub
  Future<void> _startScrub(String path) async {
    _videoDurMs = await videoDurationMs(path);
    if (!mounted) return;
    setState(() => _posMs = 0);
    await _grabFrame(0);
  }

  Future<void> _grabFrame(double ms) async {
    final path = widget.videoPath;
    if (path == null) return;
    if (_grabbing) {
      _pendingMs = ms; // a grab is in flight — queue the latest position
      return;
    }
    setState(() => _grabbing = true);
    try {
      final data = await grabVideoFrame(path, ms);
      if (data != null && mounted) setState(() => _frameBytes = data);
    } catch (_) {
      // keep the previous frame on failure
    }
    if (!mounted) return;
    setState(() => _grabbing = false);
    final pending = _pendingMs;
    _pendingMs = null;
    if (pending != null && pending != ms) await _grabFrame(pending);
  }

  void _onSlider(double ms) {
    setState(() => _posMs = ms);
    _grabFrame(ms);
  }

  Future<void> _changeVideo() async {
    try {
      final picked = await _picker.pickVideo(source: ImageSource.gallery);
      if (picked == null || !mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
            builder: (_) => CalibratePage.video(
                videoPath: picked.path, doubles: widget.doubles)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not pick a video: $e')),
      );
    }
  }

  // ------------------------------------------------------------ calibration
  Future<void> _calibrate() async {
    if (widget.live) {
      final cam = _cam;
      if (cam == null || !cam.value.isInitialized) return;
      setState(() => _stage = _Stage.busy);
      try {
        final shot = await cam.takePicture();
        await _runDetection(await shot.readAsBytes());
      } catch (e) {
        _fail('Capture failed: $e');
      }
      return;
    }
    final b = _frameBytes;
    if (b == null) return;
    setState(() => _stage = _Stage.busy);
    await _runDetection(b);
  }

  Future<void> _runDetection(Uint8List bytes) async {
    if (museSupported) return _runMuseDetection(bytes);
    var req = VlineRequest.encoded(bytes);
    if (kIsWeb) {
      // The web bridge takes raw pixels; decode for display anyway.
      final img = await _decode(bytes);
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd != null) {
        req = VlineRequest.rgba(
            bd.buffer.asUint8List(), img.width, img.height);
      }
      img.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    final det = await compute(runVlineCalibration, req);
    if (!mounted) return;
    _showDetection(bytes, det);
  }

  // muse2 calibrate_around: 8 frames over ±10 s around the chosen moment so
  // players are medianed out of the background.
  static const int _museCalFrames = 8;
  static const double _museCalSpreadMs = 10000;

  Future<void> _runMuseDetection(Uint8List bytes) async {
    // Warm the ball model alongside the court fit: by Confirm time the scan
    // starts instantly instead of paying unpack + compile after playback.
    // Warmup errors surface honestly when the scan starts; nothing to show.
    museWarmup().ignore();
    VlineCalibration? det;
    try {
      final frames = <Uint8List>[];
      var fw = 0, fh = 0;

      final path = widget.videoPath;
      if (path != null && _videoDurMs > 0) {
        var lo = math.max(0.0, _posMs - _museCalSpreadMs);
        var hi = math.min(_videoDurMs, _posMs + _museCalSpreadMs);
        if (hi <= lo) {
          lo = 0;
          hi = _videoDurMs;
        }
        final times = <int>{
          for (var i = 0; i < _museCalFrames; i++)
            (lo + (hi - lo) * i / (_museCalFrames - 1)).floor(),
          // The picked frame itself: the user chose this moment because the
          // court looks clear there, so it must be a candidate.
          _posMs.floor(),
        };
        // OpenCV-equivalent pixels (what muse2 was tuned on), one frame read
        // at each sample time.
        for (final t in times) {
          if (!await openVideoReader(path,
              startMs: t.toDouble(),
              maxWidth: kMuseProcW,
              minIntervalMs: 0,
              cvColor: true)) {
            continue;
          }
          try {
            final rf = await nextVideoFrame();
            if (rf != null &&
                (frames.isEmpty || (rf.$2 == fw && rf.$3 == fh))) {
              fw = rf.$2;
              fh = rf.$3;
              frames.add(rf.$1);
            }
          } finally {
            await closeVideoReader();
          }
        }
      }
      if (frames.isEmpty) {
        // Single still (photo or frozen live frame): decode to RGBA.
        final img = await _decode(bytes);
        try {
          final bd =
              await img.toByteData(format: ui.ImageByteFormat.rawRgba);
          if (bd != null) {
            fw = img.width;
            fh = img.height;
            frames.add(bd.buffer.asUint8List());
          }
        } finally {
          img.dispose();
        }
      }
      if (frames.isEmpty) throw StateError('no frames to calibrate on');
      final img = await _decode(bytes);
      try {
        final calib = await museCalibrate(frames, fw, fh);
        final projected = projectedFromMuse(calib, img.width / kMuseProcW);
        if (projected != null) {
          det = VlineCalibration(
            lines: const [],
            projected: projected,
            score: 0,
            rms: calib.rmsPx,
            coarseRetry: false,
            frameW: img.width,
            frameH: img.height,
          );
        }
      } finally {
        img.dispose();
      }
    } catch (e) {
      debugPrint('[calib] muse2: $e'); // no court → honest reject below
    }
    if (!mounted) return;
    _showDetection(bytes, det);
  }

  void _showDetection(Uint8List bytes, VlineCalibration? det) {
    // Only a COMPLETE projected court (the full 10-segment ITF model) is
    // accepted — a partial detection would draw a broken court.
    final complete = det != null && det.projected.length == 10;
    setState(() {
      _frameBytes = bytes;
      _result = complete ? det : null;
      _stage = _Stage.result;
      _message = complete
          ? 'Court found. Confirm to start tracking, or recalibrate.'
          : 'No tennis court detected. Move so the whole court is visible '
              'and recalibrate.';
    });
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _stage = _Stage.pick;
      _message = msg;
    });
  }

  void _recalibrate() {
    setState(() {
      _result = null;
      _message = '';
      _stage = _Stage.pick;
    });
  }

  void _confirm() {
    final r = _result;
    if (r == null || !_accepted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => TrackPage(
          calibration: r,
          videoPath: widget.videoPath,
          doubles: widget.doubles,
          initialCamera: _activeCamera ?? widget.camera,
        ),
      ),
    );
  }

  Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    return (await codec.getNextFrame()).image;
  }

  String _fmtMs(double ms) {
    final s = (ms / 1000).floor();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  // ------------------------------------------------------------------ build
  static const _shadow = Shadow(
      color: Colors.black, blurRadius: 4, offset: Offset(0, 1));

  @override
  Widget build(BuildContext context) {
    final title = widget.live ? 'Calibrate live feed' : 'Court detection';
    // Full-bleed frame for small phone screens; the label, buttons and
    // slider float over it.
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 17)),
        actions: [
          if (!widget.live)
            IconButton(
              icon: const Icon(Icons.movie_outlined),
              tooltip: 'Choose a different video',
              onPressed: _changeVideo,
            ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: _frameView()),
            // Status message, top middle over the video.
            if (_message.isNotEmpty)
              Positioned(
                top: 10,
                left: 16,
                right: 16,
                child: Text(_message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color:
                            _accepted ? Colors.greenAccent : Colors.white70,
                        fontSize: 13,
                        shadows: const [_shadow])),
              ),
            // Calibrate top right; Recalibrate takes the same spot once a
            // court is drawn.
            if (_stage == _Stage.pick)
              Positioned(
                top: 10,
                right: 10,
                child: ElevatedButton.icon(
                  onPressed: _canCalibrate ? _calibrate : null,
                  icon: const Icon(Icons.grid_on_outlined),
                  label: const Text('Calibrate',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            if (_stage == _Stage.result)
              Positioned(
                top: 10,
                right: 10,
                child: ElevatedButton.icon(
                  onPressed: _recalibrate,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Recalibrate',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            // Confirm bottom right once a court is detected.
            if (_stage == _Stage.result && _accepted)
              Positioned(
                bottom: 10,
                right: 10,
                child: ElevatedButton.icon(
                  onPressed: _confirm,
                  icon: const Icon(Icons.check),
                  label: const Text('Confirm',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            // Scrub slider along the bottom, full width.
            if (!widget.live && _stage == _Stage.pick)
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _videoDurMs > 0
                            ? _posMs.clamp(0.0, _videoDurMs)
                            : 0.0,
                        min: 0,
                        max: _videoDurMs > 0 ? _videoDurMs : 1.0,
                        onChanged: _grabbing ? null : _onSlider,
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(_fmtMs(_posMs),
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              shadows: [_shadow])),
                    ),
                  ],
                ),
              ),
            if (!museSupported)
              Positioned(
                left: 12,
                right: 170,
                bottom: (!widget.live && _stage == _Stage.pick) ? 64 : 12,
                child: const Text(
                  'On-device engine unavailable here — using the classical '
                  'fallback. Ball tracking needs iOS or macOS.',
                  style: TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      shadows: [_shadow]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _frameView() {
    if (widget.live && _stage == _Stage.pick) return _liveView();
    final b = _frameBytes;
    if (b == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(b, fit: BoxFit.cover),
        if (_accepted && _result != null)
          CourtOverlay(_result!, cover: true, doubles: widget.doubles),
        if (_stage == _Stage.busy)
          Container(
            color: Colors.black54,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.purpleAccent),
                  SizedBox(height: 12),
                  Text('Finding the court…',
                      style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _liveView() {
    if (!_cameraReady) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _cameraError == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam_off_outlined,
                        color: Colors.white54, size: 48),
                    const SizedBox(height: 12),
                    Text(_cameraError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70)),
                  ],
                ),
        ),
      );
    }
    final controller = _cam!;
    final preview = controller.value.previewSize;
    final aspect = preview == null || preview.height == 0
        ? 16 / 9
        : preview.width / preview.height;
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: aspect * 100,
        height: 100,
        child: CameraPreview(controller),
      ),
    );
  }

  bool get _canCalibrate {
    if (widget.live) return _cameraReady;
    return _frameBytes != null;
  }
}
