// End-to-end drive of the challenge + live flows on a real engine run.
//
// Run on macOS (the test app is sandboxed, so the video is a bundled
// rally-3 slice staged to temp; the iOS simulator cannot do even that):
//   TENNIS_CORE_LIB=/tmp/libtennis_vendor.dylib flutter test -d macos \
//     integration_test/drive_test.dart
//
// 1. Challenge browser over real rally-3 footage: slider scrubbed across
//    the window frame-by-frame, tap-to-review, back.
// 2. Live TrackPage with a fake dual camera: preview starts on the real
//    engine scan, the switch button appears and flips front/back mid-stream.
// 3. Live challenge browser over a synthetic >2-minute buffer: scrub the
//    full window, tap-to-review, back.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:line_call/engine/vline_calibrate_types.dart';
import 'package:line_call/live/frame_buffer.dart';
import 'package:line_call/ui/challenge_page.dart';
import 'package:line_call/ui/track_page.dart';
import 'package:path_provider/path_provider.dart';

/// Stage the bundled rally-3 slice where the sandboxed test app can play
/// it (ChallengePage.video takes a file path, not an asset key).
Future<String> _stageClip() async {
  final data = await rootBundle.load('assets/test/clip_6s.mp4');
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/drive_clip.mp4');
  await f.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  return f.path;
}

/// Synthetic court: near baseline low in frame, far baseline high.
/// projected[0]/[4] are the doubles sidelines (near→far), the two segments
/// museHomographies fits from; the rest just need finite paint values.
VlineCalibration _fakeCal() {
  // Near-left (340,650) near-right (940,650) far-left (540,180)
  // far-right (740,180) in a 1280x720 frame.
  const sides = [
    [340.0, 650.0, 540.0, 180.0], // [0] left doubles sideline
    [0.0, 0.0, 1.0, 1.0],
    [0.0, 0.0, 1.0, 1.0],
    [0.0, 0.0, 1.0, 1.0],
    [940.0, 650.0, 740.0, 180.0], // [4] right doubles sideline
    [340.0, 650.0, 940.0, 650.0], // near baseline
    [540.0, 180.0, 740.0, 180.0], // far baseline
    [0.0, 0.0, 1.0, 1.0],
    [0.0, 0.0, 1.0, 1.0],
    [0.0, 0.0, 1.0, 1.0],
  ];
  return VlineCalibration(
    lines: const [],
    projected: [for (final s in sides) List<double>.from(s)],
    score: 1,
    rms: 0,
    coarseRetry: false,
    frameW: 1280,
    frameH: 720,
  );
}

/// Dual fake camera streaming small gray BGRA frames into the real live
/// pipeline (conversion, engine scan, challenge buffer all run for real).
class FakeCams extends CameraPlatform {
  int _nextId = 1;
  final _cams = [
    const CameraDescription(
        name: 'back',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 0),
    const CameraDescription(
        name: 'front',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 0),
  ];

  CameraImageData _frame() {
    const w = 320, h = 240;
    final bytes = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      final g = 100 + ((i ~/ w + i % w) % 60);
      bytes[i * 4] = g;
      bytes[i * 4 + 1] = g;
      bytes[i * 4 + 2] = g;
      bytes[i * 4 + 3] = 255;
    }
    return CameraImageData(
      format: const CameraImageFormat(ImageFormatGroup.bgra8888, raw: 0),
      planes: [
        CameraImagePlane(bytes: bytes, bytesPerRow: w * 4, height: h, width: w)
      ],
      height: h,
      width: w,
    );
  }

  @override
  Future<List<CameraDescription>> availableCameras() async => _cams;

  @override
  Future<int> createCameraWithSettings(
          CameraDescription description, MediaSettings settings) async =>
      _nextId++;

  @override
  Future<void> initializeCamera(int cameraId,
          {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) =>
      Future.value();

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(CameraInitializedEvent(cameraId, 640, 480,
          ExposureMode.auto, false, FocusMode.auto, false));

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      const Stream.empty();

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  bool supportsImageStreaming() => true;

  @override
  Stream<CameraImageData> onStreamedFrameAvailable(int cameraId,
          {CameraImageStreamOptions? options}) =>
      Stream.fromIterable(List.generate(40, (_) => _frame()));

  @override
  Widget buildPreview(int cameraId) =>
      const SizedBox.expand(child: ColoredBox(color: Colors.black));

  @override
  Future<void> dispose(int cameraId) => Future.value();
}

Future<void> _pumpUntil(
    WidgetTester t, Finder f, Duration step, int max) async {
  for (var i = 0; i < max && f.evaluate().isEmpty; i++) {
    await t.pump(step);
  }
}

