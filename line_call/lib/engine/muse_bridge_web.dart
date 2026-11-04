// =============================================================================
// LINE CALLING — muse2 engine facade, web stub (no dart:ffi on web).
// =============================================================================
import 'dart:async';
import 'dart:typed_data';

import 'package:tennis_core/types.dart';

bool get museSupported => false;
String get museUnavailableReason => 'Ball tracking needs the iOS or macOS app';

class MuseScan {
  Stream<MuseUpdate> get updates => const Stream.empty();
  void push(Uint8List rgba, int w, int h) {}
  void flush() {}
  Future<void> close() async {}
}

/// Web has no model: a no-op so calibration can warm unconditionally.
Future<(String, String)> museWarmup() => Future.value(('', ''));

Future<MuseScan> museStartScan({
  required double fps,
  required int procW,
  required int procH,
  List<double>? hImg2Court,
  List<double>? hCourt2Img,
  bool adaptiveStride = true,
}) =>
    throw UnsupportedError(museUnavailableReason);

Future<List<Candidate>> museDetect(List<Uint8List> rgba, int w, int h) =>
    throw UnsupportedError(museUnavailableReason);

Future<CourtCalib> museCalibrate(List<Uint8List> rgba, int w, int h) =>
    throw UnsupportedError(museUnavailableReason);
