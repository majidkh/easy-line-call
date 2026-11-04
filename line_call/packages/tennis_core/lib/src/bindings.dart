// Raw dart:ffi bindings over muse2's C ABI (darwin/Classes/include/tennis/
// tennis_c.h) plus SetMatch's pixel shim (darwin/Classes/setmatch_shim.h).
//
// Pure Dart (no Flutter import) so the same code runs inside a worker
// isolate and from a plain `dart run` harness. The library lives in the
// plugin's framework on iOS/macOS; TENNIS_CORE_LIB overrides the path (a
// desktop-built libtennis_shared for offline checks).
import 'dart:ffi';
import 'dart:io' show Platform;

typedef _SessionCreateC = Pointer<Void> Function(
    Double, Int32, Pointer<Double>, Pointer<Double>, Int32);
typedef _SessionCreate = Pointer<Void> Function(
    double, int, Pointer<Double>, Pointer<Double>, int);
typedef _SessionIngestC = Int32 Function(Pointer<Void>, Int32, Pointer<Int32>,
    Pointer<Double>, Pointer<Double>, Pointer<Double>, Pointer<Int32>);
typedef _SessionIngest = int Function(Pointer<Void>, int, Pointer<Int32>,
    Pointer<Double>, Pointer<Double>, Pointer<Double>, Pointer<Int32>);
typedef _PtrToVoidC = Void Function(Pointer<Void>);
typedef _PtrToVoid = void Function(Pointer<Void>);
typedef _PtrToIntC = Int32 Function(Pointer<Void>);
typedef _PtrToInt = int Function(Pointer<Void>);
typedef _PtrToStrC = Pointer<Char> Function(Pointer<Void>);
typedef _SetStitchC = Void Function(Pointer<Void>, Int32, Double);
typedef _SetStitch = void Function(Pointer<Void>, int, double);
typedef _SetMinLenC = Void Function(Pointer<Void>, Int32);
typedef _SetMinLen = void Function(Pointer<Void>, int);
typedef _DetectCourtC = Pointer<Char> Function(Pointer<Uint8>, Int32, Int32);
typedef _DetectCourt = Pointer<Char> Function(Pointer<Uint8>, int, int);
typedef _CalibFramesC = Pointer<Char> Function(
    Pointer<Pointer<Uint8>>, Int32, Int32, Int32);
typedef _CalibFrames = Pointer<Char> Function(
    Pointer<Pointer<Uint8>>, int, int, int);
typedef _ExtractC = Pointer<Double> Function(
    Pointer<Uint8>, Int32, Int32, Int32, Int32, Pointer<Int32>);
typedef _Extract = Pointer<Double> Function(
    Pointer<Uint8>, int, int, int, int, Pointer<Int32>);
typedef _RoiFindC = Int32 Function(
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    Int32,
    Int32,
    Double,
    Double,
    Double,
    Pointer<Double>,
    Pointer<Double>,
    Pointer<Double>);
typedef _RoiFind = int Function(
    Pointer<Uint8>,
    Pointer<Uint8>,
    Pointer<Uint8>,
    int,
    int,
    double,
    double,
    double,
    Pointer<Double>,
    Pointer<Double>,
    Pointer<Double>);
typedef _DetCreateC = Pointer<Void> Function(Pointer<Char>, Pointer<Char>);
typedef _DetInferC = Int32 Function(
    Pointer<Void>,
    Pointer<Pointer<Uint8>>,
    Int32,
    Int32,
    Int32,
    Pointer<Pointer<Uint8>>,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>);
typedef _DetInfer = int Function(
    Pointer<Void>,
    Pointer<Pointer<Uint8>>,
    int,
    int,
    int,
    Pointer<Pointer<Uint8>>,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>);
typedef _LastErrC = Pointer<Char> Function();
typedef _RgbaToBgrC = Void Function(Pointer<Uint8>, Int32, Int32, Pointer<Uint8>);
typedef RgbaToBgrFn = void Function(Pointer<Uint8>, int, int, Pointer<Uint8>);
typedef _ResizeC = Int32 Function(
    Pointer<Uint8>, Int32, Int32, Pointer<Uint8>, Int32, Int32);
