// =============================================================================
// LINE CALLING — video frame access, native platforms (dart:io available).
// Duration via a throwaway VideoPlayerController, stills via the
// video_thumbnail plugin, playback straight from the file.
//
// macOS note: `video_thumbnail` ships no macOS implementation (its plugin call
// throws MissingPluginException), which left the calibration scrub view
// spinning forever. So on macOS we grab frames through a tiny native
// AVAssetImageGenerator channel instead (see macos/Runner/MainFlutterWindow).
// =============================================================================
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as vt;

const MethodChannel _macVideo = MethodChannel('line_call/video');

/// Video duration in milliseconds, 0 if it cannot be determined. The timeout
/// guards against a controller that never reaches `initialized` (which would
/// otherwise hang the calibration busy overlay indefinitely).
Future<double> videoDurationMs(String src) async {
  final ctrl = VideoPlayerController.file(File(src));
  try {
    await ctrl.initialize().timeout(const Duration(seconds: 8));
    return ctrl.value.duration.inMilliseconds.toDouble();
  } catch (_) {
    return 0;
  } finally {
    await ctrl.dispose();
  }
}

/// JPEG still of the frame at [ms], capped at [maxWidth]; null on failure.
Future<Uint8List?> grabVideoFrame(String src, double ms,
    {int maxWidth = 1920}) async {
  if (Platform.isMacOS) {
    // video_thumbnail has no macOS impl → use the native AVFoundation channel.
    try {
      return await _macVideo.invokeMethod<Uint8List>('grabFrame', {
        'path': src,
        'timeMs': ms.round(),
        'maxWidth': maxWidth,
      });
    } catch (_) {
      return null;
    }
  }
  return vt.VideoThumbnail.thumbnailData(
    video: src,
    imageFormat: vt.ImageFormat.JPEG,
    maxWidth: maxWidth,
    quality: 95,
    timeMs: ms.round(),
  );
}

VideoPlayerController createVideoController(String src) =>
    VideoPlayerController.file(File(src));

/// No platform resources are cached on native.
void releaseVideoFrameResources() {}

// --------------------------------------------------------------------------- //
// Sequential frame reader (macOS + iOS + Android) — decodes frames in order
// (AVAssetReader on Apple, a reused MediaMetadataRetriever on Android) instead
// of seeking to each timestamp / re-opening the file every call (seconds/frame).
// Returns at most one frame per [minIntervalMs] of video time. Wired on macOS
// (MainFlutterWindow), iOS (AppDelegate) and Android (MainActivity, API 28+);
// elsewhere [openVideoReader] returns false and the caller falls back to
// grabVideoFrame.
// --------------------------------------------------------------------------- //

/// Start a sequential read from [startMs]; returns false if unavailable (then
/// fall back to stepping grabVideoFrame). [cvColor] returns the pixels OpenCV
/// would decode (BT.601 from the raw YUV, HDR ignored, cv2-style resize) —
/// what the muse2 engine was tuned on — instead of colour-managed display
/// frames.
Future<bool> openVideoReader(String src,
    {double startMs = 0,
    int maxWidth = 1280,
    int minIntervalMs = 30,
    bool cvColor = false}) async {
  if (!Platform.isMacOS && !Platform.isIOS && !Platform.isAndroid) return false;
  try {
    return await _macVideo.invokeMethod<bool>('openReader', {
          'path': src,
          'startMs': startMs,
          'maxWidth': maxWidth,
          'minIntervalMs': minIntervalMs,
          'cvColor': cvColor,
        }) ??
        false;
  } catch (e) {
    debugPrint('[reader] openReader failed: $e');
    return false;
  }
}

/// The next decoded frame as RAW RGBA bytes + its width/height + its real
/// presentation time in ms (or −1 if the platform didn't report one), or null at
/// end of stream / on error. Raw (not JPEG) so the caller skips a decode + GPU
/// readback — the whole point of the fast path. The ms lets a caller place a frame
/// at its true video time instead of assuming a fixed inter-frame spacing.
Future<(Uint8List, int, int, double)?> nextVideoFrame() async {
  if (!Platform.isMacOS && !Platform.isIOS && !Platform.isAndroid) return null;
  try {
    final m = await _macVideo.invokeMapMethod<String, dynamic>('nextFrame');
    if (m == null) return null;
    final bytes = m['bytes'] as Uint8List?;
    final w = (m['width'] as num?)?.toInt() ?? 0;
    final h = (m['height'] as num?)?.toInt() ?? 0;
    final ms = (m['ms'] as num?)?.toDouble() ?? -1.0;
    if (bytes == null || w <= 0 || h <= 0) return null;
    return (bytes, w, h, ms);
  } catch (_) {
    return null;
  }
}

Future<void> closeVideoReader() async {
  if (!Platform.isMacOS && !Platform.isIOS && !Platform.isAndroid) return;
  try {
    await _macVideo.invokeMethod('closeReader');
  } catch (_) {}
}
