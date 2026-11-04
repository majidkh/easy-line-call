// =============================================================================
// LINE CALLING — on-device super-resolution for the precision magnifier.
//
// Loads the ESRGAN-TF2 TFLite model bundled at assets/models/esrgan.tflite
// (4× super-res, 50×50 RGB float in [0, 255] → 200×200 RGB float in [0, 255]).
//
// Runs on iOS, Android, and the desktop platforms tflite_flutter supports.
// TFLite has no web backend, so [SrService.upscalePatch] returns null on web
// and callers fall back to nearest sampling on the (high-resolution) source.
//
// Acceleration: inference runs on a hardware delegate when one is available —
// Core ML (Neural Engine) preferred on iOS and macOS, then the Metal GPU;
// the GPU delegate on Android. These are thread-bound, so that path runs on
// the MAIN isolate (no IsolateInterpreter, which also removes the per-tile
// cross-isolate copy). If none can load/run we fall back to the CPU XNNPACK +
// worker-isolate path (other desktops, and where no delegate is available).
// =============================================================================

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter_litert/flutter_litert.dart';

class SrResult {
  /// 200×200 RGBA image produced by the model.
  final ui.Image tile;

  /// Region of the original source image (in source image pixel coords)
  /// that the tile covers. Width and height are always 50.
  final ui.Rect sourceRect;

  SrResult({required this.tile, required this.sourceRect});

  void dispose() => tile.dispose();
}

class SrService {
  SrService._();
  static final SrService instance = SrService._();

  Interpreter? _interp;
  IsolateInterpreter? _iso; // CPU path only; null when the GPU delegate runs
  // Retained so the native delegate outlives this app-lifetime singleton's
  // interpreter (never read).
  // ignore: unused_field
  Delegate? _delegate;
  Future<void>? _loading;
  bool _failed = false;

  bool get available => _interp != null && !_failed;
  bool get _ready => _interp != null && !_failed;

  Future<void> _ensureLoaded() async {
    if (kIsWeb || _failed || _interp != null) return;
    _loading ??= _doLoad();
    await _loading;
  }

  Future<void> _doLoad() async {
    const asset = 'assets/models/esrgan.tflite';
    // Hardware delegates, best-first (Core ML / Neural Engine, then Metal on
    // iOS; GPU on Android). Each is thread-bound, so the chosen interpreter
    // runs on THIS (main) isolate — no IsolateInterpreter. A dummy warm-up
    // doubles as a health check: the first delegate that loads AND runs the
    // graph wins; anything that throws (simulator, missing native lib,
    // unsupported op) is skipped.
    for (final make in _delegates()) {
      Delegate? delegate;
      try {
        delegate = make();
        final opts = InterpreterOptions()..addDelegate(delegate);
        final interp = await Interpreter.fromAsset(asset, options: opts);
        _warmup(interp);
        _interp = interp;
        _delegate = delegate;
        return;
      } catch (_) {
        _interp?.close();
        _interp = null;
        try {
          delegate?.delete();
        } catch (_) {}
      }
    }
    // CPU fallback: inference on the worker isolate (XNNPACK). Used on desktop
    // and wherever no hardware delegate could load.
    try {
      _interp = await Interpreter.fromAsset(asset);
      _iso = await IsolateInterpreter.create(address: _interp!.address);
    } catch (_) {
      _failed = true;
      _interp?.close();
      _interp = null;
      _iso = null;
    }
  }

