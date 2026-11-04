# Easy Line Call (Flutter)

Author: Majid Khosravi

Copyright © 2026 Majid Khosravi. All rights reserved.

Phone-first tennis line calling, landscape everywhere (the desktop window
opens landscape too). Three screens:

1. **Home** — big `Easy Line Call` title + racket icon, then the two
   feeds: `process video` (pick a clip) and `live feed` (phone camera).
   Everything downstream behaves the same; only the frame source differs.
2. **Calibrate** — video: scrub to a frame with the slider, tap Calibrate.
   Live: tap Calibrate to freeze the current camera frame. The court is
   fitted and drawn over the frame; Confirm to track or Recalibrate.
3. **Track** — video: a full scan pass with a progress bar, then playback
   with ball trails, bounce rings and court lines. Live: the camera preview
   processes in real time. Right panel: **Challenge** button, translucent
   court minimap with bounce dots, bounce list with times.
4. **Challenge** — the last 10 bounces (tap to review ±0.5 s at 10x with
   slow motion), plus a 2-minute footage scrubber: slide anywhere, tap the
   preview where the bounce is, review that moment.

Simplifications vs the previous UI: doubles lines always (no format
toggle), whole court always, no manual court adjust, no 3D simulate view.

## Build & run

From `muse2/`:

```sh
./build_linecall.sh                 # macOS app, release, run it
./build_linecall.sh ios             # refresh Xcode project, open it (sign + run in Xcode)
./build_linecall.sh android --no-run  # release APK, no launch
./build_linecall.sh web             # release, serve on Chrome
./build_linecall.sh --help          # clean / --no-run / --debug / bundle
```

Missing platform shells are scaffolded on first use. First build per
platform compiles OpenCV from source via the `dartcv4` hook (one-time each,
~10-30 min, cached under `.dart_tool/`). The SDK is taken from `PATH`
(`FLUTTER_SDK` overrides).

## Layout

- `lib/main.dart` — landscape lock, theme, home.
- `lib/ui/` — `home_page`, `calibrate_page`, `track_page`,
  `challenge_page`, `court_overlay` (all new, phone-first).
- `lib/live/` — `camera_convert` (CameraImage→RGBA, tested),
  `frame_buffer` (2-minute live ring buffer for challenges, tested).
- `lib/engine/` — reused detection plumbing: `muse_bridge` (engine
  facade), `muse_court` (court frames), `court_geometry` + `court_minimap`,
  `video_frames` (file/reader access), `sr_service` (review upscaling),
  `vline_*` (classical calibration fallback).
- `packages/tennis_core/` — FFI plugin with the byte-identical muse2 core
  (see `VENDORED.md`); macOS/iOS only.
- `packages/dartcv4/` — vendored OpenCV backend with the Apple
  deployment-target fix (see `VENDORED.md`).
- Native video readers (fast sequential decode for scans + reviews):
  `macos/.../MainFlutterWindow.swift`,
  `ios/.../AppDelegate.swift`,
  `android/.../MainActivity.kt`, all on the `line_call/video` channel.
- `assets/models/` — `BallHeatANE.mlpackage` + `esrgan.tflite`.
- `tool/macos/lipo-shim/` — temporary Xcode 27 workaround (see its README).

## Platform notes

- Deployment floors for current Xcode: macOS 13, iOS 15.
- The engine (court fit + ball detector) builds for macOS/iOS only.
  Elsewhere calibration falls back to the classical detector and tracking
  says so honestly. Android builds but is unverified here (no Android SDK
  on this machine); the native reader + camera permission are wired.
- Live tracking streams camera frames through the engine; the challenge
  buffer keeps ~10 fps downscaled stills for the last 2 minutes.
