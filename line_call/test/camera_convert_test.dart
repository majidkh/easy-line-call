import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/live/camera_convert.dart';

void main() {
  test('bgraToRgba swaps channels and skips row padding', () {
    // 2x1 image, row stride 12 (4 padding bytes).
    final bgra = Uint8List.fromList([
      10, 20, 30, 255, // B G R A
      40, 50, 60, 128,
      0, 0, 0, 0, // padding
    ]);
    final out = bgraToRgba(bgra, 2, 1, 12);
    expect(out.width, 2);
    expect(out.height, 1);
    expect(out.bytes, [30, 20, 10, 255, 60, 50, 40, 128]);
  });

  test('yuv420ToRgba maps gray and colors', () {
    // 2x2, neutral chroma (128,128) → gray ramp from luma.
    final y = Uint8List.fromList([0, 255, 64, 192]);
    final u = Uint8List.fromList([128]);
    final v = Uint8List.fromList([128]);
    final out = yuv420ToRgba(
      y: y,
      u: u,
      v: v,
      width: 2,
      height: 2,
      yRowStride: 2,
      uvRowStride: 1,
      uvPixelStride: 1,
    );
    expect(out.bytes.length, 16);
    // Luma passes through, alpha opaque.
    expect(out.bytes[0], 0);
    expect(out.bytes[4], 255);
    expect(out.bytes[8], 64);
    expect(out.bytes[12], 192);
    for (var i = 3; i < 16; i += 4) {
      expect(out.bytes[i], 255);
    }
    // Neutral chroma → r == g == b.
    for (var i = 0; i < 16; i += 4) {
      expect(out.bytes[i], out.bytes[i + 1]);
      expect(out.bytes[i], out.bytes[i + 2]);
    }
  });

  test('yuv420ToRgba renders red for high V', () {
    final y = Uint8List.fromList([128, 128, 128, 128]);
    final u = Uint8List.fromList([128]);
    final v = Uint8List.fromList([255]);
    final out = yuv420ToRgba(
      y: y,
      u: u,
      v: v,
      width: 2,
      height: 2,
      yRowStride: 2,
      uvRowStride: 1,
      uvPixelStride: 1,
    );
    // Strong red push: r maxes, b stays low.
    expect(out.bytes[0], 255);
    expect(out.bytes[2], lessThan(200));
  });
}
