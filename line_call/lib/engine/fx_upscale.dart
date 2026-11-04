// =============================================================================
// LINE CALLING — device built-in 2x upscale (MetalFX spatial scaler, one
// GPU pass per crop, milliseconds) for the challenge review magnifier. The
// magnifier shows the 2x tile at 4x with a bicubic second step. Returns
// null wherever MetalFX is unavailable (old OS, simulator without Metal,
// web) and the magnifier falls back to plain bicubic.
// =============================================================================
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;

const MethodChannel _video = MethodChannel('line_call/video');

/// RGBA [w]×[h] → 2x BGRA bytes (+ new dims) via the native MetalFX twins
/// (macOS + iOS); null on any failure.
Future<({Uint8List bgra, int w, int h})?> fxUpscale2x(
    Uint8List rgba, int w, int h) async {
  try {
    final m = await _video.invokeMethod<Map>(
        'srUpscale2x', {'bytes': rgba, 'width': w, 'height': h});
    if (m == null) return null;
    final bytes = m['bytes'];
    if (bytes is! Uint8List) return null;
    return (
      bgra: bytes,
      w: (m['width'] as num?)?.toInt() ?? 0,
      h: (m['height'] as num?)?.toInt() ?? 0
    );
  } catch (_) {
    return null;
  }
}
