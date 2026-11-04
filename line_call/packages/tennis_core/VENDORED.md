# tennis_core — muse2 engine as a Flutter FFI plugin

The line-calling engine is the **muse2** core, byte-identical, compiled into
the app and driven over FFI. Do not edit the copied files to tune behaviour;
change them in `muse2/core` and re-copy so both stay identical.

## What is copied

| Here | muse2 source |
|---|---|
| `darwin/Classes/include/tennis/*` | `core/include/tennis/*` |
| `darwin/Classes/src/*.cpp` | `core/src/*.cpp` (minus `infer_stub.cpp`) |
| `darwin/Classes/apple/infer_apple.mm` | `core/apple/infer_apple.mm` |
| `assets/models/BallHeatANE.mlpackage` (app) | `models/BallHeatANE.mlpackage` |

The `setmatch_shim.*` pixel helpers (`sm_rgba_to_bgr`, `sm_bgr_to_gray`,
`sm_resize_bgr`) ship alongside the core; the Dart bindings use them when
present and fall back to identical Dart arithmetic otherwise.

The only app-side build settings are the podspec's deployment targets
(`osx` 13.0, `ios` 15.0 — the floors current Xcode SDKs accept).

## What is ported (Dart, `lib/src/`)

The Python glue muse2 runs around the core, line for line:

- `driver.dart` — `umpire/driver.py` `ChunkDriver` (== `StreamAnalyzer.step`):
  24-frame chunks, ANE inference every 3rd frame on consecutive triplets.
- `recover.dart` — `tennis_ai/recover.py` (densify, blind-gap recovery,
  trailing window, gray ring) and `StreamSession` with `fast_config()`.
- `core.dart` — `tennis_ai/core_bind.py`.

Settings are muse2's default "fast" mode (desktop app + umpire app): ANE
model, stride 3, chunk 24, 1280 px processing width, recovery on, court filter
on. (Turbo's quantized build outputs all-zero heat on this Core ML runtime.)

Parity: on the first 900 frames of `rally_30s.mp4`, the Dart driver and
muse2's Python `ChunkDriver` (both over the same core) produce identical
candidates, tracks and rallies. Gray frames use OpenCV's 15-bit
`BGR2GRAY` formula (`setmatch_shim.cpp`), bit-exact with `cv2.cvtColor`.

## Differences from muse2 that are input plumbing, not algorithm

- Frames come from AVFoundation scaled to 1280 px (muse2 desktop decodes full
  resolution and `cv2.resize`s).
- Calibration frames for a video are 8 stills over ±10 s around the chosen
  frame (muse2 `calibrate_around`), grabbed at 1280 px.
- Clips above ~60 fps are thinned to ~60 fps before detection.

## Re-syncing

From `muse2/line_call/packages/tennis_core`:

```sh
M=../../..
cp $M/core/include/tennis/*  darwin/Classes/include/tennis/
cp $M/core/src/*.cpp darwin/Classes/src/ && rm darwin/Classes/src/infer_stub.cpp
cp $M/core/apple/infer_apple.mm darwin/Classes/apple/
```
