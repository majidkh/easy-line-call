// =============================================================================
// LINE CALLING — super-resolution facade.
//
// Picks the real on-device ESRGAN implementation on platforms where dart:io
// (and therefore dart:ffi via tflite_flutter) is available — i.e. iOS,
// Android, Linux, macOS, Windows. Falls back to a no-op stub on platforms
// where dart:io is *not* available — currently just Flutter web, whose
// JS compiler refuses to compile anything that even imports dart:ffi.
//
// This is a pure compile-time selection: the web build will never see
// tflite_flutter's transitive `import 'dart:ffi';` chain.
//
// Callers should import this file and use the SrService / SrResult API
// directly. Both implementations expose the same surface.
// =============================================================================

export 'sr_service_stub.dart'
    if (dart.library.io) 'sr_service_io.dart';
