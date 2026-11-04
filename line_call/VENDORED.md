# Vendored code

## `packages/tennis_core` — muse2 core (FFI)

Byte-identical copy of `muse2/core/{include,src}` (court fit, detector,
session, judge) plus the Dart FFI bindings in `lib/` and the
`darwin/tennis_core.podspec` (macOS 13 / iOS 15 floors for current Xcode).

Re-sync recipe (from `muse2/`):

```sh
for f in core/src/*.cpp core/src/*.h core/include/tennis/*.hpp; do
  # mirror into packages/tennis_core/darwin/Classes/{src,include}/
done
```

i.e. copy each `core/src/*` → `darwin/Classes/src/*` and each
`core/include/tennis/*` → `darwin/Classes/include/tennis/*`, then
`diff -r` to confirm byte-identical (only the podspec/hook deltas stay).

Model notes (kept in sync by the recipe above):

- Service lines sit at |y| = 6.40 m from the court centre (6.40 m from the
  net, 5.485 m from the baseline) — `kServY`, `kModelLines`, `ycomb`.
- Across-role assignment needs seed-caliber pixel support
  (`length >= 250 * w / 1280`): short far fragments lever the fit under
  foreshortening, so they stay unassigned instead of taking roles.
- `CalibrateFrames` fits the median plus every member frame and keeps the
  best verified fit by model support: the median erases players but can
  dilute thin lines below threshold, single frames the reverse.
- Rotated back-of-court views: every pool line is an along candidate and
  dual-pooled lines take their axis from world shape under each seed H0
  (image angle alone cannot separate sidelines from baselines in rotation).
- Fit gates before scoring: near-court scale floor (3 px/m per model axis),
  convex court-quad projection, and a redundant 5th keypoint — stretched,
  twisted, and axis-swapped exact fits fail instead of false-passing.
- Bounce V-bottoms tolerate interpolated shoulders (nearest observed within
  the ±6 fit windows) and gap amplitude is measured against the legs' far
  ends: impact frames the detector misses no longer hide the bounce.
- Bounce amplitude has a camera-aware relief: a coherent V shallower than
  2.5px still counts when it spans >=0.12m on the calibrated court
  (far/grazing views), never below a 1px noise floor or without a court.
- Rally segmentation keeps validated impacts: events orphaned in dead-zone
  cut gaps attach to the nearest bound (ties to the previous), and a bound
  holding a hit/bounce is live play unless it is sub-jitter still — the old
  image-x-range gate vetoed depth rallies shot from behind the court.
- NOTE: rally.cpp FindServe, roi.cpp and DetectShots in
  tracker_events.cpp carry newer Python-twin ports that core/ lacks
  (pre-existing drift); SegmentRallies and DetectBounces are kept
  byte-identical in both copies.

## `packages/dartcv4` — OpenCV backend

Vendored `dartcv4-2.2.2` with the Apple deployment-target fix in
`lib/src/hook_helpers/run_build.dart` (macOS takes the toolchain default,
iOS pinned to 15 to match `ios/Podfile`). Revisit on Flutter/Xcode upgrade.
`analyzer.exclude` covers this tree.
