// Shared Plain-data types for the tennis core.
//
// Units match the Python engine exactly: pixels at processing width
// (x right, y DOWN), frames as ints, world in meters on the court
// plane (x across, y along). Doubles everywhere; the port keeps
// identical arithmetic order so results bit-match by default.
#pragma once

#include <cstdint>
#include <vector>

namespace tennis {

struct Candidate {
  double x = 0, y = 0;  // processing-frame coords
  double conf = 0;      // 0..1
  int area = 0;         // hot pixels at heatmap resolution
  int peak = 0;         // max heat class
};

struct TrackPoint {
  int frame = 0;
  double x = 0, y = 0;
  bool observed = true;
  double conf = 0;
};

struct Track {
  int id = 0;
  std::vector<TrackPoint> points;  // frame ascending
  std::vector<int> hits;           // shot frames
  std::vector<int> bounces;        // bounce frames
  std::vector<int> junction_hits;  // handover strikes (merge)
  bool stray = false;              // intruder ball (not our rally)
  int start() const { return points.front().frame; }
  int end() const { return points.back().frame; }
};

struct TrackerConfig {
  double gate_base = 25.0;
  double gate_speed = 1.5;
  double vel_alpha = 0.55;
  double birth_conf = 0.25;
  int min_hits = 3;
  int confirm_window = 6;
  int max_miss = 22;
  int stitch_gap = 30;
  double stitch_resid = 5.0;
  int min_length = 8;
  double min_disp = 30.0;
};

struct BounceCall {
  int frame = 0;
  double x = 0, y = 0;
  // "IN", "OUT" or "?"
  char call[4] = "?";
  double wx = 0, wy = 0;
};

struct Rally {
  int index = 0;
  int track_id = 0;
  int start = 0, end = 0;
  std::vector<int> hits;
  std::vector<BounceCall> bounces;
  int serve_frame = -1;  // -1 == none
};

// Court calibration: the two homographies (row-major 3x3). The core
// consumes calibrations; producing them (line detection) is currently
// the Python engine's job and ports next.
struct CourtGeom {
  bool valid = false;
  double h_img2court[9] = {0};
  double h_court2img[9] = {0};
};

constexpr double kHalfLen = 23.77 / 2;  // baseline |y|
constexpr double kHalfDbl = 10.97 / 2;  // doubles sideline |x|

}  // namespace tennis
