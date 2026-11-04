// CameraImage → tightly packed RGBA for the engine.
//
// iOS delivers one BGRA plane; Android delivers three YUV420 planes. Both
// converters are pure functions over plane bytes (stride-aware) so they can
// be unit-tested without a camera.
import 'dart:typed_data';

import 'package:camera/camera.dart';

class RgbaFrame {
  final Uint8List bytes; // width*height*4, tightly packed
  final int width, height;
  const RgbaFrame(this.bytes, this.width, this.height);
}

RgbaFrame? convertCameraImage(CameraImage image) {
  switch (image.format.group) {
    case ImageFormatGroup.bgra8888:
      if (image.planes.isEmpty) return null;
      final p = image.planes.first;
      return bgraToRgba(
          p.bytes, image.width, image.height, p.bytesPerRow);
    case ImageFormatGroup.yuv420:
      if (image.planes.length < 3) return null;
      return yuv420ToRgba(
        y: image.planes[0].bytes,
        u: image.planes[1].bytes,
        v: image.planes[2].bytes,
        width: image.width,
        height: image.height,
        yRowStride: image.planes[0].bytesPerRow,
        uvRowStride: image.planes[1].bytesPerRow,
        uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
      );
    default:
      return null;
  }
}

/// BGRA (one plane, [rowStride] bytes per row) → packed RGBA.
RgbaFrame bgraToRgba(Uint8List bgra, int w, int h, int rowStride) {
  final out = Uint8List(w * h * 4);
  var o = 0;
  for (var y = 0; y < h; y++) {
    var i = y * rowStride;
    for (var x = 0; x < w; x++, i += 4, o += 4) {
      out[o] = bgra[i + 2];
      out[o + 1] = bgra[i + 1];
      out[o + 2] = bgra[i];
      out[o + 3] = bgra[i + 3];
    }
  }
  return RgbaFrame(out, w, h);
}

/// YUV420 (BT.601 full-range-ish, the camera default) → packed RGBA.
RgbaFrame yuv420ToRgba({
  required Uint8List y,
  required Uint8List u,
  required Uint8List v,
  required int width,
  required int height,
  required int yRowStride,
  required int uvRowStride,
  required int uvPixelStride,
}) {
  final out = Uint8List(width * height * 4);
  var o = 0;
  for (var j = 0; j < height; j++) {
    final yRow = j * yRowStride;
    final uvRow = (j >> 1) * uvRowStride;
    for (var i = 0; i < width; i++, o += 4) {
      final yy = y[yRow + i];
      final uu = u[uvRow + (i >> 1) * uvPixelStride];
      final vv = v[uvRow + (i >> 1) * uvPixelStride];
      var r = yy + 1.402 * (vv - 128);
      var g = yy - 0.344136 * (uu - 128) - 0.714136 * (vv - 128);
      var b = yy + 1.772 * (uu - 128);
      r = r.clamp(0, 255);
      g = g.clamp(0, 255);
      b = b.clamp(0, 255);
      out[o] = r.toInt();
      out[o + 1] = g.toInt();
      out[o + 2] = b.toInt();
      out[o + 3] = 255;
    }
  }
  return RgbaFrame(out, width, height);
}
