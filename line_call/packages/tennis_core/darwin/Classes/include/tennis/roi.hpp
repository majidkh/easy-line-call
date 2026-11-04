// Foveal re-detection: find the ball where the global model is blind.
//
// The heatmap network sees the full frame at 640x360, where a far-court
// ball is ~1px and motion blur smears it into the background. A human
// instead saccades to the predicted spot and looks closely at full
// resolution. This is that: given three consecutive gray frames and a
// tracker's prediction, find a small, bright, MOVING blob nearby.
//
// Cues (all cheap on a small crop): frame-difference motion energy
// (static camera: only the ball/players move), brightness (the ball is
// the brightest small thing on court), compactness, and proximity to
// the prediction. Runs in microseconds; called only inside confident
// tracks' blind gaps, so false positives have nowhere to hide.
#pragma once

#include <cstdint>

namespace tennis {

struct RoiFound {
  bool found = false;
  double x = 0;     // frame coordinates (sub-pixel centroid)
  double y = 0;
  double conf = 0;  // 0..1 combined score
};

// Search radius px around (px, py) in w x h frames. Blobs must land
// within 0.75 * radius of the prediction to be accepted.
RoiFound RoiFindBall(const uint8_t* prev, const uint8_t* curr,
                     const uint8_t* next, int w, int h, double px, double py,
                     double radius);

}  // namespace tennis
