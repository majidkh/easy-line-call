// =============================================================================
// LINE CALLING — video frame access facade.
//
// The calibration screen needs three things from a picked video: its
// duration, a still frame at an arbitrary time (for the scrub-and-calibrate
// flow), and a playback controller. The native implementation rides on
// dart:io + the video_thumbnail plugin; neither exists on Flutter web, where
// an HTML5 <video> + <canvas> does the same job on the picker's blob URL.
//
// Pure compile-time selection (same idea as sr_service.dart): importers see
// one API — videoDurationMs / grabVideoFrame / createVideoController /
// releaseVideoFrameResources — and the web build never touches dart:io.
// =============================================================================

export 'video_frames_io.dart'
    if (dart.library.js_interop) 'video_frames_web.dart';
