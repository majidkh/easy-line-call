// Background-isolate runner for the muse2 pipeline. The Core ML detector,
// the ChunkDriver and its gray-frame ring all live in one worker isolate, so
// inference + re-derivation never block the UI. The UI pushes decoded RGBA
// frames in order and receives a [MuseUpdate] after every processed chunk.
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'core.dart';
import 'driver.dart';
import 'recover.dart' show TrackerConfig, trailWindow;
import 'types.dart';

class MuseEngineConfig {
  final double fps;
  final int procW, procH;
  final List<double>? hImg2Court, hCourt2Img; // processing-px court
  final String modelPath, compileCache;
  final bool courtFilter;
  final int chunk, stride;
  const MuseEngineConfig({
    required this.fps,
    required this.procW,
    required this.procH,
    required this.modelPath,
    required this.compileCache,
    this.hImg2Court,
    this.hCourt2Img,
    this.courtFilter = true,
    this.chunk = 24,
    this.stride = 3,
  });
}

class MuseEngine {
  final Isolate _iso;
  final SendPort _to;
  final ReceivePort _from;
  final StreamController<MuseUpdate> _updates;
  final Completer<void> _closed;
  final String device;
  MuseEngine._(this._iso, this._to, this._from, this._updates, this._closed,
      this.device);

  Stream<MuseUpdate> get updates => _updates.stream;

  /// Spawns the worker, loads (compiling on first use) the model. Throws
  /// [TennisCoreException] if the core or the model is unavailable.
  static Future<MuseEngine> start(MuseEngineConfig cfg) async {
    final from = ReceivePort();
    final iso = await Isolate.spawn(_worker, (cfg, from.sendPort),
        debugName: 'muse2-engine');
    final updates = StreamController<MuseUpdate>.broadcast();
    final ready = Completer<(SendPort, String)>();
    final closed = Completer<void>();
    from.listen((m) {
      final msg = m as List;
      switch (msg[0] as String) {
        case 'ready':
          ready.complete((msg[1] as SendPort, msg[2] as String));
        case 'update':
          updates.add(msg[1] as MuseUpdate);
        case 'closed':
          if (!closed.isCompleted) closed.complete();
        case 'error':
          final e = TennisCoreException(msg[1] as String);
          if (!ready.isCompleted) {
            ready.completeError(e);
          } else {
            updates.addError(e);
          }
      }
    });
    try {
      final (to, device) = await ready.future;
      return MuseEngine._(iso, to, from, updates, closed, device);
    } catch (_) {
      from.close();
      iso.kill(priority: Isolate.immediate);
      await updates.close();
      rethrow;
    }
  }

  /// Queue the next frame (tightly packed RGBA, any size — resized to the
  /// processing size in the worker).
  void push(Uint8List rgba, int w, int h) =>
      _to.send(['frame', TransferableTypedData.fromList([rgba]), w, h]);

  /// End of footage: process what's left, then emit a `done` update.
  void flush() => _to.send(['flush']);

  /// Frees the worker's native buffers (detector, frames, gray ring) before
  /// the isolate goes — malloc'd memory would outlive a plain kill.
  Future<void> close() async {
    _to.send(['close']);
    await _closed.future
        .timeout(const Duration(seconds: 10), onTimeout: () {});
    _from.close();
    _iso.kill();
    await _updates.close();
  }
}

void _worker((MuseEngineConfig, SendPort) args) {
  final (cfg, out) = args;
  final inbox = ReceivePort();
  CoreDetector? det;
  ChunkDriver? drv;
  try {
    det = CoreDetector.create(cfg.modelPath, cfg.compileCache);
    drv = ChunkDriver(
      fps: cfg.fps,
      width: cfg.procW,
      height: cfg.procH,
      detector: det,
      hImg2Court: cfg.hImg2Court,
      hCourt2Img: cfg.hCourt2Img,
      cfg: TrackerConfig.fast,
      chunk: cfg.chunk,
      stride: cfg.stride,
      courtFilter: cfg.courtFilter,
    );
  } catch (e) {
    det?.close();
    out.send(['error', '$e']);
    inbox.close();
    return;
  }
  final driver = drv, detector = det;
  out.send(['ready', inbox.sendPort, 'coreml-ane']);
  var sentFrontier = 0;

  void emit(int ms, bool done) {
    final lo = (sentFrontier - trailWindow - 64).clamp(0, 1 << 30);
    final cands = <int, List<Candidate>>{
      for (final e in driver.fc.entries)
        if (e.key >= lo && e.key < driver.frontier) e.key: List.of(e.value)
    };
    sentFrontier = driver.frontier;
    out.send([
      'update',
      MuseUpdate(driver.frontier, driver.session.tracks, driver.session.rallies,
          cands, ms, done)
    ]);
  }

  inbox.listen((m) {
    final msg = m as List;
    try {
      switch (msg[0] as String) {
        case 'frame':
          final rgba = (msg[1] as TransferableTypedData).materialize().asUint8List();
          driver.push(bgrFromRgba(
              rgba, msg[2] as int, msg[3] as int, cfg.procW, cfg.procH));
          while (driver.pending >= driver.chunk) {
            final sw = Stopwatch()..start();
            if (!driver.step()) break;
            emit(sw.elapsedMilliseconds, false);
          }
        case 'flush':
          final sw = Stopwatch()..start();
          driver.flush();
          emit(sw.elapsedMilliseconds, true);
        case 'close':
          driver.close();
          detector.close();
          inbox.close();
          out.send(['closed']);
      }
    } catch (e) {
      out.send(['error', '$e']);
    }
  });
}

/// Compile + load the model once, off-thread, so a later scan starts
/// instantly: the compiled artifact persists in [compileCache]. Callers
/// sharing one cache dir must serialize this with detector creation (the
/// app does it through one shared future).
Future<void> warmDetector(
    {required String modelPath, required String compileCache}) {
  return Isolate.run(() {
    CoreDetector.create(modelPath, compileCache).close();
  });
}

/// One-shot: ball candidates on the LAST frame of a 3-frame triplet (the
/// "Detect now" check). Frames are RGBA at [w] x [h], processed at
/// [procW] x [procH]. Best candidate first.
Future<List<Candidate>> detectTriplet(
    {required String modelPath,
    required String compileCache,
    required List<Uint8List> rgba,
    required int w,
    required int h,
    required int procW,
    required int procH}) {
  return Isolate.run(() {
    final det = CoreDetector.create(modelPath, compileCache);
    final imgs = [for (final f in rgba) bgrFromRgba(f, w, h, procW, procH)];
    try {
      return det.candidatesFor(imgs).last;
    } finally {
      for (final i in imgs) {
        i.free();
      }
      det.close();
    }
  });
}

/// One-shot court calibration (pipeline.calibrate_around's core call):
/// several static-camera frames build a median background with the players
/// removed (tennis_calibrate_frames); a single still uses
/// tennis_detect_court. Frames are RGBA at [w] x [h], fitted at [procW] x
/// [procH]; the result's homographies are in that processing space.
Future<CourtCalib> calibrateCourt(
    {required List<Uint8List> rgba,
    required int w,
    required int h,
    required int procW,
    required int procH}) {
  return Isolate.run(() {
    final imgs = [for (final f in rgba) bgrFromRgba(f, w, h, procW, procH)];
    try {
      return imgs.length == 1 ? detectCourt(imgs.first) : calibrateFrames(imgs);
    } finally {
      for (final i in imgs) {
        i.free();
      }
    }
  });
}
