// Warmup path: warmDetector compiles the Core ML model into the cache once
// and reuses it, so a later scan starts instantly.
//
// Needs the native core + the ANE model; run with e.g.
//   TENNIS_CORE_LIB=../core/build/libtennis_shared.dylib flutter test
// Skips when either is absent (fresh checkout without a native build).
import 'dart:io' show Directory, FileStat;

import 'package:flutter_test/flutter_test.dart';
import 'package:tennis_core/tennis_core.dart';

void main() {
  test('detector warms once and reuses the compiled model', () async {
    const model = '../models/BallHeatANE.mlpackage'; // relative to line_call/
    if (TennisCoreLib.instance == null ||
        !Directory(model).existsSync()) {
      markTestSkipped('needs native core (TENNIS_CORE_LIB) + $model');
    }
    final cache = await Directory.systemTemp.createTemp('warmtest');
    try {
      await warmDetector(modelPath: model, compileCache: cache.path)
          .timeout(const Duration(minutes: 3));
      final compiled = cache
          .listSync()
          .where((e) => e.path.endsWith('.mlmodelc'))
          .toList();
      expect(compiled, isNotEmpty, reason: 'compiled model cached');
      final mtime = FileStat.statSync(compiled.first.path).modified;
      await warmDetector(modelPath: model, compileCache: cache.path)
          .timeout(const Duration(minutes: 3));
      expect(FileStat.statSync(compiled.first.path).modified, mtime,
          reason: 'second warm reuses the cache instead of recompiling');
    } finally {
      await cache.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 7)));
}
