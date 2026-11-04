import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:line_call/live/frame_buffer.dart';

void main() {
  Uint8List rgba(int w, int h, int v) =>
      Uint8List.fromList(List<int>.filled(w * h * 4, v));

  test('add stores downscaled JPEGs and window slices by time', () {
    final buf = LiveBuffer();
    for (var i = 0; i < 10; i++) {
      buf.add(rgba(640, 360, i * 10), 640, 360, i * 100.0);
    }
    expect(buf.frames.length, 10);
    expect(buf.frames.first.width, LiveBuffer.maxWidth);
    // JPEG magic bytes.
    expect(buf.frames.first.jpeg[0], 0xFF);
    expect(buf.frames.first.jpeg[1], 0xD8);

    final slice = buf.window(450, 100);
    expect([for (final f in slice) f.ms], [400.0, 500.0]);
  });

  test('evicts beyond capacity and the 2-minute window', () {
    final buf = LiveBuffer();
    for (var i = 0; i < LiveBuffer.capacity + 50; i++) {
      buf.add(rgba(32, 18, 7), 32, 18, i * 100.0);
    }
    expect(buf.frames.length, LiveBuffer.capacity);

    buf.clear();
    buf.add(rgba(32, 18, 7), 32, 18, 0);
    buf.add(rgba(32, 18, 7), 32, 18, LiveBuffer.windowMs + 1000);
    expect(buf.frames.length, 1);
    expect(buf.frames.first.ms, LiveBuffer.windowMs + 1000);
  });
}
