#!/usr/bin/env bash
# Build & run the Easy Line Call Flutter app (line_call/) for mac, ios,
# android or web — same style as the SetMatch build scripts.
#
#   ./build_linecall.sh [mac|ios|android|web] [clean] [--no-run] [--debug] [bundle]
#
#   target   mac (default), ios, android, web
#   clean    full `flutter clean` first (default: incremental, like SetMatch)
#   --no-run build only, don't launch (mac/android) or serve (web);
#            ios: generate the Xcode project but don't open Xcode
#   --debug  debug build (default: release)
#   bundle   android only: build a store .aab instead of an installable .apk
#
# The ios target does NOT build or sign: it refreshes the Xcode project
# (`flutter build ios --config-only` + `pod install`) and opens
# ios/Runner.xcworkspace in Xcode, where signing (team, bundle id,
# provisioning) and the device run happen.
#
# Environment:
#   FLUTTER_SDK  Flutter SDK root (default: `flutter` from PATH)
#   ANDROID_HOME Android SDK for the android target
#                (default: ~/Library/Android/sdk)
#
# Missing platform shells (ios/, android/, web/) are scaffolded on first use
# with `flutter create`; mac/ already exists. The ios target runs
# `pod install` first, like the SetMatch script does.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/line_call"

TARGET="mac"
CLEAN=false
RUN=true
MODE="release"
BUNDLE=false

usage() {
  sed -n '2,26p' "$0"
  echo "Examples:"
  echo "  ./build_linecall.sh              # macOS app, release, run it"
  echo "  ./build_linecall.sh ios          # refresh Xcode project, open it"
  echo "  ./build_linecall.sh android --no-run   # release APK, no launch"
  echo "  ./build_linecall.sh web clean    # web, clean rebuild, serve on Chrome"
}

for arg in "$@"; do
  case "$arg" in
    mac|macos) TARGET="mac" ;;
    ios) TARGET="ios" ;;
    android) TARGET="android" ;;
    web) TARGET="web" ;;
    clean) CLEAN=true ;;
    --no-run) RUN=false ;;
    --debug) MODE="debug" ;;
    --release) MODE="release" ;;
    bundle) BUNDLE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg '$arg'" >&2; usage >&2; exit 1 ;;
  esac
done

# --- Flutter SDK (FLUTTER_SDK or PATH) ---
if [ -n "${FLUTTER_SDK:-}" ] && [ -x "$FLUTTER_SDK/bin/flutter" ]; then
  FLUTTER="$FLUTTER_SDK/bin/flutter"
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER="flutter"
else
  echo "error: no Flutter SDK (set FLUTTER_SDK)" >&2
  exit 1
fi

cd "$APP"

# --- Scaffold a missing platform shell (macos/ already exists) ---
PLATFORM="$TARGET"
if [ "$TARGET" = "mac" ]; then PLATFORM="macos"; fi
if [ ! -d "$APP/$PLATFORM" ]; then
  echo "==> scaffolding $PLATFORM platform shell"
  "$FLUTTER" create --platforms="$PLATFORM" .
fi

if [ "$TARGET" = "ios" ]; then
  # CocoaPods install is iOS-specific; other targets handle their own deps.
  (cd ios && pod install)
fi

if [ "$CLEAN" = true ]; then
  "$FLUTTER" clean
fi
"$FLUTTER" pub get

MODE_FLAG="--$MODE"

case "$TARGET" in
  mac)
    if [ "$RUN" = true ]; then
      "$FLUTTER" run "$MODE_FLAG" -d macos
    else
      "$FLUTTER" build macos "$MODE_FLAG"
    fi
    ;;
  ios)
    # Xcode owns the iOS build: refresh the project files, then hand off.
    # Signing, devices and running all happen in Xcode — nothing Apple-ID
    # related lives in this script.
    "$FLUTTER" build ios --config-only
    if [ "$RUN" = true ]; then
      echo "==> opening ios/Runner.xcworkspace in Xcode"
      open "$APP/ios/Runner.xcworkspace"
    else
      echo "==> Xcode project refreshed (--no-run: not opening Xcode)"
    fi
    ;;
  android)
    # AGP needs the NDK's `llvm-strip`; export the SDK path so it is found
    # reliably (same as SetMatch's build-bundle.sh).
    export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
    export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
    if [ "$RUN" = true ]; then
      "$FLUTTER" run "$MODE_FLAG"
    elif [ "$BUNDLE" = true ]; then
      "$FLUTTER" build appbundle "$MODE_FLAG"
    else
      "$FLUTTER" build apk "$MODE_FLAG"
    fi
    ;;
  web)
    if [ "$RUN" = true ]; then
      "$FLUTTER" run "$MODE_FLAG" -d chrome
    else
      "$FLUTTER" build web "$MODE_FLAG"
    fi
    ;;
esac
