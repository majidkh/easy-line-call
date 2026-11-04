// =============================================================================
// LINE CALLING — muse2 engine facade.
//
// The engine (packages/tennis_core) rides on dart:ffi, which the web compiler
// refuses to even import, so web gets a stub that reports "unsupported" —
// same compile-time selection as vline_calibrate.dart. Callers import this
// file and use museSupported / museCalibrate / museDetect / museStartScan.
// =============================================================================

export 'muse_bridge_web.dart' if (dart.library.io) 'muse_bridge_io.dart';
