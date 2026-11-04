// =============================================================================
// LINE CALLING — video frame access, Flutter web.
//
// The picker hands us a blob: URL. A hidden HTML5 <video> element seeks to
// the requested time and a <canvas> rasterizes the frame to JPEG bytes —
// there is no video_thumbnail plugin on web. The element is cached per URL
// so scrubbing seeks the already-decoded video instead of reloading it.
// Playback uses VideoPlayerController.networkUrl, which video_player_web
// accepts for blob URLs.
// =============================================================================
import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

web.HTMLVideoElement? _cached;
String? _cachedSrc;

Future<web.HTMLVideoElement?> _element(String src) async {
  if (_cached != null && _cachedSrc == src) return _cached;
  releaseVideoFrameResources();
  final v = web.HTMLVideoElement()
    ..src = src
    ..muted = true
    ..preload = 'auto';
  _cached = v;
  _cachedSrc = src;
  try {
    await web.EventStreamProviders.loadedMetadataEvent
        .forTarget(v)
        .first
        .timeout(const Duration(seconds: 20));
  } catch (_) {
    releaseVideoFrameResources();
    return null;
  }
  return v;
}

/// Video duration in milliseconds, 0 if it cannot be determined.
Future<double> videoDurationMs(String src) async {
  final v = await _element(src);
  final d = v?.duration ?? 0; // seconds; NaN/Infinity while unknown
  return d.isFinite && d > 0 ? d * 1000.0 : 0.0;
}

/// JPEG still of the frame at [ms], capped at [maxWidth]; null on failure.
Future<Uint8List?> grabVideoFrame(String src, double ms,
    {int maxWidth = 1920}) async {
  final v = await _element(src);
  if (v == null) return null;
  final dur = v.duration;
  var t = ms / 1000.0;
  if (dur.isFinite && dur > 0) {
    t = t.clamp(0.0, dur - 0.05 > 0 ? dur - 0.05 : 0.0);
  }
  // subscribe before seeking; a tiny epsilon forces a real seek (and so a
  // 'seeked' event) even when the requested time equals the current one
  final seeked = web.EventStreamProviders.seekedEvent.forTarget(v).first;
  v.currentTime = t < 0.001 ? 0.001 : t;
  try {
    await seeked.timeout(const Duration(seconds: 20));
  } catch (_) {
    return null;
  }
  final w0 = v.videoWidth, h0 = v.videoHeight;
  if (w0 == 0 || h0 == 0) return null;
  final scale = w0 > maxWidth ? maxWidth / w0 : 1.0;
  final w = (w0 * scale).round(), h = (h0 * scale).round();
  final canvas = web.HTMLCanvasElement()
    ..width = w
    ..height = h;
  final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
  ctx.drawImage(v, 0, 0, w, h);
  final dataUrl = canvas.toDataURL('image/jpeg', 0.92.toJS);
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return null;
  return base64Decode(dataUrl.substring(comma + 1));
}

// Sequential reader is native-only; web tracking would fall back to seeking.
Future<bool> openVideoReader(String src,
        {double startMs = 0,
        int maxWidth = 1280,
        int minIntervalMs = 30,
        bool cvColor = false}) async =>
    false;
Future<(Uint8List, int, int, double)?> nextVideoFrame() async => null;
Future<void> closeVideoReader() async {}

VideoPlayerController createVideoController(String src) =>
    VideoPlayerController.networkUrl(Uri.parse(src));

/// Detach and release the cached <video> element.
void releaseVideoFrameResources() {
  final v = _cached;
  if (v != null) {
    v.removeAttribute('src');
    v.load();
  }
  _cached = null;
  _cachedSrc = null;
}
