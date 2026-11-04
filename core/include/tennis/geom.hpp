// Court-plane geometry: homography application, court quad tests.
#pragma once

#include "tennis/types.hpp"

namespace tennis {

// Apply row-major 3x3 H to (x, y); returns false near the horizon.
bool ApplyH(const double h[9], double x, double y, double& wx, double& wy);

// Signed distance to the main-court image quad: positive inside,
// negative outside (matches cv2.pointPolygonTest semantics).
double QuadSignedDist(const CourtGeom& court, int width, double x, double y);

// Fraction + absolute count of a track's points inside the quad
// (generous -60px margin), mirroring rally.py exactly.
double OnCourtFraction(const Track& track, int a, int b,
                       const CourtGeom& court, int width);
int OnCourtCount(const Track& track, const CourtGeom& court, int width);

}  // namespace tennis
