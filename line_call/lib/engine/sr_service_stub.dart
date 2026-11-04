// =============================================================================
// LINE CALLING — super-resolution stub used on platforms without dart:io
// (currently: Flutter web). Matches the API of sr_service_io.dart but does
// no inference; upscalePatch always returns null, so the magnifier falls
// back to nearest sampling on the raw source image.
// =============================================================================

import 'dart:async';
import 'dart:ui' as ui;

class SrResult {
  final ui.Image tile;
  final ui.Rect sourceRect;

  SrResult({required this.tile, required this.sourceRect});

  void dispose() => tile.dispose();
}

class SrService {
  SrService._();
  static final SrService instance = SrService._();

  bool get available => false;

  Future<ui.Image?> upscale2x(ui.Image src,
          {void Function(double progress)? onProgress}) async =>
      null;

  Future<ui.Image?> upscale4x(ui.Image src,
          {void Function(double progress)? onProgress}) async =>
      null;

  Future<SrResult?> upscalePatch(ui.Image source, ui.Offset center) async =>
      null;
}
