// Payload rules for the annotated-film export mirror TrackOverlayPainter
// exactly (trail window, cand window, numbered rings) so the exported
// film matches the live view.
import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/engine/film_export.dart';
import 'package:line_call/engine/vline_calibrate_types.dart';
import 'package:tennis_core/types.dart';

Track _track(int id, List<int> frames, {bool stray = false}) => Track(
      id,
      [for (final f in frames) TrackPoint(f, f.toDouble(), 10, true, 1)],
      const [],
      const [],
      stray,
    );

void main() {
  test('tails keep the last 30 frames and drop strays/shorts', () {
    final tracks = [
      _track(1, [for (var f = 0; f < 40; f++) f]), // long: windowed
      _track(2, [for (var f = 0; f < 40; f++) f], stray: true),
      _track(3, [36, 37, 38]), // short (<6): never drawn
    ];
    final fr = exportFrameBalls(tracks, {}, 39);
    final tails = fr['tails']! as List<List<double>>;
    expect(tails, hasLength(1));
    // Frames (39-30, 39] = 10..39 → 30 points → 60 doubles.
    expect(tails[0], hasLength(60));
    expect(tails[0].first, 10.0);
    expect(tails[0].last, 10.0); // y of frame 39
    expect(tails[0][58], 39.0); // x of frame 39
    final heads = fr['heads']! as List<double>;
    expect(heads, [39.0, 10.0]);
  });

  test('cands cover ±2 frames around the shown frame', () {
    final cands = {
      8: [const Candidate(1, 1, 1)],
      9: [const Candidate(2, 2, 1)],
      10: [const Candidate(3, 3, 1)],
      11: [const Candidate(4, 4, 1)],
      12: [const Candidate(5, 5, 1)],
      13: [const Candidate(6, 6, 1)],
    };
    final fr = exportFrameBalls([], cands, 10);
    // Frames 8..12 (|k-10| ≤ 2); frame 13 is out of the window.
    expect(fr['cands'],
        [1.0, 1.0, 2.0, 2.0, 3.0, 3.0, 4.0, 4.0, 5.0, 5.0]);
  });

  test('marks gate on frame and number 1 = newest, last 10', () {
    final all = [
      for (var i = 0; i < 12; i++)
        BounceCall(100 + i * 10, 1, 1, 'IN', 0, 0),
    ];
    // Early: only the first two exist (frames 100, 110).
    expect(exportFrameMarks(all, 115), [
      [0, 2],
      [1, 1],
    ]);
    // Late: last 10, newest is 1.
    final late = exportFrameMarks(all, 1000);
    expect(late, hasLength(10));
    expect(late.first, [2, 10]);
    expect(late.last, [11, 1]);
  });

  test('payload carries court lines, bounces and one row per scan frame',
      () {
    // Court marking needs no engine here: projected lines pass through.
    final payload = buildExportPayload(
      calibration: _calib(),
      doubles: true,
      procW: 1280,
      procH: 720,
      scanMs: [0, 33.3, 66.6],
      bounces: [BounceCall(1, 640, 360, 'IN', 0, -6.0)],
      tracks: [_track(1, [0, 1, 2, 3, 4, 5])],
      cands: {
        1: [const Candidate(640, 360, 0.9)]
      },
    );
    expect(payload['procW'], 1280);
    expect(payload['frameW'], 1920);
    expect((payload['lines'] as List), hasLength(1));
    final bounces = payload['bounces'] as List;
    expect(bounces.single['in'], isTrue);
    final frames = payload['frames'] as List;
    expect(frames, hasLength(3));
    // Middle frame: the bounce exists already, numbered 1.
    expect((frames[1] as Map)['marks'], [
      [0, 1]
    ]);
    expect((frames[0] as Map)['marks'], isEmpty);
  });
}

// Minimal calibration: one projected segment passes courtMarking through.
VlineCalibration _calib() => VlineCalibration(
      lines: const [],
      baselines: const [],
      serviceLines: const [],
      projected: const [
        [0.0, 0.0, 100.0, 100.0]
      ],
      score: 1,
      rms: 0,
      coarseRetry: false,
      frameW: 1920,
      frameH: 1080,
    );
