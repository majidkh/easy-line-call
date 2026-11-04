// Review gate end to end (mocked native channel): clip frames load, the
// "Upscaling… NN%" gate runs first, then playback starts half a second
// before the moment (frame 1) at 1/16× with AI tiles applied.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/ui/challenge_page.dart';

Uint8List _frame(int w, int h, int v) {
  final b = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    b[i * 4] = v;
    b[i * 4 + 1] = v;
    b[i * 4 + 2] = v;
    b[i * 4 + 3] = 255;
  }
  return b;
}

// Nearest-neighbor RGBA→2× BGRA, mimicking the native MetalFX reply shape.
Map<String, Object> _up2x(Uint8List rgba, int w, int h) {
  final out = Uint8List(w * 2 * h * 2 * 4);
  for (var y = 0; y < h * 2; y++) {
    for (var x = 0; x < w * 2; x++) {
      final s = ((y ~/ 2) * w + (x ~/ 2)) * 4;
      final d = (y * w * 2 + x) * 4;
      out[d] = rgba[s + 2];
      out[d + 1] = rgba[s + 1];
      out[d + 2] = rgba[s];
      out[d + 3] = 255;
    }
  }
  return {'bytes': out, 'width': w * 2, 'height': h * 2};
}

void main() {
  testWidgets('review upscales first, then plays from frame 1 at 1/16x',
      (tester) async {
    const w = 64, h = 48, n = 6;
    var next = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('line_call/video'),
      (call) async {
        switch (call.method) {
          case 'openReader':
            next = 0;
            return true;
          case 'nextFrame':
            if (next >= n) return null;
            final m = next;
            next++;
            return {
              'bytes': _frame(w, h, 40 + m * 30),
              'width': w,
              'height': h,
              'ms': m * 33.0,
            };
          case 'closeReader':
            return null;
          case 'srUpscale2x':
            // No artificial delay: decodes take real time, so the gate
            // stays observable across polls. (A Future.delayed here
            // would use the fake clock, which pump() without a duration
            // never advances — deadlock.)
            final a = call.arguments as Map;
            return _up2x(a['bytes'] as Uint8List,
                (a['width'] as num).toInt(), (a['height'] as num).toInt());
          default:
            return null;
        }
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('line_call/video'), null);
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: ChallengeReviewPage.video(
          videoPath: 'mock.mp4',
          ms: 99,
          norm: Offset(0.5, 0.5),
        ),
      ),
    );
    // Image decode needs real async; the mocked native delays are
    // real time too. Poll until the upscale gate engages.
    var gateSeen = false;
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && !gateSeen; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        gateSeen =
            find.textContaining('Upscaling…').evaluate().isNotEmpty;
      }
    });
    expect(gateSeen, isTrue);
    // Run until the gate lifts into playback.
    await tester.runAsync(() async {
      for (var i = 0;
          i < 200 && find.text('frame 1/6').evaluate().isEmpty;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    // Gate lifted: playback from frame 1 at 1/16×, AI tiles applied.
    expect(find.text('frame 1/6'), findsOneWidget);
    expect(find.text('1/16×'), findsOneWidget);
    expect(find.text('AI ×2'), findsOneWidget);
    // Autoplay advances at 1/16× (33ms / 0.0625 = 528ms per frame).
    // The playback timer was armed in the fake-async zone (the review
    // future started outside runAsync), so advance the fake clock.
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('frame 2/6'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
