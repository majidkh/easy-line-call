// Court calibration: white-line detection -> ITF model fit -> homography.
// Port of tennis_ai/court.py (same algorithm; RANSAC uses its own
// deterministic stream, so expect equivalent — not bitwise — fits).
#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace tennis {

struct CourtLine {
  double a = 0, b = 0, c = 0;  // normalized: a*x+b*y+c=0
  double angle = 0;            // direction, radians mod pi
  double length = 0;           // supporting length (px)
  std::string role;            // baseline-*, doubles-*, ... or ""
  double px = 0, py = 0;       // supported extent: point + direction
  double dx = 1, dy = 0;
  double t0 = 0, t1 = 0;
};

struct CourtKeypoint {
  double x, y, wx, wy;
};

struct CourtCalib {
  double h_img2court[9] = {0};
  double h_court2img[9] = {0};
  std::vector<CourtKeypoint> keypoints;
  std::vector<CourtLine> lines;
  double rms_px = 0;
  double support = 0;  // model-vs-paint agreement [0..1], for fit selection
};

class CourtError : public std::runtime_error {
 public:
  explicit CourtError(const std::string& m) : std::runtime_error(m) {}
};

// Fit from one BGR frame (row-major, w x h x 3). Throws CourtError.
CourtCalib DetectCourt(const uint8_t* bgr, int w, int h);

// Fit from several static-camera frames (median background). Each frame
// is w x h x 3 bytes; mismatched frames are resized. Throws CourtError.
CourtCalib CalibrateFrames(const std::vector<const uint8_t*>& bgrs, int w,
                           int h);

}  // namespace tennis
