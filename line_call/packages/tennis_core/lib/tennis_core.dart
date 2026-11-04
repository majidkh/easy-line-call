/// muse2 tennis core over FFI: court calibration, TrackNet (Core ML) ball
/// detection, tracking, bounce + rally calls. See VENDORED.md.
library;

export 'src/bindings.dart' show TennisCoreLib;
export 'src/core.dart'
    show TennisCoreException, CoreSession, CoreDetector, NativeImage;
export 'src/driver.dart' show ChunkDriver;
export 'src/engine.dart'
    show
        MuseEngine,
        MuseEngineConfig,
        detectTriplet,
        calibrateCourt,
        warmDetector;
export 'src/recover.dart' show TrackerConfig;
export 'src/types.dart';