typedef ResizeBgrFn = int Function(Pointer<Uint8>, int, int, Pointer<Uint8>, int, int);

/// The loaded core, or null where it isn't built (Android, web, tests).
class TennisCoreLib {
  final DynamicLibrary lib;
  TennisCoreLib._(this.lib);

  static TennisCoreLib? _instance;
  static String _error = '';

  /// Why [instance] is null (empty when it loaded).
  static String get loadError => _error;

  static TennisCoreLib? get instance {
    if (_instance != null || _error.isNotEmpty) return _instance;
    try {
      final override = Platform.environment['TENNIS_CORE_LIB'];
      final DynamicLibrary lib;
      if (override != null && override.isNotEmpty) {
        lib = DynamicLibrary.open(override);
      } else if (Platform.isIOS || Platform.isMacOS) {
        lib = DynamicLibrary.open('tennis_core.framework/tennis_core');
      } else {
        _error = 'muse2 core is built for iOS/macOS only';
        return null;
      }
      _instance = TennisCoreLib._(lib);
    } catch (e) {
      _error = 'muse2 core not loadable: $e';
    }
    return _instance;
  }

  late final lastError =
      lib.lookupFunction<_LastErrC, _LastErrC>('tennis_last_error');
  late final free = lib.lookupFunction<_PtrToVoidC, _PtrToVoid>('tennis_free');

  late final sessionCreate =
      lib.lookupFunction<_SessionCreateC, _SessionCreate>('tennis_session_create');
  late final sessionDestroy =
      lib.lookupFunction<_PtrToVoidC, _PtrToVoid>('tennis_session_destroy');
  late final sessionIngest =
      lib.lookupFunction<_SessionIngestC, _SessionIngest>('tennis_session_ingest');
  late final sessionCoverage =
      lib.lookupFunction<_PtrToIntC, _PtrToInt>('tennis_session_coverage');
  late final sessionSetStitch =
      lib.lookupFunction<_SetStitchC, _SetStitch>('tennis_session_set_stitch');
  late final sessionSetMinLength =
      lib.lookupFunction<_SetMinLenC, _SetMinLen>('tennis_session_set_min_length');
  late final sessionTracksJson =
      lib.lookupFunction<_PtrToStrC, _PtrToStrC>('tennis_session_tracks_json');
  late final sessionRalliesJson =
      lib.lookupFunction<_PtrToStrC, _PtrToStrC>('tennis_session_rallies_json');

  late final detectCourt =
      lib.lookupFunction<_DetectCourtC, _DetectCourt>('tennis_detect_court');
  late final calibrateFrames =
      lib.lookupFunction<_CalibFramesC, _CalibFrames>('tennis_calibrate_frames');
  late final extractCandidates =
      lib.lookupFunction<_ExtractC, _Extract>('tennis_extract_candidates');
  late final roiFind = lib.lookupFunction<_RoiFindC, _RoiFind>('tennis_roi_find');

  late final detectorCreate =
      lib.lookupFunction<_DetCreateC, _DetCreateC>('tennis_detector_create');
  late final detectorDestroy =
      lib.lookupFunction<_PtrToVoidC, _PtrToVoid>('tennis_detector_destroy');
  late final detectorInfer =
      lib.lookupFunction<_DetInferC, _DetInfer>('tennis_detector_infer');

  // SetMatch shim. Absent from a plain muse2 build (TENNIS_CORE_LIB), where
  // the Dart fallbacks in pixels.dart take over with identical arithmetic.
  late final RgbaToBgrFn? rgbaToBgr = _try(() =>
      lib.lookupFunction<_RgbaToBgrC, RgbaToBgrFn>('sm_rgba_to_bgr'));
  late final RgbaToBgrFn? bgrToGray = _try(() =>
      lib.lookupFunction<_RgbaToBgrC, RgbaToBgrFn>('sm_bgr_to_gray'));
  late final ResizeBgrFn? resizeBgr =
      _try(() => lib.lookupFunction<_ResizeC, ResizeBgrFn>('sm_resize_bgr'));

  static T? _try<T>(T Function() f) {
    try {
      return f();
    } catch (_) {
      return null;
    }
  }
}
