// =============================================================================
// LINE CALLING — calibration bridge facade.
//
// Picks the OpenCV-backed bridge on platforms where dart:io (and therefore
// dart:ffi) is available — iOS, Android, Linux, macOS, Windows. On Flutter
// web, where the JS compiler refuses to compile anything that even imports
// dart:ffi (opencv_dart/dartcv4), it picks the pure-Dart bridge instead:
// the same detection core seeded by a pure Canny+Hough, fed RGBA pixels.
//
// Pure compile-time selection, same as sr_service.dart. Callers import this
// file and use VlineRequest / VlineCalibration / runVlineCalibration; both
// implementations expose the same surface.
// =============================================================================

export 'vline_calibrate_web.dart'
    if (dart.library.io) 'vline_calibrate_io.dart';
