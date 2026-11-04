#include "tennis/geom.hpp"

#include <cmath>

namespace tennis {

bool ApplyH(const double h[9], double x, double y, double& wx, double& wy) {
  double q0 = h[0] * x + h[1] * y + h[2];
  double q1 = h[3] * x + h[4] * y + h[5];
  double q2 = h[6] * x + h[7] * y + h[8];
  if (std::fabs(q2) < 1e-9) return false;
  wx = q0 / q2;
  wy = q1 / q2;
  return std::isfinite(wx) && std::isfinite(wy);
}

namespace {

void CourtQuad(const CourtGeom& court, double q[4][2]) {
  const double corners[4][2] = {{-kHalfDbl, -kHalfLen},
                                {kHalfDbl, -kHalfLen},
                                {kHalfDbl, kHalfLen},
                                {-kHalfDbl, kHalfLen}};
  for (int i = 0; i < 4; ++i) {
    double x, y;
    ApplyH(court.h_court2img, corners[i][0], corners[i][1], x, y);
    q[i][0] = x;
    q[i][1] = y;
  }
}

double PtSegDist(double px, double py, double ax, double ay, double bx,
                 double by) {
  double dx = bx - ax, dy = by - ay;
  double len2 = dx * dx + dy * dy;
  double t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0.0;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
  return std::hypot(px - (ax + t * dx), py - (ay + t * dy));
}

}  // namespace

double QuadSignedDist(const CourtGeom& court, int width, double x,
                      double y) {
  (void)width;
  double q[4][2];
  CourtQuad(court, q);
  // Convex-quad inside test: same sign on all edge cross products.
  bool pos = false, neg = false;
  for (int i = 0; i < 4; ++i) {
    double ax = q[i][0], ay = q[i][1];
    double bx = q[(i + 1) % 4][0], by = q[(i + 1) % 4][1];
    double cr = (bx - ax) * (y - ay) - (by - ay) * (x - ax);
    if (cr > 0) pos = true;
    if (cr < 0) neg = true;
  }
  double d = 1e18;
  for (int i = 0; i < 4; ++i)
    d = std::min(d, PtSegDist(x, y, q[i][0], q[i][1], q[(i + 1) % 4][0],
                              q[(i + 1) % 4][1]));
  return (pos && neg) ? -d : d;
}

double OnCourtFraction(const Track& track, int a, int b,
                       const CourtGeom& court, int width) {
  int near = 0, tot = 0;
  for (const auto& p : track.points) {
    if (p.frame < a || p.frame > b) continue;
    ++tot;
    if (tot % 2) continue;
    if (QuadSignedDist(court, width, p.x, p.y) > -60) ++near;
  }
  return static_cast<double>(near) / std::max(1, tot / 2);
}

int OnCourtCount(const Track& track, const CourtGeom& court, int width) {
  int n = 0;
  for (size_t i = 0; i < track.points.size(); i += 2) {
    const auto& p = track.points[i];
    if (QuadSignedDist(court, width, p.x, p.y) > -60) ++n;
  }
  return n;
}

}  // namespace tennis
