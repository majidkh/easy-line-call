// =============================================================================
// LINE CALLING — annotated-film export (Dart side). After a video scan, this
// builds one overlay payload from the final engine results and hands it to
// the native AVAssetWriter twins (macOS + iOS) over `line_call/video`. The
// native side re-reads the source at FULL resolution, draws the same court
// lines / ball trails / detection dots / numbered bounce rings the live
// view shows, and re-encodes video (same size, same FPS, original audio
// passed through) into an output/ folder.
//
// The per-frame primitives replicate TrackOverlayPainter exactly (trail
// window 30, cand window ±2, last-10 numbered rings with 1 = newest), so the
// exported film matches what the user watched — except nothing is cover-
// cropped: overlays map onto the full frame.
// =============================================================================
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;
import 'package:tennis_core/types.dart'
    show BounceCall, Candidate, Track;
import 'dart:ui' show Offset;

import 'court_geometry.dart' show CourtModel;
import 'muse_court.dart' show museCall;
import 'vline_calibrate_types.dart' show VlineCalibration;
import 'vline_court_core.dart' show courtMarking;

const MethodChannel _video = MethodChannel('line_call/video');

/// Singles/doubles-aware IN test — same rule as the live overlay.
bool exportBounceIsIn(BounceCall b, {required bool doubles}) => museCall(
      Offset(
        b.wx + CourtModel.doublesWidth / 2,
        b.wy + CourtModel.length / 2,
      ),
      doubles: doubles,
    ).inBounds;

/// Per-scan-frame ball primitives: polylines (flat [x,y,…] in processing
/// px), head dots and raw detection dots — the painter's exact rules.
Map<String, Object> exportFrameBalls(
    List<Track> tracks, Map<int, List<Candidate>> cands, int idx) {
  final tails = <List<double>>[];
  final heads = <double>[];
  for (final t in tracks) {
    if (t.stray) continue;
    if (t.points.length < 6) continue;
    final pts = [
      for (final p in t.points)
        if (p.frame <= idx && p.frame > idx - 30) p
    ];
    if (pts.length >= 2) {
      tails.add([for (final p in pts) ...[p.x, p.y]]);
    }
    if (pts.isNotEmpty) {
      heads.addAll([pts.last.x, pts.last.y]);
    }
  }
  final dots = <double>[
    for (final e in cands.entries)
      if ((e.key - idx).abs() <= 2)
        for (final c in e.value) ...[c.x, c.y]
  ];
  return {'tails': tails, 'heads': heads, 'cands': dots};
}

/// Per-scan-frame bounce marks [[bounceIndex, number]] — the painter's
/// last-10 rule with 1 = newest. [all] must be oldest-first.
List<List<int>> exportFrameMarks(List<BounceCall> all, int idx,
    [int max = 10]) {
  final shown = [
    for (var i = 0; i < all.length; i++)
      if (all[i].frame <= idx) i
  ];
  final window =
      shown.length <= max ? shown : shown.sublist(shown.length - max);
  return [
    for (var i = 0; i < window.length; i++)
      [window[i], window.length - i]
  ];
}

/// Full channel payload. [scanMs] maps scan frame → video ms (ascending);
/// native binary-searches it per output frame, like the live view.
Map<String, Object> buildExportPayload({
  required VlineCalibration calibration,
  required bool doubles,
  required int procW,
  required int procH,
  required List<double> scanMs,
  required List<BounceCall> bounces,
  required List<Track> tracks,
  required Map<int, List<Candidate>> cands,
}) {
  final marked = courtMarking(
    doubles: doubles,
    projected: calibration.projected,
    lines: calibration.lines,
    baselines: calibration.baselines,
    serviceLines: calibration.serviceLines,
  );
  final frames = <Map<String, Object>>[];
  for (var i = 0; i < scanMs.length; i++) {
    frames.add({
      ...exportFrameBalls(tracks, cands, i),
      'marks': exportFrameMarks(bounces, i),
    });
  }
  return {
    'procW': procW,
    'procH': procH,
    'frameW': calibration.frameW,
    'frameH': calibration.frameH,
    'lines': [
      for (final l in marked)
        [l[0], l[1], l[2], l[3]]
    ],
    'scanMs': scanMs,
    'bounces': [
      for (final b in bounces)
        {
          'x': b.x,
          'y': b.y,
          'in': exportBounceIsIn(b, doubles: doubles),
        }
    ],
    'frames': frames,
  };
}

/// Where the annotated film goes: an output/ folder next to the source
/// video when writable (dev videos), else the app documents output/
/// (sandboxed macOS / iOS).
Future<String> resolveExportPath(String videoPath) async {
  final src = File(videoPath);
  final base = src.uri.pathSegments.isEmpty
      ? 'film'
      : src.uri.pathSegments.last.replaceAll(RegExp(r'\.[^.]*$'), '');
  final name = '${base}_annotated.mp4';
  try {
    final dir = Directory('${src.parent.path}/output');
    await dir.create(recursive: true);
    return '${dir.path}/$name';
  } catch (_) {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/output');
    await dir.create(recursive: true);
    return '${dir.path}/$name';
  }
}

/// Drives the native export: starts it, polls progress, returns the written
/// path or throws. [isCancelled] is checked between polls.
Future<String> runExport({
  required String videoPath,
  required Map<String, Object> payload,
  required void Function(double progress) onProgress,
  required bool Function() isCancelled,
}) async {
  if (!(Platform.isMacOS || Platform.isIOS)) {
    throw StateError('Annotated export needs macOS or iOS.');
  }
  final outPath = await resolveExportPath(videoPath);
  final started = await _video.invokeMethod<Map>('exportStart', {
    'path': videoPath,
    'outPath': outPath,
    'payload': payload,
  });
  final ok = started?['ok'] == true;
  if (!ok) {
    throw StateError(
        '${started?['error'] ?? 'export failed to start'}');
  }
  while (true) {
    if (isCancelled()) {
      await _video.invokeMethod('exportCancel');
      throw StateError('Export cancelled.');
    }
    await Future.delayed(const Duration(milliseconds: 250));
    final st = await _video.invokeMethod<Map>('exportProgress');
    final state = st?['state'] as String? ?? 'error';
    if (state == 'running') {
      onProgress(((st?['progress'] as num?) ?? 0).toDouble());
    } else if (state == 'done') {
      onProgress(1);
      return (st?['path'] as String?) ?? outPath;
    } else {
      throw StateError('${st?['error'] ?? 'export failed'}');
    }
  }
}
