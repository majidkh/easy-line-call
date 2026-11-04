# Vendored dartcv4 2.2.2

Copied from pub.dev (`dartcv4-2.2.2`, the OpenCV native backend behind
`opencv_dart`) with one fix in `lib/src/hook_helpers/run_build.dart`:

- Rework the hook's hardcoded `DEPLOYMENT_TARGET` CMake defines (10.15 for
  macOS, 12.0 for iOS). They overrode the `native_toolchain_cmake` value that
  follows the Flutter tool's hardcoded target version (13 for macOS, 13 for
  iOS), and current Xcode SDKs refuse to compile for any of 10.15 / 12.0 /
  13-for-iOS, breaking every macOS/iOS build and `flutter test` run. Now
  macOS takes the toolchain's 13 (valid: the macOS floor is 12.0) and iOS is
  pinned to 15 (keep in sync with `ios/Podfile`). Upstream went conditional
  in dartcv4 2.3.1, but 2.3.1 needs `meta ^1.19` / `record_use ^1.1`, which
  this Flutter SDK pins below, so it cannot resolve here yet.

Wired via a `dependency_overrides` entry in `line_call/pubspec.yaml`.
To un-vendor: delete this folder + the override once `opencv_dart` resolves a
fixed `dartcv4` with the project's Flutter SDK.