String _clock(WidgetTester t) {
  final w = t.widget<Text>(find.textContaining('last 2 min'));
  return w.data ?? '';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scrub real rally-3, tap to review, back', (t) async {
    final clip = await _stageClip();
    await t.pumpWidget(MaterialApp(
        home: ChallengePage.video(videoPath: clip, entryMs: 5000)));
    await _pumpUntil(t, find.byType(Slider), const Duration(seconds: 1), 30);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('Could not play this video.'), findsNothing);

    // Frame-by-frame scrub: drag the thumb in small steps, the clock must
    // follow every step (coalesced seeks keep this smooth, not jumpy).
    final sliderCenter = t.getCenter(find.byType(Slider));
    final gesture = await t.startGesture(sliderCenter);
    final clocks = <String>{_clock(t)};
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await t.pump(const Duration(milliseconds: 120));
      clocks.add(_clock(t));
    }
    await gesture.up();
    await t.pump(const Duration(seconds: 1));
    // ignore: avoid_print
    print('scrub clocks: ${clocks.join(' | ')}');
    expect(clocks.length, greaterThan(5),
        reason: 'clock follows the drag step by step');

    // Tap the footage (above the slider) → review page → back.
    await t.tapAt(const Offset(400, 200));
    await t.pump(const Duration(seconds: 2));
    expect(find.byType(ChallengeReviewPage), findsOneWidget);
    await t.pageBack();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(ChallengePage), findsOneWidget);
  });

  testWidgets('video playback never holds for the trailing scan',
      (t) async {
    final clip = await _stageClip();
    await t.pumpWidget(MaterialApp(
        home: TrackPage(
            calibration: _fakeCal(), videoPath: clip, doubles: true)));
    // Wait for the analysis to start (model warmup on first run).
    await _pumpUntil(t, find.textContaining('Analyzing'),
        const Duration(seconds: 2), 150);
    expect(find.textContaining('Analyzing'), findsOneWidget);
    // The 6s/60fps clip outruns the ~21fps analysis within the first
    // second; the old pacing held playback here ('holding…'). Let the
    // video play well past the frontier, then check it was never held.
    final t0 = DateTime.now();
    while (DateTime.now().difference(t0) < const Duration(seconds: 7)) {
      await Future.delayed(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Analyzing'), findsOneWidget,
        reason: 'scan still trailing (6s clip takes ~17s to analyze)');
    expect(find.textContaining('holding'), findsNothing,
        reason: 'playback never holds for the analysis');
    // To the end: the scan completes after the video ended, offering a
    // replay with the full calls on screen.
    await _pumpUntil(t, find.text('Replay with calls'),
        const Duration(seconds: 2), 90);
    expect(find.text('Replay with calls'), findsOneWidget);
  });

  testWidgets('live challenge browser over a 3-minute buffer', (t) async {
    final buf = LiveBuffer();
    final rgba = Uint8List(320 * 180 * 4);
    for (var i = 0; i < 320 * 180; i++) {
      rgba[i * 4] = 60 + (i % 80);
      rgba[i * 4 + 1] = 100;
      rgba[i * 4 + 2] = 140;
      rgba[i * 4 + 3] = 255;
    }
    for (var ms = 0; ms <= 180000; ms += 900) {
      buf.add(rgba, 320, 180, ms.toDouble());
    }
    await t.pumpWidget(MaterialApp(
        home: ChallengePage.live(buffer: buf, entryMs: 180000)));
    await t.pump(const Duration(seconds: 2));
    expect(find.byType(Slider), findsOneWidget);
    expect(_clock(t), contains('3:00'));

    // Scrub to the window start (entry − 2 min = 1:00).
    final sliderCenter = t.getCenter(find.byType(Slider));
    final gesture = await t.startGesture(sliderCenter);
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await t.pump(const Duration(milliseconds: 100));
    }
    await gesture.up();
    await t.pump(const Duration(seconds: 1));
    // ignore: avoid_print
    print('live scrub clock: ${_clock(t)}');
    expect(_clock(t), contains('1:00'));

    await t.tapAt(const Offset(400, 200));
    await t.pump(const Duration(seconds: 2));
    expect(find.byType(ChallengeReviewPage), findsOneWidget);
    await t.pageBack();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(ChallengePage), findsOneWidget);
  });

  testWidgets('live camera switch flips front/back mid-stream', (t) async {
    CameraPlatform.instance = FakeCams();
    // ignore: avoid_print
    print('diag: TENNIS_CORE_LIB=${Platform.environment['TENNIS_CORE_LIB']}');
    await t.pumpWidget(MaterialApp(home: TrackPage(calibration: _fakeCal())));
    // The preview appears after the real engine warms (Core ML compiles the
    // model on first run, then caches it) and the stream starts.
    await _pumpUntil(
        t, find.byType(CameraPreview), const Duration(seconds: 2), 150);
    if (find.byType(CameraPreview).evaluate().isEmpty) {
      for (final e in find.byType(Text).evaluate()) {
        // ignore: avoid_print
        print('diag TEXT: ${(e.widget as Text).data}');
      }
    }
    expect(find.byType(CameraPreview), findsOneWidget);
    expect(find.text('Live camera is not available.'), findsNothing);

    CameraLensDirection current() => t
        .widget<CameraPreview>(find.byType(CameraPreview))
        .controller
        .description
        .lensDirection;
    expect(current(), CameraLensDirection.back);
    expect(find.byTooltip('Switch camera'), findsOneWidget);

    await t.tap(find.byTooltip('Switch camera'));
    await t.pump(const Duration(seconds: 3));
    // ignore: avoid_print
    print('camera now: $current()');
    expect(current(), CameraLensDirection.front);
    expect(find.text('Live camera is not available.'), findsNothing);
  });
}