  /// Hardware-delegate factories to try in order (best-first) on this platform:
  /// iOS and macOS prefer Core ML (Neural Engine), falling back to the Metal
  /// GPU (both dylibs ship in the app bundle); Android uses the GPU delegate;
  /// other desktops stay on CPU. FP16 (precision loss) is fine for image
  /// upscaling and faster.
  ///
  /// On macOS the Core ML delegate allows all devices: Macs without a Neural
  /// Engine (Intel) would otherwise refuse to create the delegate at all
  /// (noisy null-delegate error) instead of running Core ML on CPU/GPU.
  List<Delegate Function()> _delegates() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return [
          () => CoreMlDelegate(),
          () => GpuDelegate(options: GpuDelegateOptions(allowPrecisionLoss: true)),
        ];
      case TargetPlatform.macOS:
        return [
          () => CoreMlDelegate(
                options: CoreMlDelegateOptions(
                  // TfLiteCoreMlDelegateAllDevices (= 1): the generated
                  // bindings enum isn't exported by flutter_litert, so
                  // the native-header value is spelled out.
                  enabledDevices: 1,
                ),
              ),
          () => GpuDelegate(options: GpuDelegateOptions(allowPrecisionLoss: true)),
        ];
      case TargetPlatform.android:
        return [
          () => GpuDelegateV2(
              options: GpuDelegateOptionsV2(isPrecisionLossAllowed: true)),
        ];
      default:
        return const [];
    }
  }

  /// One inference on a zero tile: compiles the GPU shaders up front (so the
  /// first real tile isn't slow) and proves the delegate can run the graph.
  void _warmup(Interpreter interp) {
    final input = List.generate(
        1,
        (_) => List.generate(
            50, (_) => List.generate(50, (_) => List<double>.filled(3, 0))));
    final output = List.generate(
        1,
        (_) => List.generate(
            200, (_) => List.generate(200, (_) => List<double>.filled(3, 0))));
    interp.run(input, output);
  }

  /// Run one tile through whichever backend is active: the GPU interpreter on
  /// the main isolate (yielding afterwards so the progress UI can paint between
  /// tiles), or the CPU worker isolate.
  Future<void> _run(Object input, Object output) async {
    final iso = _iso;
    if (iso != null) {
      await iso.run(input, output);
    } else {
      _interp!.run(input, output);
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Whole-frame 2× neural upscale for pre-detection enhancement: tiles the
  /// 4× ESRGAN over [src] in 50×50 steps and composes each 200×200 output at
  /// 100×100 (net 2×). Edge tiles are clamped inward, so seams re-render the
  /// same source pixels. Returns null when SR is unavailable (web, model
  /// load failure), the source is smaller than one tile, or it is large
  /// enough that tiling would take unreasonably long — callers then fall
  /// back to the detector's plain bicubic path. [onProgress] gets 0..1.
  Future<ui.Image?> upscale2x(ui.Image src,
      {void Function(double progress)? onProgress}) async {
    if (kIsWeb) return null;
    await _ensureLoaded();
    if (!_ready) return null;
    const inSize = 50;
    const outSize = 200;
    if (src.width < inSize || src.height < inSize) return null;
    final cols = (src.width / inSize).ceil(), rows = (src.height / inSize).ceil();
    // covers the detector-width-normalized frames (1400px wide: 28x16=448
    // landscape, up to ~588 portrait-ish) that every calibration source is
    // now reduced to before the always-on 2x enhancement
    if (cols * rows > 600) return null;

    final bd = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return null;
    final rgba = bd.buffer.asUint8List();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
    final tiles = <ui.Image>[]; // disposed only after toImage rasterizes
    try {
      for (var ty = 0; ty < rows; ty++) {
        for (var tx = 0; tx < cols; tx++) {
          final left = (tx * inSize).clamp(0, src.width - inSize);
          final top = (ty * inSize).clamp(0, src.height - inSize);
          final input = List.generate(
            1,
            (_) => List.generate(
              inSize,
              (y) => List.generate(inSize, (x) {
                final i = ((top + y) * src.width + (left + x)) * 4;
                return <double>[
                  rgba[i].toDouble(),
                  rgba[i + 1].toDouble(),
                  rgba[i + 2].toDouble(),
                ];
              }),
            ),
          );
          final output = List.generate(
            1,
            (_) => List.generate(outSize,
                (_) => List.generate(outSize, (_) => List<double>.filled(3, 0))),
          );
          try {
            await _run(input, output);
          } catch (_) {
            return null;
          }
          final tile = await _outputToImage(output[0], outSize);
          tiles.add(tile);
          canvas.drawImageRect(
            tile,
            ui.Rect.fromLTWH(0, 0, outSize.toDouble(), outSize.toDouble()),
            ui.Rect.fromLTWH(left * 2.0, top * 2.0, inSize * 2.0, inSize * 2.0),
            paint,
          );
          onProgress?.call((ty * cols + tx + 1) / (rows * cols));
        }
      }
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(src.width * 2, src.height * 2);
      } catch (_) {
        return null;
      } finally {
        picture.dispose();
      }
    } finally {
      for (final t in tiles) {
        t.dispose();
      }
    }
  }

  /// Whole-crop 4× neural upscale for the challenge magnifier: tiles the
  /// 4× ESRGAN over [src] in 50×50 steps and composes each 200×200 output
  /// at full size (net 4×). Same tile (and inference) count as [upscale2x]
  /// for the same crop — only the composition is sharper. Edge tiles are
  /// clamped inward, so seams re-render the same source pixels. Returns
  /// null when SR is unavailable (web, model load failure), the source is
  /// smaller than one tile, or tiling would take unreasonably long.
  /// [onProgress] gets 0..1.
  Future<ui.Image?> upscale4x(ui.Image src,
      {void Function(double progress)? onProgress}) async {
    if (kIsWeb) return null;
    await _ensureLoaded();
    if (!_ready) return null;
    const inSize = 50;
    const outSize = 200;
    if (src.width < inSize || src.height < inSize) return null;
    final cols = (src.width / inSize).ceil(), rows = (src.height / inSize).ceil();
    if (cols * rows > 600) return null;

    final bd = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) return null;
    final rgba = bd.buffer.asUint8List();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
    final tiles = <ui.Image>[]; // disposed only after toImage rasterizes
    try {
      for (var ty = 0; ty < rows; ty++) {
        for (var tx = 0; tx < cols; tx++) {
          final left = (tx * inSize).clamp(0, src.width - inSize);
          final top = (ty * inSize).clamp(0, src.height - inSize);
          final input = List.generate(
            1,
            (_) => List.generate(
              inSize,
              (y) => List.generate(inSize, (x) {
                final i = ((top + y) * src.width + (left + x)) * 4;
                return <double>[
                  rgba[i].toDouble(),
                  rgba[i + 1].toDouble(),
                  rgba[i + 2].toDouble(),
                ];
              }),
            ),
          );
          final output = List.generate(
            1,
            (_) => List.generate(outSize,
                (_) => List.generate(outSize, (_) => List<double>.filled(3, 0))),
          );
          try {
            await _run(input, output);
          } catch (_) {
            return null;
          }
          final tile = await _outputToImage(output[0], outSize);
          tiles.add(tile);
          canvas.drawImageRect(
            tile,
            ui.Rect.fromLTWH(0, 0, outSize.toDouble(), outSize.toDouble()),
            ui.Rect.fromLTWH(
                left * 4.0, top * 4.0, inSize * 4.0, inSize * 4.0),
            paint,
          );
          onProgress?.call((ty * cols + tx + 1) / (rows * cols));
        }
      }
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(src.width * 4, src.height * 4);
      } catch (_) {
        return null;
      } finally {
        picture.dispose();
      }
    } finally {
      for (final t in tiles) {
        t.dispose();
      }
    }
  }

  /// Upscale a 50×50 image-pixel patch of [source] centered (best-effort) on
  /// [center] (in source image pixel coords). Returns the 200×200 tile and
  /// the source rect it covers, or null if SR is unavailable (web, model
  /// load failure, or source smaller than 50×50).
  Future<SrResult?> upscalePatch(ui.Image source, ui.Offset center) async {
    if (kIsWeb) return null;
    await _ensureLoaded();
    if (!_ready) return null;

    const inSize = 50;
    const outSize = 200;
    if (source.width < inSize || source.height < inSize) return null;

    final left = (center.dx - inSize / 2)
        .clamp(0.0, (source.width - inSize).toDouble());
    final top = (center.dy - inSize / 2)
        .clamp(0.0, (source.height - inSize).toDouble());
    final patchRect =
        ui.Rect.fromLTWH(left, top, inSize.toDouble(), inSize.toDouble());

    final input = await _extractPatch(source, patchRect, inSize);
    if (input == null) return null;

    final output = List.generate(
      1,
      (_) => List.generate(
        outSize,
        (_) => List.generate(outSize, (_) => List<double>.filled(3, 0)),
      ),
    );

    try {
      await _run(input, output);
    } catch (_) {
      return null;
    }

    final tile = await _outputToImage(output[0], outSize);
    return SrResult(tile: tile, sourceRect: patchRect);
  }

  /// Render the 50×50 patch through a PictureRecorder and read its raw RGBA
  /// bytes, then pack into the [1, 50, 50, 3] float buffer the model expects.
  Future<List<List<List<List<double>>>>?> _extractPatch(
      ui.Image source, ui.Rect rect, int size) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      rect,
      ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.none,
    );
    final picture = recorder.endRecording();
    ui.Image patch;
    try {
      patch = await picture.toImage(size, size);
    } catch (_) {
      return null;
    } finally {
      picture.dispose();
    }
    ByteData? bd;
    try {
      bd = await patch.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      patch.dispose();
    }
    if (bd == null) return null;
    final rgba = bd.buffer.asUint8List();

    return List.generate(
      1,
      (_) => List.generate(
        size,
        (y) => List.generate(
          size,
          (x) {
            final i = (y * size + x) * 4;
            return <double>[
              rgba[i].toDouble(),
              rgba[i + 1].toDouble(),
              rgba[i + 2].toDouble(),
            ];
          },
        ),
      ),
    );
  }

  Future<ui.Image> _outputToImage(
      List<List<List<double>>> output, int size) async {
    final rgba = Uint8List(size * size * 4);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final px = output[y][x];
        final i = (y * size + x) * 4;
        rgba[i] = px[0].clamp(0.0, 255.0).toInt();
        rgba[i + 1] = px[1].clamp(0.0, 255.0).toInt();
        rgba[i + 2] = px[2].clamp(0.0, 255.0).toInt();
        rgba[i + 3] = 255;
      }
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      size,
      size,
      ui.PixelFormat.rgba8888,
      (image) => completer.complete(image),
    );
    return completer.future;
  }
}
