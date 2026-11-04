// The ball-model files muse_bridge_io unpacks must be bundled (a model
// switch that forgets pubspec/assets fails only on-device at scan time).
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('bundled ANE ball model unpacks', () async {
    const pkg = 'assets/models/BallHeatANE.mlpackage';
    for (final rel in [
      'Manifest.json',
      'Data/com.apple.CoreML/model.mlmodel',
      'Data/com.apple.CoreML/weights/weight.bin',
    ]) {
      final data = await rootBundle.load('$pkg/$rel');
      expect(data.lengthInBytes, greaterThan(0), reason: rel);
    }
  });
}
