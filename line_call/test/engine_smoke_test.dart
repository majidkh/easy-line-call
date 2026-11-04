// Engine ABI smoke test: the vendored muse2 core loads over dart:ffi and
// exposes the symbols the app's bindings need.
//
// Uses $TENNIS_CORE_LIB when set (e.g. the built app's
// tennis_core.framework/tennis_core), else the desktop-built
// core/build/libtennis_shared.dylib. Skips when neither exists (fresh
// checkout without a native build).
import 'dart:convert' show utf8;
import 'dart:ffi';
import 'dart:io' show File, Platform;

import 'package:flutter_test/flutter_test.dart';

String? _libPath() {
  final override = Platform.environment['TENNIS_CORE_LIB'];
  if (override != null && override.isNotEmpty && File(override).existsSync()) {
    return override;
  }
  const desktop =
      '../core/build/libtennis_shared.dylib'; // relative to line_call/
  if (File(desktop).existsSync()) return desktop;
  return null;
}

String _readStr(Pointer<Int8> p) {
  final bytes = <int>[];
  var i = 0;
  while (p[i] != 0) {
    bytes.add(p[i]);
    i++;
  }
  return utf8.decode(bytes);
}

void main() {
  final libPath = _libPath();
  test(
    'muse2 core loads and answers over FFI',
    skip: libPath == null ? 'no native core built' : false,
    () {
      final lib = DynamicLibrary.open(libPath!);
      for (final sym in [
        'tennis_last_error',
        'tennis_free',
        'tennis_detect_court',
        'tennis_calibrate_frames',
        'tennis_detector_create',
        'tennis_detector_infer',
        'tennis_session_create',
        'tennis_session_ingest',
      ]) {
        expect(() => lib.lookup(sym), returnsNormally, reason: sym);
      }
      final lastError = lib
          .lookupFunction<Pointer<Int8> Function(), Pointer<Int8> Function()>(
              'tennis_last_error');
      // A fresh handle reports an empty error string; the call itself must
      // not crash.
      expect(_readStr(lastError()), isEmpty);
    },
  );
}
