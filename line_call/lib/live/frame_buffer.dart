// Live challenge buffer: the last 2 minutes of the camera feed as
// downscaled JPEG stills, so any recent moment can be challenged and
// reviewed without a video file. ~10 fps × 120 s × ~25 KB ≈ 30 MB worst.
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class BufferedFrame {
  final Uint8List jpeg;
  final double ms; // same clock the tracker stamps scan frames with
  final int width, height;
  const BufferedFrame(this.jpeg, this.ms, this.width, this.height);
}

class LiveBuffer {
  static const int capacity = 1200; // 2 min @ 10 fps
  static const int maxWidth = 480;
  static const double windowMs = 120 * 1000;

  final List<BufferedFrame> _frames = [];

  List<BufferedFrame> get frames => _frames;
  bool get isEmpty => _frames.isEmpty;

  /// Store one RGBA frame ([ms] on the tracker's clock), downscaled.
  void add(Uint8List rgba, int w, int h, double ms) {
    if (w <= 0 || h <= 0 || rgba.length < w * h * 4) return;
    final src = img.Image.fromBytes(
        width: w, height: h, bytes: rgba.buffer, numChannels: 4);
    final small = w > maxWidth
        ? img.copyResize(src, width: maxWidth)
        : img.copyResize(src, width: w);
    final jpg = img.encodeJpg(small, quality: 70);
    _frames.add(BufferedFrame(
        Uint8List.fromList(jpg), ms, small.width, small.height));
    // Evict by count and by age (keep the last 2 minutes).
    while (_frames.length > capacity) {
      _frames.removeAt(0);
    }
    while (_frames.length > 1 && ms - _frames.first.ms > windowMs) {
      _frames.removeAt(0);
    }
  }

  /// Frames within ±[halfMs] of [centerMs], time ascending.
  List<BufferedFrame> window(double centerMs, double halfMs) => [
        for (final f in _frames)
          if ((f.ms - centerMs).abs() <= halfMs) f
      ];

  void clear() => _frames.clear();
}
