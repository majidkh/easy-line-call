# tool/macos/lipo-shim — temporary Xcode 27 workaround

`lipo` here wraps the real `/usr/bin/lipo`: Xcode 27 changed `-verify_arch`
to accept a single architecture, but this Flutter SDK (3.44) passes all
architectures in one call when thinning `FlutterMacOS.framework`, failing
every macOS build. The shim loops single-arch verifies and passes everything
else through untouched.

Wired in at both assemble entry points, each prepending this directory to
`PATH` before invoking `macos_assemble.sh`:

- the Runner scheme's "Run Prepare Flutter Framework Script" pre-action
  (`macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme`), which
  runs the framework unpack that calls `lipo`;
- the "Run Script" build phase in `macos/Runner.xcodeproj/project.pbxproj`
  (same `export`, for the bundle assemble).

Remove this folder and both `export`s once the Flutter SDK is upgraded past
the upstream fix.
