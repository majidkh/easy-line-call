// =============================================================================
// LINE CALLING — muse2 engine facade, native platforms.
//
// Thin app glue over packages/tennis_core: unpacks the bundled Core ML model
// (assets/models/BallHeatANE.mlpackage) to app support once, then hands
// paths + frames to the engine. Import 'muse_bridge.dart', not this file.
// =============================================================================
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:tennis_core/tennis_core.dart';

import 'muse_court.dart' show kMuseProcW;

bool get museSupported => TennisCoreLib.instance != null;
String get museUnavailableReason => TennisCoreLib.loadError.isEmpty
    ? 'Ball tracking needs the iOS or macOS app'
    : TennisCoreLib.loadError;

// ANE (not Turbo): Turbo's quantized build outputs all-zero heat on this
// Core ML runtime (blind detector); ANE matches the full model's heat.
const String _pkg = 'BallHeatANE.mlpackage';
const List<String> _pkgFiles = [
  'Manifest.json',
  'Data/com.apple.CoreML/model.mlmodel',
  'Data/com.apple.CoreML/weights/weight.bin',
];

Future<(String, String)>? _paths;
Future<(String, String)>? _warmed;

/// (model package dir, compile cache dir), warmed: the model is unpacked
/// from assets and compiled + loadable. Call early (calibration already
/// does) so a later scan starts instantly instead of paying unpack + Core ML
/// compile after the video starts playing. Starting a scan without warming
/// awaits the same future, so concurrent starts and the warmup serialize
/// instead of compiling twice.
Future<(String, String)> museWarmup() => _warmed ??= () async {
      final pc = await _modelPaths();
      await warmDetector(modelPath: pc.$1, compileCache: pc.$2);
      return pc;
    }();

/// (model package dir, compile cache dir) — unpacked from assets on first use
/// (and again only if a file's size changed with an app update).
Future<(String, String)> _modelPaths() => _paths ??= () async {
      final root = Directory('${(await getApplicationSupportDirectory()).path}/muse2');
      final pkg = '${root.path}/$_pkg';
      for (final rel in _pkgFiles) {
        final data = await rootBundle.load('assets/models/$_pkg/$rel');
        final f = File('$pkg/$rel');
        if (await f.exists() && await f.length() == data.lengthInBytes) continue;
        await f.parent.create(recursive: true);
        await f.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            flush: true);
      }
      return (pkg, '${root.path}/compiled');
    }();

/// A running muse2 tracking session (worker isolate).
class MuseScan {
  final MuseEngine _engine;
  MuseScan._(this._engine);

  Stream<MuseUpdate> get updates => _engine.updates;
  void push(Uint8List rgba, int w, int h) => _engine.push(rgba, w, h);
  void flush() => _engine.flush();
  Future<void> close() => _engine.close();
}

/// Start the umpire/desktop "fast" pipeline: ANE model, stride 3, 24-frame
/// chunks, blind-gap recovery, court filter. Court homographies are muse2
/// ones in processing px (see museHomographies), or null for no court.
Future<MuseScan> museStartScan({
  required double fps,
  required int procW,
  required int procH,
  List<double>? hImg2Court,
  List<double>? hCourt2Img,
}) async {
  final (model, cache) = await museWarmup();
  final e = await MuseEngine.start(MuseEngineConfig(
    fps: fps,
    procW: procW,
    procH: procH,
    modelPath: model,
    compileCache: cache,
    hImg2Court: hImg2Court,
    hCourt2Img: hCourt2Img,
  ));
  return MuseScan._(e);
}

/// Ball candidates on the last of 3 consecutive RGBA frames (best first),
/// in processing px (width [kMuseProcW]).
Future<List<Candidate>> museDetect(List<Uint8List> rgba, int w, int h) async {
  final (model, cache) = await museWarmup();
  return detectTriplet(
      modelPath: model,
      compileCache: cache,
      rgba: rgba,
      w: w,
      h: h,
      procW: kMuseProcW,
      procH: h * kMuseProcW ~/ w);
}

/// Court calibration on RGBA frames (one still, or several frames of a static
/// camera), fitted at processing width [kMuseProcW]. Throws when no court.
Future<CourtCalib> museCalibrate(List<Uint8List> rgba, int w, int h) =>
    calibrateCourt(
        rgba: rgba, w: w, h: h, procW: kMuseProcW, procH: h * kMuseProcW ~/ w);
