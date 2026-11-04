// Plain result types mirroring muse2's engine dataclasses (tracker.py /
// rally.py / candidates.py). Everything is sendable between isolates.
//
// Units match the core: pixels at the PROCESSING width (x right, y down),
// frames as ints from the start of the scan, world metres on the court
// plane (origin court centre, x across, y along).

class Candidate {
  final double x, y, conf;
  const Candidate(this.x, this.y, this.conf);
}

class TrackPoint {
  final int frame;
  final double x, y;
  final bool observed;
  final double conf;
  const TrackPoint(this.frame, this.x, this.y, this.observed, this.conf);
}

class Track {
  final int id;
  final List<TrackPoint> points; // frame ascending
  final List<int> hits;
  final List<int> bounces;
  final bool stray;
  const Track(this.id, this.points, this.hits, this.bounces, this.stray);

  int get start => points.first.frame;
  int get end => points.last.frame;

  static Track fromJson(Map<String, dynamic> j) => Track(
        j['id'] as int,
        [
          for (final p in j['points'] as List)
            TrackPoint(
              (p as List)[0] as int,
              (p[1] as num).toDouble(),
              (p[2] as num).toDouble(),
              p[3] as bool,
              (p[4] as num).toDouble(),
            )
        ],
        [for (final h in j['hits'] as List) h as int],
        [for (final b in j['bounces'] as List) b as int],
        j['stray'] as bool,
      );
}

class BounceCall {
  final int frame;
  final double x, y;
  final String call; // "IN", "OUT" or "?"
  final double wx, wy;
  const BounceCall(this.frame, this.x, this.y, this.call, this.wx, this.wy);
}

class Rally {
  final int index;
  final int trackId;
  final int start, end;
  final List<int> hits;
  final List<BounceCall> bounces;
  final int? serve; // serve strike frame
  const Rally(this.index, this.trackId, this.start, this.end, this.hits,
      this.bounces, this.serve);

  static Rally fromJson(Map<String, dynamic> j) => Rally(
        j['index'] as int,
        j['track_id'] as int,
        j['start'] as int,
        j['end'] as int,
        [for (final h in j['hits'] as List) h as int],
        [
          for (final b in j['bounces'] as List)
            BounceCall(
              (b as Map)['frame'] as int,
              (b['x'] as num).toDouble(),
              (b['y'] as num).toDouble(),
              b['call'] as String,
              (b['wx'] as num).toDouble(),
              (b['wy'] as num).toDouble(),
            )
        ],
        j['serve'] as int?,
      );
}

/// rally.live_at_frame: the rally whose span contains [frame].
Rally? liveAtFrame(List<Rally> rallies, int frame) {
  for (final r in rallies) {
    if (r.start <= frame && frame <= r.end) return r;
  }
  return null;
}

/// A court calibration from the core (tennis_detect_court /
/// tennis_calibrate_frames). Homographies are row-major 3x3 in the pixel
/// space of the frames that were calibrated.
class CourtCalib {
  final List<double> hImg2Court;
  final List<double> hCourt2Img;
  final double rmsPx;
  final int keypoints;
  final List<String> roles;
  const CourtCalib(
      this.hImg2Court, this.hCourt2Img, this.rmsPx, this.keypoints, this.roles);

  static List<double> _mat(Object? m) => [
        for (final row in m as List)
          for (final v in row as List) (v as num).toDouble()
      ];

  static CourtCalib fromJson(Map<String, dynamic> j) => CourtCalib(
        _mat(j['h_img2court']),
        _mat(j['h_court2img']),
        (j['rms'] as num).toDouble(),
        (j['keypoints'] as List).length,
        [
          for (final l in j['lines'] as List)
            if (((l as Map)['role'] as String).isNotEmpty) l['role'] as String
        ],
      );
}

/// Results after a processed chunk: everything before [frontier] is final
/// for now (later chunks may still revise it — tracks re-derive).
class MuseUpdate {
  final int frontier;
  final List<Track> tracks;
  final List<Rally> rallies;

  /// Candidates (detection + recovery) for recently touched frames.
  final Map<int, List<Candidate>> cands;
  final int stepMs;
  final bool done; // the flush after end of footage has finished
  const MuseUpdate(this.frontier, this.tracks, this.rallies, this.cands,
      this.stepMs, this.done);
}
