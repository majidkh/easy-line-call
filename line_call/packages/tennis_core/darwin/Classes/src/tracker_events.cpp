#include "tennis/tracker.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>

#include "tennis/num.hpp"

namespace tennis {
namespace {

// Median-5 restricted to frames within ±2: never mixes points
// across holes (dense tracks are bit-identical to Median5).
std::vector<double> Median5Local(const std::vector<double>& v,
                                 const std::vector<double>& fs) {
  std::vector<double> out = v;
  size_t n = v.size();
  if (n < 5) return out;
  for (size_t i = 2; i + 2 < n; ++i) {
    std::vector<double> w;
    for (size_t j = i - 2; j <= i + 2; ++j)
      if (std::fabs(fs[j] - fs[i]) <= 2) w.push_back(v[j]);
    if (!w.empty()) out[i] = num::Median(w);
  }
  return out;
}

// |angle(exp(i*(b-a)))| — absolute wrapped angle difference.
double AngDiff(double a, double b) {
  double d = std::fmod(b - a, 2 * M_PI);
  if (d > M_PI) d -= 2 * M_PI;
  if (d < -M_PI) d += 2 * M_PI;
  return std::fabs(d);
}

}  // namespace

std::vector<int> DetectShots(const Track& track, int width) {
  double s = width / 1280.0;
  const auto& pts = track.points;
  size_t n = pts.size();
  if (n < 7) return {};
  std::vector<double> xs(n), ys(n), fs(n);
  std::vector<char> ob(n);
  for (size_t i = 0; i < n; ++i) {
    xs[i] = pts[i].x;
    ys[i] = pts[i].y;
    fs[i] = pts[i].frame;
    ob[i] = pts[i].observed;
  }
  xs = Median5Local(xs, fs);
  ys = Median5Local(ys, fs);
  std::vector<double> vx = num::Gradient(xs, fs);
  std::vector<double> vy = num::Gradient(ys, fs);
  std::vector<double> sp(n), ang(n);
  for (size_t i = 0; i < n; ++i) {
    sp[i] = std::hypot(vx[i], vy[i]);
    ang[i] = std::atan2(vy[i], vx[i]);
  }
  std::vector<int> hits;
  for (size_t i = 3; i + 3 < n; ++i) {
    // Local support: gradients across a hole pin phantom hits.
    if (fs[i + 2] - fs[i - 2] > 6) continue;
    bool fast_before = sp[i - 1] > 3.5 * s || sp[i - 2] > 3.5 * s;
    bool fast_after = sp[i + 1] > 3.5 * s || sp[i + 2] > 3.5 * s;
    bool maybe_jump = sp[i + 1] > 10.0 * s || sp[i + 2] > 10.0 * s;
    bool maybe_launch = sp[i + 1] > 6.0 * s || sp[i + 2] > 6.0 * s;
    if (!(fast_after && (fast_before || maybe_jump || maybe_launch))) continue;
    int seen = 0;
    for (size_t k = i - 2; k <= i + 2; ++k) seen += ob[k] ? 1 : 0;
    if (seen < 2) continue;
    double d = AngDiff(ang[i - 1], ang[i + 1]);
    double kick = std::hypot(vx[i + 1] - vx[i - 1], vy[i + 1] - vy[i - 1]);
    bool turn_hit = d > 55 * M_PI / 180 && kick >= 7.0 * s;
    // A strike steps UP from flat-slow; dip-then-rise is jitter.
    // (2px floor: static pre-serve balls have ~zero speed where
    // ratios are noise. A DEEP stall (<=1.5) passes outright:
    // jitter dips partially, but contact genuinely stops the ball.)
    // No flatness required after: post-strike image speed can drop
    // at once as the ball recedes.
    bool flat_before = sp[i - 2] <= 1.5 * std::max(sp[i - 1], 2.0 * s) ||
                       sp[i - 1] <= 1.5 * s;
    // Speed jumps must be seen on BOTH sides: bridges across coasts
    // carry the gap-crossing slope, mimicking collinear launches.
    bool speed_seen = ob[i - 1] && ob[i + 1];
    // A launch after a long stall is a hand feed, not a strike.
    int stall = 0;
    for (int j = i - 1;
         j >= 0 && sp[j] < std::max(1.2 * s, 1.0) && stall <= 4; --j)
      ++stall;
    bool arrived_flying = stall <= 4;
    bool jump_hit = (d <= 55 * M_PI / 180 && sp[i + 1] > 10.0 * s &&
                     sp[i + 1] > 2.5 * std::max(sp[i - 1], 1.0) &&
                     kick > 10.0 * s && flat_before && speed_seen &&
                     arrived_flying);
    // Launch from stall: blur-smoothed contact sits ~2px/frame then
    // leaves at 6+ along the same line — abrupt (2.5x) and
    // sustained (jitter bursts collapse at once).
    bool launch_hit =
        (d <= 55 * M_PI / 180 && sp[i - 1] < 3.0 * s &&
         sp[i + 1] > 6.0 * s && sp[i + 1] > 2.5 * std::max(sp[i - 1], 1.0) &&
         sp[i + 2] > 4.0 * s && kick > 4.0 * s && flat_before &&
         speed_seen && arrived_flying);
    if (!(turn_hit || jump_hit || launch_hit)) continue;
    if (vy[i - 1] > 1.5 * s && vy[i + 1] < -1.5 * s && ys[i] >= ys[i - 1] &&
        ys[i] >= ys[i + 1] && vx[i - 1] * vx[i + 1] >= 0 &&
        std::fabs(vy[i + 1]) <= std::fabs(vy[i - 1]) * 1.15 + 1.0 * s)
      continue;
    double d0 = AngDiff(ang[i - 2], ang[i]);
    double d1 = AngDiff(ang[i], ang[i + 2]);
    if (turn_hit && (d < d0 || d < d1)) continue;
    if (jump_hit || launch_hit) {
      double k0 = std::hypot(vx[i] - vx[i - 2], vy[i] - vy[i - 2]);
      double k1 = std::hypot(vx[i + 2] - vx[i], vy[i + 2] - vy[i]);
      if (kick < k0 || kick < k1) continue;
    }
    if (hits.empty() || pts[i].frame - hits.back() > 5)
      hits.push_back(pts[i].frame);
  }
  return hits;
}

struct LinFit {
  double slope = 0, intercept = 0, rms = 0;
};

// Closed-form least squares (sums in frame order, like the twin).
LinFit FitLine(const std::vector<double>& t, const std::vector<double>& v) {
  LinFit r;
  size_t n = t.size();
  if (n == 0) return r;
  double tm = 0, vm = 0;
  for (size_t i = 0; i < n; ++i) {
    tm += t[i];
    vm += v[i];
  }
  tm /= n;
  vm /= n;
  double denom = 0, num = 0;
  for (size_t i = 0; i < n; ++i) {
    denom += (t[i] - tm) * (t[i] - tm);
    num += (t[i] - tm) * (v[i] - vm);
  }
  if (denom == 0) {
    r.intercept = vm;
    return r;
  }
  r.slope = num / denom;
  double se = 0;
  for (size_t i = 0; i < n; ++i) {
    double d = r.slope * (t[i] - tm) + vm - v[i];
    se += d * d;
  }
  r.rms = std::sqrt(se / n);
  r.intercept = vm - r.slope * tm;
  return r;
}

// Meters per image pixel along image-Y at (px,py): how far a vertical
// image step travels on the court plane. Stands the pixel amplitude
// floor on physical ground so far/grazing views are not held to
// near-court pixels. Returns <0 when unprojectable.
double ImageYMpp(const CourtGeom* court, double px, double py) {
  if (!court || !court->valid) return -1.0;
  auto proj = [&](double x, double y, double& wx, double& wy) {
    const double* H = court->h_img2court;
    double w = H[6] * x + H[7] * y + H[8];
    if (std::fabs(w) < 1e-9) return false;
    wx = (H[0] * x + H[1] * y + H[2]) / w;
    wy = (H[3] * x + H[4] * y + H[5]) / w;
    return std::isfinite(wx) && std::isfinite(wy);
  };
  double x0, y0, x1, y1, x2, y2;
  if (!proj(px, py, x0, y0) || !proj(px, py - 2, x1, y1) ||
      !proj(px, py + 2, x2, y2))
    return -1.0;
  return std::max(std::hypot(x1 - x0, y1 - y0),
                  std::hypot(x2 - x0, y2 - y0)) /
         2.0;
}

// A visible impact displaces the ball by at least ~2 ball diameters.
constexpr double kMinBounceAmpM = 0.12;
// Sub-pixel Vs are fitting artifacts, never impacts.
constexpr double kMinBounceAmpPx = 1.0;

// Pixel floor first; a coherent V shallower than it still counts when it
// spans physical meters on the calibrated court (far/grazing views).
bool BounceAmpOk(double amp_px, double bx, double by, double s,
                 const CourtGeom* court) {
  if (amp_px >= 2.5 * s) return true;
  if (amp_px < kMinBounceAmpPx * s) return false;
  double mpp = ImageYMpp(court, bx, by);
  return mpp > 0 && amp_px * mpp >= kMinBounceAmpM;
}

namespace {

struct FallSeg {
  size_t begin = 0;  // index into track.points (inclusive)
  size_t end = 0;    // index into track.points (inclusive)
};

// Maximal steep-fall runs: pairwise vertical speed stays steep while
// extending, then strict keep gates on the whole run.
std::vector<FallSeg> FindFallSegs(const std::vector<TrackPoint>& pts,
                                  double s) {
  std::vector<FallSeg> segs;
  size_t n = pts.size();
  size_t i = 0;
  while (i < n) {
    size_t j = i;
    while (j + 1 < n && j + 1 - i < 24) {
      int df = pts[j + 1].frame - pts[j].frame;
      double dy = pts[j + 1].y - pts[j].y;
      double dx = pts[j + 1].x - pts[j].x;
      // Vertical fall without a lateral handover jump.
      if (df > 0 && dy / df >= 3.0 * s && std::fabs(dx) / df <= 30.0 * s)
        ++j;
      else
        break;
    }
    if (j > i + 1) {
      int nobs = 0;
      for (size_t k = i; k <= j; ++k)
        if (pts[k].observed) ++nobs;
      double drop = pts[j].y - pts[i].y;
      int span = pts[j].frame - pts[i].frame;
      if (j - i + 1 >= 3 && nobs >= 2 && drop >= 10.0 * s && span >= 2) {
        std::vector<double> t, v;
        for (size_t k = i; k <= j; ++k) {
          t.push_back(pts[k].frame);
          v.push_back(pts[k].y);
        }
        if (FitLine(t, v).slope >= 4.0 * s) {
          segs.push_back({i, j});
          i = j + 1;
          continue;
        }
      }
    }
    ++i;
  }
  return segs;
}

// Ballistic falls are monotone: a V whose 15-frame run-up bobs upward
// more than twice is body motion (a head-lock crouch), not a fall —
// unless an earlier candidate inside the window explains the rise (a
// hop landing off the previous bounce). Sightings only: interpolated
// bridge spikes (a linker void-fill overshooting upward) are not body
// motion and must not veto a V with an observed bottom and rise.
bool FallBobbles(const Track& track, int f,
                 const std::vector<std::pair<double, int>>& all, double s) {
  int ups = 0;
  const TrackPoint* prev = nullptr;
  for (const auto& p : track.points) {
    if (p.frame < f - 15 || p.frame >= f) continue;
    if (!p.observed) continue;
    if (prev && p.y < prev->y - 0.5 * s) ++ups;
    prev = &p;
  }
  if (ups <= 2) return false;
  for (const auto& vf : all)
    if (vf.second < f && f - vf.second < 15) return false;
  return true;
}

// Handover touchdown: a weak depth-flight fall (too shallow for the
// steep-fall rescue) that lands while the tracker jumps to a static
// distractor, or rolls visibly. Apex-anchored fall + flat onset + (a lateral
// jump or roll motion), away from hits (a hit's turnaround mimics
// the same shape) and from established candidates.
void HandoverTouchdowns(const Track& track, double s,
                        const std::vector<std::pair<double, int>>& vframes,
                        const std::vector<int>& shots,
                        std::vector<std::pair<double, int>>& cand) {
  const auto& pts = track.points;
  size_t n = pts.size();
  if (n < 4) return;
  std::vector<std::pair<double, int>> found;
  for (size_t i = 0; i < n; ++i) {
    const TrackPoint& p = pts[i];
    int f = p.frame;
    if (!p.observed) continue;
    if (!(390.0 * s <= p.y && p.y <= 720.0 * s)) continue;
    // Apex-anchored fall: the trajectory apex (lowest y) in
    // [f-25, f-3] starts the fall, which must run dense and
    // near-monotone into f — so jagged pre-apex handover garbage
    // never vetoes the landing.
    const TrackPoint* apex = nullptr;
    for (const auto& r : pts) {
      if (r.frame < f - 25 || r.frame > f - 3) continue;
      if (!r.observed) continue;  // sighted apex: a void-fill dip is
      if (!apex || r.y < apex->y) apex = &r;  // not a trajectory top
    }
    if (!apex) continue;
    int ups = 0;
    bool dense = true;
    for (int g = apex->frame; g < f; ++g) {
      const TrackPoint *a = nullptr, *b = nullptr;
      for (const auto& r : pts) {
        if (r.frame == g) a = &r;
        if (r.frame == g + 1) b = &r;
      }
      if (!a || !b) {
        dense = false;
        break;
      }
      if (b->y < a->y - 0.5 * s && ++ups > 2) break;
    }
    if (!dense || ups > 2) continue;
    double drop = p.y - apex->y;
    if (drop < 5.0 * s) continue;
    if (i + 1 >= n || pts[i + 1].frame != f + 1) continue;
    const TrackPoint& q = pts[i + 1];
    // Flat onset, tolerant of pre-smooth observation jitter (~1px per
    // point): the landing settles instead of rebounding.
    if (std::fabs(q.y - p.y) > 2.5 * s) continue;
    if (std::hypot(q.x - p.x, q.y - p.y) > 4.0 * s) continue;
    // Lateral jump: a single-step |dx| over 8px within [f+1, f+2] — a
    // handover discontinuity, not an on-ball correction.
    bool jump = false;
    for (int h = f + 1; h <= f + 2; ++h) {
      const TrackPoint *a = nullptr, *b = nullptr;
      for (const auto& r : pts) {
        if (r.frame == h - 1) a = &r;
        if (r.frame == h) b = &r;
      }
      if (a && b && b->frame - a->frame == 1 &&
          std::fabs(b->x - a->x) > 8.0 * s &&
          (a->observed || b->observed)) {
        jump = true;  // sighted jump: bridge-to-bridge interpolation
      }  // steps are not handover discontinuities
    }
    // Roll: 4 present frames of flat y with travel in x.
    bool roll = false;
    {
      const TrackPoint* w[4] = {nullptr, nullptr, nullptr, nullptr};
      for (const auto& r : pts)
        if (f <= r.frame && r.frame <= f + 3) w[r.frame - f] = &r;
      if (w[0] && w[1] && w[2] && w[3]) {
        double ymin = w[0]->y, ymax = w[0]->y;
        int nobs = 0;
        for (int k = 0; k < 4; ++k) {
          ymin = std::min(ymin, w[k]->y);
          ymax = std::max(ymax, w[k]->y);
          if (w[k]->observed) ++nobs;
        }
        if (ymax - ymin <= 2.0 * s &&
            std::fabs(w[3]->x - w[0]->x) >= 6.0 * s && nobs >= 3)
          roll = true;  // sighted roll: mostly interpolated flat is void
      }  // fill, not a ball settling
    }
    if (!(jump || roll)) continue;
    bool near_hit = false;
    for (int h : shots)
      if (std::abs(f - h) <= 10) {
        near_hit = true;
        break;
      }
    if (near_hit) continue;
    bool near = false;
    for (const auto& vf : vframes)
      if (std::abs(f - vf.second) <= 10) {
        near = true;
        break;
      }
    if (near) continue;
    if (std::getenv("TENNIS_TRACE_EV")) fprintf(stderr, "EV:HANDOVER f=%d\n", f);
    found.emplace_back(drop, f);
  }
  std::stable_sort(found.begin(), found.end(),
                   [](const auto& a, const auto& b) { return a.first > b.first; });
  for (const auto& c : found) {
    bool near = false;
    for (const auto& g : cand)
      if (std::abs(c.second - g.second) <= 10) {
        near = true;
        break;
      }
    if (!near) cand.push_back(c);
  }
}

// Teleport bounce: a single-interval handover-step (the tracker
// switching from a ghost-lock onto the ball) that lands a slow descent
// onto a flat roll. The switch point is the deflection, and the
// deflection is the impact — so the bounce is the pre-step frame.
// Supplement: suppressed near established candidates. Shots within 2
// of the step are the step's own artifact (a 27px jump fakes jump_hit),
// never a veto; anything 3-10 away vetoes like a handover mimic.
void TeleportBounces(const Track& track, double s,
                     const std::vector<std::pair<double, int>>& vframes,
                     const std::vector<int>& shots,
                     std::vector<std::pair<double, int>>& cand) {
  const auto& pts = track.points;
  size_t n = pts.size();
  if (n < 10) return;
  std::map<int, const TrackPoint*> byf;
  for (const auto& p : pts) byf[p.frame] = &p;
  for (size_t k = 0; k + 1 < n; ++k) {
    const TrackPoint& a = pts[k];
    const TrackPoint& b = pts[k + 1];
    if (b.frame - a.frame != 1) continue;
    int f = a.frame;
    double d = std::hypot(b.x - a.x, b.y - a.y);
    if (!(12.0 * s <= d && d <= 60.0 * s)) continue;
    std::vector<double> nbs;
    for (int j : {(int)k - 2, (int)k - 1, (int)k + 1}) {
      if (j < 0 || j + 1 >= (int)n) continue;
      if (pts[j + 1].frame - pts[j].frame != 1) continue;
      nbs.push_back(
          std::hypot(pts[j + 1].x - pts[j].x, pts[j + 1].y - pts[j].y));
    }
    if (nbs.size() < 3) continue;
    if (d < 3.0 * *std::max_element(nbs.begin(), nbs.end())) continue;
    bool missing = false;
    for (int g = f - 4; g <= f + 5; ++g)
      if (!byf.count(g)) {
        missing = true;
        break;
      }
    if (missing) continue;
    double ymin = byf[f - 4]->y;
    for (int g = f - 3; g <= f; ++g) ymin = std::min(ymin, byf[g]->y);
    // Floor 0.5px, not 2: pre-smooth takes crawl nearly flat into the
    // switch (smoothing smears the jump backward, manufacturing drop).
    // Mid-roll switches (drop ~0.2) still die here.
    if (a.y - ymin < 0.5 * s) continue;
    int ups = 0;
    for (int g = f - 4; g < f; ++g)
      if (byf[g + 1]->y < byf[g]->y - 0.5 * s && ++ups > 1) break;
    if (ups > 1) continue;
    if (!(390.0 * s <= a.y && a.y <= 720.0 * s)) continue;
    double y1 = byf[f + 1]->y;
    bool flat = true;
    for (int g = f + 1; g <= f + 5; ++g)
      if (std::fabs(byf[g]->y - y1) > 3.0 * s) {
        flat = false;
        break;
      }
    if (!flat) continue;
    if (std::fabs(byf[f + 5]->x - byf[f + 1]->x) < 4.0 * s) continue;
    bool near_hit = false;
    for (int h : shots)
      if (std::abs(f - h) <= 10 && std::abs(f - h) > 2) {
        near_hit = true;
        break;
      }
    if (near_hit) continue;
    bool near = false;
    for (const auto& vf : vframes)
      if (std::abs(f - vf.second) <= 10) {
        near = true;
        break;
      }
    if (near) continue;
    if (std::getenv("TENNIS_TRACE_EV")) fprintf(stderr, "EV:TELEPORT f=%d\n", f);
    cand.emplace_back(d, f);
  }
}

// Descent-anchored rescue: steep falls whose impact the classic ±6
// windows cannot see. Two endings:
//  - V: the fall lands and hops (lowest observed, sustained rise).
//    Anchoring v_before on the visible descent (instead of flat
//    roll-onset inside ±6) restores occluded landings.
//  - touchdown: the fall ends in roll/stop with no rebound leg
//    (dead balls). Steep fall, then slow sustained, continuous,
//    on the court plane.
// Additive: runs after the classic paths and never fires within 10
// frames of them, so dense-track behavior is unchanged.
void RescueBounces(const Track& track, double s, const CourtGeom* court,
                   const std::vector<std::pair<double, int>>& vframes,
                   std::vector<std::pair<double, int>>& cand_v,
                   std::vector<std::pair<double, int>>& cand_td) {
  const auto& pts = track.points;
  size_t n = pts.size();
  if (n < 3) return;
  auto far_from_classic = [&](int f) {
    for (const auto& vf : vframes)
      if (std::abs(f - vf.second) <= 10) return false;
    return true;
  };
  auto court_ok = [&](double x, double y) {
    if (!court || !court->valid) return true;
    const double* H = court->h_img2court;
    double q2 = H[6] * x + H[7] * y + H[8];
    if (std::fabs(q2) < 1e-9) return false;
    double wx = (H[0] * x + H[1] * y + H[2]) / q2;
    double wy = (H[3] * x + H[4] * y + H[5]) / q2;
    return std::hypot(wx, wy) <= 25.0;
  };
  for (const FallSeg& sg : FindFallSegs(pts, s)) {
    int b = pts[sg.end].frame;
    std::vector<double> st, sx, sy;
    for (size_t k = sg.begin; k <= sg.end; ++k) {
      st.push_back(pts[k].frame);
      sx.push_back(pts[k].x);
      sy.push_back(pts[k].y);
    }
    LinFit sl0 = FitLine(st, sy), slx0 = FitLine(st, sx);
    double drop = pts[sg.end].y - pts[sg.begin].y;
    // V ending: lowest observed in [b, b+8], sustained rise after it.
    const TrackPoint* m = nullptr;
    for (size_t k = sg.end; k < n; ++k) {
      if (pts[k].frame < b || pts[k].frame > b + 8) continue;
      if (!pts[k].observed) continue;
      if (!m || pts[k].y > m->y) m = &pts[k];
    }
    if (m != nullptr) {
      std::vector<double> rt, rx, ry;
      for (size_t k = 0; k < n; ++k) {
        if (!pts[k].observed || pts[k].frame < m->frame) continue;
        if (pts[k].frame > b + 8) break;
        rt.push_back(pts[k].frame);
        rx.push_back(pts[k].x);
        ry.push_back(pts[k].y);
      }
      // Rise persistence (clean bottoms only): a real bounce-rise
      // sustains (ball rises 10+ frames); a 3-take flicker over 6
      // frames is a racket/shadow artifact (rally-3.mov frame 920:
      // racket-head track). When the bottom lands after seg-end
      // (occluded V), the [m, b+8] view is truncated and persistence
      // can't be judged — skip the gate (rally-3.mov frame 1258).
      if (rt.size() >= 3 && (m->frame > b || rt.back() - m->frame >= 8)) {
        LinFit fr = FitLine(rt, ry), fxr = FitLine(rt, rx);
        double rdrop = m->y - ry.back();
        if (fr.slope <= -1.5 * s && rdrop >= 12.0 * s) {
          double amp = std::min(m->y - pts[sg.begin].y, rdrop);
          if (BounceAmpOk(amp, m->x, m->y, s, court) &&
              far_from_classic(m->frame) &&
              !((slx0.slope > 2.0 * s && fxr.slope < -2.0 * s) ||
                (slx0.slope < -2.0 * s && fxr.slope > 2.0 * s))) {
            double v_bef = std::hypot(slx0.slope, sl0.slope);
            double v_aft = std::hypot(fxr.slope, fr.slope);
            if (v_aft < 0.95 * v_bef && court_ok(m->x, m->y))
              if (std::getenv("TENNIS_TRACE_EV")) fprintf(stderr, "EV:VRESCUE f=%d\n", m->frame);
              cand_v.emplace_back(amp, m->frame);
          }
        }
      }
    }
    // Occluded-drop ending: the fall's bottom is hidden — the tracker
    // stalls on a ground speck, then a void — but slow exit takes
    // reappear along the flight path. The ball bounced inside the blind
    // zone and rolled out (rally-3.mov frame ~1256: steep fall, static
    // speck takes, then a slow roll; no rise is ever observed, so the
    // V, gap-cusp and touchdown paths all stay silent). Fire at the
    // entry line's crossing with the stall-to-exit ground line (or the
    // exit level without a stall). Supplement-only: suppressed near any
    // fire so far, including this segment's own V (the touchdown block
    // runs after; a same-segment touchdown double-fire merges in dedup,
    // where the touchdown's deeper amplitude wins).
    if (court && court->valid && drop >= 25.0 * s) {
      double peak = 0;
      int ef = -1;
      for (size_t k = sg.begin; k < sg.end; ++k) {
        int df = pts[k + 1].frame - pts[k].frame;
        if (df <= 0) continue;
        double vy = (pts[k + 1].y - pts[k].y) / df;
        peak = std::max(peak, vy);
        if (vy >= 3.0 * s) ef = pts[k + 1].frame;
      }
      if (ef >= 0 && peak >= 6.0 * s) {
        // Clean flight: outlier pairs (a handover jump onto the stall
        // ghost) end the fit so the entry line is not steepened.
        std::vector<double> vys;
        for (size_t k = sg.begin; k < sg.end; ++k) {
          int df = pts[k + 1].frame - pts[k].frame;
          if (df > 0) vys.push_back((pts[k + 1].y - pts[k].y) / df);
        }
        std::sort(vys.begin(), vys.end());
        double med = vys.empty() ? 0.0 : vys[vys.size() / 2];
        size_t fej = sg.end;
        for (size_t k = sg.begin; k < sg.end; ++k) {
          int df = pts[k + 1].frame - pts[k].frame;
          if (df > 0 && (pts[k + 1].y - pts[k].y) / df > 2.5 * med + 1.0) {
            fej = k;
            break;
          }
        }
        if (fej < sg.begin + 2) fej = sg.end;
        std::vector<double> et, ex, ey;
        for (size_t k = sg.begin; k <= fej; ++k) {
          et.push_back(pts[k].frame);
          ex.push_back(pts[k].x);
          ey.push_back(pts[k].y);
        }
        LinFit ely = FitLine(et, ey), elx = FitLine(et, ex);
        double v_entry = std::hypot(elx.slope, ely.slope);
        const TrackPoint& fp = pts[fej];
        const TrackPoint* ep = nullptr;
        for (const auto& p : pts)
          if (p.frame == ef) ep = &p;
        if (ep != nullptr && ely.slope > 0) {
          std::vector<const TrackPoint*> after;
          for (const auto& p : pts) {
            if (!p.observed || p.frame <= ef || p.frame > ef + 26) continue;
            after.push_back(&p);
          }
          std::vector<const TrackPoint*> leg;
          for (const auto* p : after) {
            double d0 = std::hypot(p->x - ep->x, p->y - ep->y);
            if (d0 <= 20.0 * s && leg.empty()) continue;  // stall ghost
            if (!leg.empty()) {
              int df = p->frame - leg.back()->frame;
              double d = std::hypot(p->x - leg.back()->x,
                                    p->y - leg.back()->y);
              if (df <= 0 || d / df > 25.0 * s ||
                  p->frame - leg.front()->frame > 14)
                break;
            }
            leg.push_back(p);
            if (leg.size() >= 3) break;
          }
          if (leg.size() >= 2) {
            // Bottomless exit: the leg must keep descending (a roll).
            // An observed V bottom inside the leg belongs to the V
            // paths — inferring a second, earlier impact double-fires.
            bool dipped = false;
            for (size_t li = 1; li < leg.size(); ++li)
              if (leg[li]->y < leg[li - 1]->y - 1.0 * s) dipped = true;
            int void_len = leg.front()->frame - ef - 1;
            const TrackPoint* a = leg.front();
            const TrackPoint* bb = leg.back();
            int df = bb->frame - a->frame;
            if (!dipped && void_len >= 2 && df > 0) {
              double evx = (bb->x - a->x) / df;
              double evy = (bb->y - a->y) / df;
              double v_exit = std::hypot(evx, evy);
              bool x_rev = (elx.slope > 0) != (evx > 0) &&
                           std::fabs(elx.slope) > 1.0 * s &&
                           std::fabs(evx) > 1.0 * s;
              double prog = (bb->x - ep->x) * (elx.slope >= 0 ? 1 : -1);
              if (v_exit < 0.75 * v_entry && !x_rev && prog > 0) {
                double t_star;
                double sx = 0, sy = 0;
                int nstall = 0;
                for (const auto* p : after) {
                  if (p->frame >= a->frame) break;
                  if (std::hypot(p->x - ep->x, p->y - ep->y) > 20.0 * s)
                    continue;
                  sx += p->x;
                  sy += p->y;
                  ++nstall;
                }
                if (nstall >= 2 && std::fabs(a->x - sx / nstall) > 1.0) {
                  double ax = sx / nstall, ay = sy / nstall;
                  double g = (a->y - ay) / (a->x - ax);
                  double den = ely.slope - g * elx.slope;
                  if (den <= 0) {
                    t_star = -1;  // entry runs under the ground line
                  } else {
                    t_star = fp.frame +
                             (ay - fp.y + g * (fp.x - ax)) / den;
                  }
                } else {
                  t_star = fp.frame + (a->y - fp.y) / ely.slope;
                }
                if (t_star > 0) {
                  int f = (int)std::floor(t_star + 0.5);
                  f = std::max(ef + 1, std::min(a->frame - 1, f));
                  double x_star = elx.intercept + elx.slope * t_star;
                  double y_star = ely.intercept + ely.slope * t_star;
                  const double* H = court->h_img2court;
                  double q2 =
                      H[6] * x_star + H[7] * y_star + H[8];
                  if (std::fabs(q2) >= 1e-9) {
                    double wx = (H[0] * x_star + H[1] * y_star + H[2]) / q2;
                    double wy = (H[3] * x_star + H[4] * y_star + H[5]) / q2;
                    double mpp = ImageYMpp(court, x_star, y_star);
                    bool ok = std::fabs(wx) <= kHalfDbl + 2.5 &&
                              std::fabs(wy) <= kHalfLen + 2.5 &&
                              (mpp > 0 && mpp < 2.0) &&
                              far_from_classic(f);
                    for (const auto& c : cand_v)
                      if (std::abs(f - c.second) <= 10) ok = false;
                    for (const auto& c : cand_td)
                      if (std::abs(f - c.second) <= 10) ok = false;
                    if (ok)
                      cand_td.emplace_back(
                          std::max(0.5, a->y - ep->y), f);
                    if (std::getenv("TENNIS_TRACE_EV")) fprintf(stderr, "EV:OCCDROP f=%d\n", f);
                  }
                }
              }
            }
          }
        }
      }
    }
    // Touchdown ending: steep fall ends, ball slow sustained after.
    // Needs the court: the ground-plane gate is what separates a
    // landing from a catch or a leap.
    if (court && court->valid && drop >= 25.0 * s) {
      double peak_v = 0;
      int end_f = -1;
      // Impact speed needs a real sighting: the peak pair must touch
      // an observation, or a void-fill spike (linker overshoot, never
      // a sighted fall) reads as a landing.
      bool peak_obs = false;
      for (size_t k = sg.begin; k < sg.end; ++k) {
        int df = pts[k + 1].frame - pts[k].frame;
        if (df <= 0) continue;
        double vy = (pts[k + 1].y - pts[k].y) / df;
        if (vy > peak_v) {
          peak_v = vy;
          peak_obs = pts[k].observed || pts[k + 1].observed;
        }
        if (vy >= 3.0 * s) end_f = pts[k + 1].frame;
      }
      if (end_f < 0 || peak_v < 6.0 * s || !peak_obs) continue;
      std::vector<const TrackPoint*> post;
      for (size_t k = 0; k < n; ++k) {
        if (pts[k].frame > end_f && pts[k].frame <= end_f + 10)
          post.push_back(&pts[k]);
      }
      if (post.size() < 3) continue;
      int best_span = 0, best_obs = 0, best_start = 0;
      for (size_t i0 = 0; i0 + 1 < post.size();) {
        int df = post[i0 + 1]->frame - post[i0]->frame;
        double v = df > 0 ? std::hypot(post[i0 + 1]->x - post[i0]->x,
                                       post[i0 + 1]->y - post[i0]->y) / df
                          : 1e300;
        if (v > 3.0 * s) {
          ++i0;
          continue;
        }
        size_t j0 = i0;
        while (j0 + 1 < post.size()) {
          int d = post[j0 + 1]->frame - post[j0]->frame;
          double w = d > 0 ? std::hypot(post[j0 + 1]->x - post[j0]->x,
                                        post[j0 + 1]->y - post[j0]->y) / d
                           : 1e300;
          if (w > 3.0 * s) break;
          ++j0;
        }
        int span = post[j0]->frame - post[i0]->frame;
        int nobs = 0;
        for (size_t k = i0; k <= j0; ++k)
          if (post[k]->observed) ++nobs;
        if (span > best_span) {
          best_span = span;
          best_obs = nobs;
          best_start = post[i0]->frame;
        }
        i0 = j0 + 1;
      }
      // The landing settles promptly: a slow chain starting 6+ frames
      // past the fall's end, across fast motion, is a different event
      // (a ghost the tracker settled on), not the touchdown's rest.
      if (best_span < 3 || best_obs < 2 || best_start > end_f + 5) continue;
      const TrackPoint* bp = nullptr;
      for (const auto& p : pts)
        if (p.frame == end_f) bp = &p;
      if (bp == nullptr) continue;
      double jump = std::hypot(post[0]->x - bp->x, post[0]->y - bp->y);
      if (jump > std::max(2.0 * std::hypot(slx0.slope, sl0.slope),
                           12.0 * s))
        continue;
      const double* H = court->h_img2court;
      double q2 = H[6] * bp->x + H[7] * bp->y + H[8];
      if (std::fabs(q2) < 1e-9) continue;
      double wx = (H[0] * bp->x + H[1] * bp->y + H[2]) / q2;
      double wy = (H[3] * bp->x + H[4] * bp->y + H[5]) / q2;
      double mpp = ImageYMpp(court, bp->x, bp->y);
      if (std::fabs(wx) > kHalfDbl + 2.5 ||
          std::fabs(wy) > kHalfLen + 2.5 || !(mpp > 0 && mpp < 2.0))
        continue;
      if (far_from_classic(end_f)) {
        if (std::getenv("TENNIS_TRACE_EV")) fprintf(stderr, "EV:TOUCHDOWN f=%d\n", end_f);
        cand_td.emplace_back(drop, end_f);
      }
    }
  }
}

// Trap-down: a gentle arrival that lands and stays — caught, trapped, or
// dying at the player's feet (rally-3.mov frame 371: a lob descends 12
// clean frames, lands at the shoe inside a leg occlusion, never rebounds;
// the 372 rise is a 1-frame crouch ghost). No V path can fire (the rise
// never sustains), the steep-fall touchdown never triggers (drop and
// speed floors), so judge the landing directly: a significant descent
// into a bottom that continues down-or-level, then the ball lingers
// (every take within 30px for 10 frames, 3+ sightings) with no sustained
// rise (2 consecutive rising sightings anywhere in the window is a
// rebound, not a trap — a lone ghost flicker doesn't break it). The
// bottom is a local minimum (the fall must not continue past it), lands
// continuously (no handover jump onto it), and lingers on evidence (5+
// frames past it). One landing keeps its deepest bottom (takes up the
// descent leg match too).
// No supplement-suppression: dedup arbitrates against V-path fires (the
// 379 dribble dip merges into 371 via the sustained-hop rule).
void TrapDowns(const Track& track, double s, const CourtGeom* court,
               std::vector<std::pair<double, int>>& out) {
  const auto& pts = track.points;
  struct TD {
    int f;
    double y, amp;
  };
  std::vector<TD> tds;
  for (const auto& b : pts) {
    if (!b.observed) continue;
    int f = b.frame;
    std::vector<double> dt, dx, dy;
    double ymax = -1e300;
    const TrackPoint* prev = nullptr;
    for (const auto& p : pts) {
      if (!p.observed || p.frame >= f || p.frame < f - 12) continue;
      dt.push_back(p.frame);
      dx.push_back(p.x);
      dy.push_back(p.y);
      ymax = std::max(ymax, p.y);
      prev = &p;
    }
    if (dt.size() < 6) continue;
    LinFit fl = FitLine(dt, dy), flx = FitLine(dt, dx);
    if (!(fl.slope > 0)) continue;
    if (fl.slope < std::max(0.6 * s, 0.6 * std::max(fl.rms, 0.3 * s)))
      continue;
    double drop = dy.back() - dy.front();
    if (drop < 8.0 * s) continue;
    if (b.y < ymax) continue;  // jumped back up: not a landing
    // A landing is a local minimum: the descent must not continue past
    // the bottom (a monotone fall or roll-in is still falling, not
    // landing).
    double aftmax = -1e300;
    for (const auto& p : pts) {
      if (p.frame <= f || p.frame > f + 6) continue;
      aftmax = std::max(aftmax, p.y);
    }
    if (b.y < aftmax) continue;
    // Continuity: no handover jump anywhere along the descent (a steep
    // fall that leaps sideways onto a static shoe never touched down
    // there — and neither did the plateau takes after the leap).
    double spd = std::hypot(flx.slope, fl.slope);
    bool jumped = false;
    const TrackPoint* q0 = nullptr;
    for (const auto& p : pts) {
      if (!p.observed || p.frame >= f || p.frame < f - 12) continue;
      if (q0 != nullptr) {
        int df = p.frame - q0->frame;
        double step =
            df > 0 ? std::hypot(p.x - q0->x, p.y - q0->y) / df : 1e300;
        if (step > std::max(3.0 * spd, 12.0 * s)) {
          jumped = true;
          break;
        }
      }
      q0 = &p;
    }
    {
      int df = b.frame - prev->frame;
      double step =
          df > 0
              ? std::hypot(b.x - prev->x, b.y - prev->y) / df
              : 1e300;
      if (step > std::max(3.0 * spd, 12.0 * s)) jumped = true;
    }
    if (jumped) continue;
    int nobs = 0;
    bool boxed = true;
    int wspan = 0;
    for (const auto& p : pts) {
      if (p.frame <= f || p.frame > f + 10) continue;
      if (std::hypot(p.x - b.x, p.y - b.y) > 30.0 * s) {
        boxed = false;
        break;
      }
      wspan = p.frame - f;
      if (p.observed) ++nobs;
    }
    // Linger needs evidence: a bottom at track end with 2 takes past it
    // is roll jitter, not a confirmed trap.
    if (!boxed || nobs < 3 || wspan < 5) continue;
    int run = 0;
    double py = b.y;
    bool rebound = false;
    for (const auto& p : pts) {
      if (!p.observed || p.frame <= f || p.frame > f + 10) continue;
      if (p.y < py - 0.5 * s) {
        if (++run >= 2) {
          rebound = true;
          break;
        }
      } else {
        run = 0;
      }
      py = p.y;
    }
    if (rebound) continue;
    // Energy: a trapped ball can never rise above the apex it fell
    // from — that creates energy, so the "trap" was a hand lowering
    // and holding the ball (rally-3.mov 371: 25px hand descent, then
    // an 86px toss relaunch), never a landing. A real trap's rebound
    // (592: 26px rise off a 59px fall) stays well under its drop.
    // Sightings only; unknown (no observed apex/future) keeps.
    {
      double apex_y = 1e300, future_y = 1e300;
      for (const auto& p : pts) {
        if (!p.observed) continue;
        if (p.frame < f - 25 || p.frame > f + 60) continue;
        if (p.frame <= f - 3) apex_y = std::min(apex_y, p.y);
        if (p.frame > f) future_y = std::min(future_y, p.y);
      }
      if (apex_y < 1e299 && future_y < 1e299) {
        double drop = b.y - apex_y, rise = b.y - future_y;
        if (rise > drop) continue;
      }
    }
    if (court && court->valid) {
      const double* H = court->h_img2court;
      double q2 = H[6] * b.x + H[7] * b.y + H[8];
      if (std::fabs(q2) < 1e-9) continue;
      double wx = (H[0] * b.x + H[1] * b.y + H[2]) / q2;
      double wy = (H[3] * b.x + H[4] * b.y + H[5]) / q2;
      if (std::hypot(wx, wy) > 25.0) continue;
    }
    if (std::getenv("TENNIS_TRACE_EV")) fprintf(stderr, "EV:TRAP f=%d\n", f);
    tds.push_back({f, b.y, drop});
  }
  std::sort(tds.begin(), tds.end(),
            [](const TD& a, const TD& b) { return a.y > b.y; });
  std::vector<int> kept;
  for (const auto& td : tds) {
    bool near = false;
    for (int g : kept)
      if (std::abs(td.f - g) <= 10) {
        near = true;
        break;
      }
    if (!near) {
      kept.push_back(td.f);
      out.emplace_back(td.amp, td.f);
    }
  }
}

}  // namespace

std::vector<int> DetectBounces(const Track& track, int width,
                               const CourtGeom* court,
                               const std::vector<int>& shots) {
  double s = width / 1280.0;
  std::vector<const TrackPoint*> obs;
  for (const auto& p : track.points)
    if (p.observed) obs.push_back(&p);
  if (obs.size() < 7) return {};
  std::vector<std::pair<double, int>> cand;  // (amplitude, frame)
  for (size_t k = 0; k < obs.size(); ++k) {
    const TrackPoint* p = obs[k];
    int f = p->frame;
    bool has_behind = false, has_ahead = false;
    double yb = 0, ya = 0;
    for (size_t a = (k >= 4 ? k - 4 : 0); a < k; ++a) {
      if (f - obs[a]->frame > 3) continue;
      if (!has_behind || obs[a]->y > yb) {
        yb = obs[a]->y;
        has_behind = true;
      }
    }
    for (size_t a = k + 1; a < obs.size() && a < k + 5; ++a) {
      if (obs[a]->frame - f > 3) continue;
      if (!has_ahead || obs[a]->y > ya) {
        ya = obs[a]->y;
        has_ahead = true;
      }
    }
    // Interpolated shoulder: the detector routinely misses impact frames
    // (blur/occlusion), so fall back to the nearest observed point within
    // the fit windows instead of dropping the bottom outright.
    if (!has_behind) {
      // Nearest observed take behind (obs is frame-sorted, so the
      // adjacent index is the nearest): a single check, not a search.
      if (k > 0 && f - obs[k - 1]->frame <= 6) {
        yb = obs[k - 1]->y;
        has_behind = true;
      }
    }
    if (!has_ahead) {
      if (k + 1 < obs.size() && obs[k + 1]->frame - f <= 6) {
        ya = obs[k + 1]->y;
        has_ahead = true;
      }
    }
    if (!has_behind || !has_ahead) continue;
    if (p->y < yb || p->y < ya) continue;  // not the low point
    std::vector<double> Lt, Lx, Ly, Rt, Rx, Ry;
    for (const auto* q : obs) {
      if (f - 6 <= q->frame && q->frame <= f) {
        Lt.push_back(q->frame);
        Lx.push_back(q->x);
        Ly.push_back(q->y);
      }
      if (f <= q->frame && q->frame <= f + 6) {
        Rt.push_back(q->frame);
        Rx.push_back(q->x);
        Ry.push_back(q->y);
      }
    }
    if (Lt.size() < 3 || Rt.size() < 3) continue;
    LinFit fl = FitLine(Lt, Ly), fr = FitLine(Rt, Ry);
    if (!(fl.slope > 0 && fr.slope < 0)) continue;
    // Per-side noise (mirrors Python): each slope stands clear of its
    // own window's fit residual.
    if (fl.slope < std::max(0.6 * s, 0.6 * std::max(fl.rms, 0.3 * s)))
      continue;
    if (-fr.slope < std::max(0.6 * s, 0.6 * std::max(fr.rms, 0.3 * s)))
      continue;
    double amp = std::min(p->y - Ly.front(), p->y - Ry.back());
    if (!BounceAmpOk(amp, p->x, p->y, s, court)) continue;
    LinFit fxl = FitLine(Lt, Lx), fxr = FitLine(Rt, Rx);
    if ((fxl.slope > 2.0 * s && fxr.slope < -2.0 * s) ||
        (fxl.slope < -2.0 * s && fxr.slope > 2.0 * s)) {
      // Half-volley override: long observed legs both sides of an
      // observed bottom are a bounced ball the racket sent back, not
      // a mid-air hit (a hit's legs are a 1-3 frame impulse).
      int nb = 0, na = 0;
      for (const auto* q : obs) {
        if (f - 8 <= q->frame && q->frame <= f) ++nb;
        if (f <= q->frame && q->frame <= f + 8) ++na;
      }
      if (nb < 8 || na < 8) continue;  // x reverses: a hit, not a bounce
    }
    double v_before = std::hypot(fxl.slope, fl.slope);
    double v_after = std::hypot(fxr.slope, fr.slope);
    // Elastic band: a near-unity ratio is an in-air wobble (no impact),
    // but a much faster rise is hit-assisted (a half-volley scoop off
    // the bounce) — the bounce still counts, unless the ball rolled in
    // on the ground first (a pickup launch, never airborne to bounce).
    if (v_after >= 0.95 * v_before && v_after <= 1.5 * v_before) continue;
    if (v_after > 1.5 * v_before) {
      // Flight provenance: a hit-assisted keep must have flown in —
      // risen to an apex before falling. A V off a rolled-in descent
      // (no rise into its high point) is a pickup launch, never
      // airborne to bounce. Unknown (under 4 frames of history) keeps.
      const TrackPoint* apex = nullptr;
      for (const auto& r : track.points) {
        if (r.frame < f - 25 || r.frame > f - 3) continue;
        if (!apex || r.y < apex->y) apex = &r;
      }
      if (apex) {
        double ymax = -1e300;
        int present = 0;
        for (const auto& r : track.points) {
          if (r.frame < apex->frame - 15 || r.frame > apex->frame) continue;
          ymax = std::max(ymax, r.y);
          ++present;
        }
        if (present >= 4 && ymax - apex->y < 5.0 * s) continue;
      }
    }
    if (court && court->valid) {
      double q0 = court->h_img2court[0] * p->x + court->h_img2court[1] * p->y +
                  court->h_img2court[2];
      double q1 = court->h_img2court[3] * p->x + court->h_img2court[4] * p->y +
                  court->h_img2court[5];
      double q2 = court->h_img2court[6] * p->x + court->h_img2court[7] * p->y +
                  court->h_img2court[8];
      if (std::fabs(q2) < 1e-9) continue;
      if (std::hypot(q0 / q2, q1 / q2) > 25.0) continue;  // in-air wobble
    }
    if (std::getenv("TENNIS_TRACE_EV")) fprintf(stderr, "EV:CLASSIC f=%d\n", f);
    cand.emplace_back(amp, f);
  }
  // Hidden cusps inside observation gaps (far-court bottoms): the
  // observed descent into the gap and ascent out of it pin the V's
  // intersection — same gates as an observed bottom, widened
  // windows. Observed only, never bridge shape.
  for (size_t i = 0; i + 1 < obs.size(); ++i) {
    int f0 = obs[i]->frame, f1 = obs[i + 1]->frame;
    int gap = f1 - f0 - 1;
    if (gap < 4 || gap > 20) continue;
    std::vector<double> Lt, Lx, Ly, Rt, Rx, Ry;
    for (size_t a = (i >= 5 ? i - 5 : 0); a <= i; ++a) {
      if (f0 - obs[a]->frame > 11) continue;
      Lt.push_back(obs[a]->frame);
      Lx.push_back(obs[a]->x);
      Ly.push_back(obs[a]->y);
    }
    for (size_t a = i + 1; a < obs.size() && a < i + 7; ++a) {
      if (obs[a]->frame - f1 > 18) continue;
      Rt.push_back(obs[a]->frame);
      Rx.push_back(obs[a]->x);
      Ry.push_back(obs[a]->y);
    }
    if (Lt.size() < 4 || Rt.size() < 4) continue;
    LinFit fl = FitLine(Lt, Ly), fr = FitLine(Rt, Ry);
    if (!(fl.slope > 0 && fr.slope < 0)) continue;
    if (fl.slope < std::max(0.6 * s, 0.6 * std::max(fl.rms, 0.3 * s)))
      continue;
    if (-fr.slope < std::max(0.6 * s, 0.6 * std::max(fr.rms, 0.3 * s)))
      continue;
    if (fl.rms > 2.0 * s || fr.rms > 2.0 * s) continue;
    double t_star = (fr.intercept - fl.intercept) / (fl.slope - fr.slope);
    if (!(f0 <= t_star && t_star <= f1)) continue;
    int f = (int)std::floor(t_star + 0.5);
    f = std::max(f0, std::min(f1, f));
    double y_star = fl.intercept + fl.slope * t_star;
    LinFit fxl = FitLine(Lt, Lx), fxr = FitLine(Rt, Rx);
    double x_star = (fxl.intercept + fxl.slope * t_star + fxr.intercept +
                     fxr.slope * t_star) /
                    2;
    // Amplitude against the legs' far ends, like the observed-bottom path:
    // the gap-adjacent points sit at the bottom when it lands on a gap
    // edge, which would collapse the amplitude to ~nothing.
    double amp = std::min(y_star - Ly.front(), y_star - Ry.back());
    if (gap == 4 && amp < 12.0 * s) continue;  // narrowest gap: demand a deep cusp
    if (!BounceAmpOk(amp, x_star, y_star, s, court)) continue;
    if ((fxl.slope > 2.0 * s && fxr.slope < -2.0 * s) ||
        (fxl.slope < -2.0 * s && fxr.slope > 2.0 * s))
      continue;  // x reverses: a hit, not a bounce
    double v_before = std::hypot(fxl.slope, fl.slope);
    double v_after = std::hypot(fxr.slope, fr.slope);
    if (v_after >= 0.95 * v_before) continue;  // elastic: no impact
    if (court && court->valid) {
      double q0 = court->h_img2court[0] * x_star +
                  court->h_img2court[1] * y_star + court->h_img2court[2];
      double q1 = court->h_img2court[3] * x_star +
                  court->h_img2court[4] * y_star + court->h_img2court[5];
      double q2 = court->h_img2court[6] * x_star +
                  court->h_img2court[7] * y_star + court->h_img2court[8];
      if (std::fabs(q2) < 1e-9) continue;
      if (std::hypot(q0 / q2, q1 / q2) > 25.0) continue;  // in-air wobble
    }
    if (std::getenv("TENNIS_TRACE_EV")) fprintf(stderr, "EV:GAP f=%d\n", f);
    cand.emplace_back(amp, f);
  }
  // Lone-take unions: a single observed take inside a void (a shadow/
  // shoe take the linker grabbed mid-gap) splits one void into two
  // sub-gaps that each fail alone (rms corruption, t* pushed past the
  // edge). Evaluate the union with the interior take ignored — same
  // gates as a gap cusp. Suppressed near classic/gap fires: a
  // supplement, never a replacement (dedup-deepest would otherwise let
  // the farther-amplitude union steal a correct fire's frame).
  for (size_t i = 0; i + 2 < obs.size(); ++i) {
    int f0 = obs[i]->frame, f1 = obs[i + 1]->frame, f2 = obs[i + 2]->frame;
    int g1 = f1 - f0 - 1, g2 = f2 - f1 - 1;
    if (g1 < 2 || g2 < 2) continue;
    int ugap = f2 - f0 - 1;
    if (ugap < 5 || ugap > 20) continue;
    std::vector<double> Lt, Lx, Ly, Rt, Rx, Ry;
    for (size_t a = (i >= 5 ? i - 5 : 0); a <= i; ++a) {
      if (f0 - obs[a]->frame > 11) continue;
      Lt.push_back(obs[a]->frame);
      Lx.push_back(obs[a]->x);
      Ly.push_back(obs[a]->y);
    }
    for (size_t a = i + 2; a < obs.size() && a < i + 8; ++a) {
      if (obs[a]->frame - f2 > 18) continue;
      Rt.push_back(obs[a]->frame);
      Rx.push_back(obs[a]->x);
      Ry.push_back(obs[a]->y);
    }
    if (Lt.size() < 4 || Rt.size() < 4) continue;
    LinFit fl = FitLine(Lt, Ly), fr = FitLine(Rt, Ry);
    if (!(fl.slope > 0 && fr.slope < 0)) continue;
    if (fl.slope < std::max(0.6 * s, 0.6 * std::max(fl.rms, 0.3 * s)))
      continue;
    if (-fr.slope < std::max(0.6 * s, 0.6 * std::max(fr.rms, 0.3 * s)))
      continue;
    if (fl.rms > 2.0 * s || fr.rms > 2.0 * s) continue;
    double t_star = (fr.intercept - fl.intercept) / (fl.slope - fr.slope);
    if (!(f0 <= t_star && t_star <= f2)) continue;
    int f = (int)std::floor(t_star + 0.5);
    f = std::max(f0, std::min(f2, f));
    double y_star = fl.intercept + fl.slope * t_star;
    LinFit fxl = FitLine(Lt, Lx), fxr = FitLine(Rt, Rx);
    double x_star = (fxl.intercept + fxl.slope * t_star + fxr.intercept +
                     fxr.slope * t_star) /
                    2;
    double amp = std::min(y_star - Ly.front(), y_star - Ry.back());
    if (!BounceAmpOk(amp, x_star, y_star, s, court)) continue;
    if ((fxl.slope > 2.0 * s && fxr.slope < -2.0 * s) ||
        (fxl.slope < -2.0 * s && fxr.slope > 2.0 * s))
      continue;  // x reverses: a hit, not a bounce
    double v_before = std::hypot(fxl.slope, fl.slope);
    double v_after = std::hypot(fxr.slope, fr.slope);
    if (v_after >= 0.95 * v_before) continue;  // elastic: no impact
    if (court && court->valid) {
      double q0 = court->h_img2court[0] * x_star +
                  court->h_img2court[1] * y_star + court->h_img2court[2];
      double q1 = court->h_img2court[3] * x_star +
                  court->h_img2court[4] * y_star + court->h_img2court[5];
      double q2 = court->h_img2court[6] * x_star +
                  court->h_img2court[7] * y_star + court->h_img2court[8];
      if (std::fabs(q2) < 1e-9) continue;
      if (std::hypot(q0 / q2, q1 / q2) > 25.0) continue;  // in-air wobble
    }
    bool near = false;
    for (const auto& c : cand)
      if (std::abs(f - c.second) <= 10) {
        near = true;
        break;
      }
    if (near) continue;
    if (std::getenv("TENNIS_TRACE_EV")) fprintf(stderr, "EV:UNION f=%d\n", f);
    cand.emplace_back(amp, f);
  }
  const std::vector<std::pair<double, int>> vframes = cand;
  std::vector<std::pair<double, int>> cand_vr, cand_td;
  RescueBounces(track, s, court, vframes, cand_vr, cand_td);
  // Pass 2: bobble-filter every V-path candidate (classic + gap +
  // rescue-V); hop exemptions read the unfiltered set so order never
  // matters. Touchdowns ride falls that are monotone by construction.
  std::vector<std::pair<double, int>> all = cand;
  all.insert(all.end(), cand_vr.begin(), cand_vr.end());
  all.insert(all.end(), cand_td.begin(), cand_td.end());
  std::vector<std::pair<double, int>> kept;
  for (const auto& c : cand)
    if (!FallBobbles(track, c.second, all, s)) kept.push_back(c);
  for (const auto& c : cand_vr)
    if (!FallBobbles(track, c.second, all, s)) kept.push_back(c);
  kept.insert(kept.end(), cand_td.begin(), cand_td.end());
  HandoverTouchdowns(track, s, kept, shots, kept);
  TeleportBounces(track, s, kept, shots, kept);
  TrapDowns(track, s, court, kept);
  cand = std::move(kept);
  // Deepest bottom wins each 10-frame neighborhood (stable: ties
  // keep frame order, exactly like the twin) — except across a
  // genuine hop: two touchdowns with a rise between them (a skid-hop
  // double) are distinct events, not a double bottom.
  auto y_at = [&](int f, double& y) {
    for (const auto& p : track.points)
      if (p.frame == f) {
        y = p.y;
        return true;
      }
    return false;
  };
  std::stable_sort(cand.begin(), cand.end(), [](const auto& a, const auto& b) {
    return a.first > b.first;
  });
  std::vector<int> out;
  for (const auto& [amp, f] : cand) {
    (void)amp;
    bool near = false;
    for (int g : out) {
      if (std::abs(f - g) > 10) continue;
      int lo = std::min(f, g), hi = std::max(f, g);
      double yf = 0, yg = 0;
      bool hop = false;
      if (y_at(f, yf) && y_at(g, yg)) {
        double m = 1e300;
        bool any = false;
        for (const auto& p : track.points) {
          if (p.frame > lo && p.frame < hi) {
            any = true;
            m = std::min(m, p.y);
          }
        }
        // A genuine hop sustains its rise off the first landing (2+
        // consecutive rising sightings); a lone flicker between bottoms
        // is the same landing event (a dribble, a crouch ghost), not a
        // re-bounce (rally-3.mov 371 + 379 and 942 + 950 merge; 1258 +
        // 1266 still split). Sightings only: bridge takes interpolate
        // the rise they would confirm, which is circular.
        int run = 0;
        double prev = (lo == f) ? yf : yg;
        for (const auto& p : track.points) {
          if (p.frame <= lo || p.frame >= hi) continue;
          if (!p.observed) continue;
          if (p.y < prev - 0.5 * s) {
            if (++run >= 2) break;
          } else {
            run = 0;
          }
          prev = p.y;
        }
        if (any && std::max(yf, yg) - m >= 3.0 * s && run >= 2) hop = true;
      }
      if (hop) continue;
      near = true;
      break;
    }
    if (!near) out.push_back(f);
  }
  std::sort(out.begin(), out.end());
  return out;
}

namespace {
double LineDev(const TrackPoint& p, const TrackPoint& a, const TrackPoint& b) {
  if (b.frame == a.frame) return 0.0;
  double w = (double)(p.frame - a.frame) / (b.frame - a.frame);
  return std::hypot(p.x - (a.x + (b.x - a.x) * w),
                    p.y - (a.y + (b.y - a.y) * w));
}
}  // namespace

void DespikeTrack(Track& track, int width) {
  double s = width / 1280.0;
  auto& pts = track.points;
  size_t n = pts.size();
  if (n < 4) return;
  // Two-phase: decide on original points, then replace.
  std::map<size_t, std::pair<double, double>> kill;
  for (size_t i = 0; i < n; ++i) {
    const TrackPoint& p = pts[i];
    if (!p.observed) continue;
    std::vector<const TrackPoint*> nb;
    std::vector<std::pair<const TrackPoint*, const TrackPoint*>> lines;
    const TrackPoint *ra = nullptr, *rb = nullptr;
    bool repl_ok = false;
    double rx = 0, ry = 0;
    if (i >= 2 && i + 2 < n) {
      nb = {&pts[i - 2], &pts[i - 1], &pts[i + 1], &pts[i + 2]};
      lines = {{&pts[i - 2], &pts[i - 1]}, {&pts[i + 1], &pts[i + 2]}};
      ra = &pts[i - 1];
      rb = &pts[i + 1];
    } else if (i == 1 || i + 2 == n) {
      if (i == 1) {
        nb = {&pts[0], &pts[2], &pts[3]};
        lines = {{&pts[2], &pts[3]}};
      } else {
        nb = {&pts[n - 4], &pts[n - 3], &pts[n - 1]};
        lines = {{&pts[n - 4], &pts[n - 3]}};
      }
      ra = &pts[i - 1];
      rb = &pts[i + 1];
    } else {  // endpoints
      if (i == 0) {
        nb = {&pts[1], &pts[2], &pts[3]};
        lines = {{&pts[1], &pts[2]}};
      } else {
        nb = {&pts[n - 4], &pts[n - 3], &pts[n - 2]};
        lines = {{&pts[n - 3], &pts[n - 2]}};
      }
      ra = lines[0].first;
      rb = lines[0].second;
    }
    if (nb.back()->frame - nb.front()->frame > 8) continue;
    std::vector<double> mxs, mys;
    for (const auto* q : nb) {
      mxs.push_back(q->x);
      mys.push_back(q->y);
    }
    double mx = num::Median(mxs), my = num::Median(mys);
    if (std::hypot(p.x - mx, p.y - my) <= 10.0 * s) continue;
    double best = 1e300;
    for (const auto& [a, b] : lines) best = std::min(best, LineDev(p, *a, *b));
    if (best <= 6.0 * s) continue;  // fits one side: a kink
    // Valley spare: a 1-take upward flicker is physically impossible (a
    // ghost), but a 1-take downward spike is a candidate impact bottom
    // (rally-3.mov frame 371: the linker catches the true landing low
    // between a shoe-flash peak and the rise). Spare takes whose
    // deviation runs predominantly downward; the event paths (with leg,
    // amplitude and court gates) judge them. Sideways spikes still die.
    if ((p.y - my) > std::fabs(p.x - mx)) continue;
    // Interior/near-interior interpolate between bracketing frames;
    // endpoints extrapolate along their one-sided line.
    bool bracketed = i > 0 && i + 1 < n;
    if ((bracketed && rb->frame > ra->frame) ||
        (!bracketed && rb->frame != ra->frame)) {
      double w = (double)(p.frame - ra->frame) / (rb->frame - ra->frame);
      rx = ra->x + (rb->x - ra->x) * w;
      ry = ra->y + (rb->y - ra->y) * w;
      repl_ok = true;
    }
    if (repl_ok) kill[i] = {rx, ry};
  }
  for (const auto& [i, xy] : kill) {
    pts[i].x = xy.first;
    pts[i].y = xy.second;
    pts[i].observed = false;
    pts[i].conf = 0.5;
  }
}

void SmoothTrack(Track& track) {
  auto& pts = track.points;
  size_t n = pts.size();
  if (n < 7) return;
  std::set<int> hitset(track.hits.begin(), track.hits.end());
  std::vector<size_t> bounds = {0};
  for (size_t i = 0; i < n; ++i)
    if (hitset.count(pts[i].frame)) bounds.push_back(i);
  bounds.push_back(n);
  for (size_t b = 0; b + 1 < bounds.size(); ++b) {
    size_t a = bounds[b], e = bounds[b + 1];
    if (e - a < 7) continue;
    std::vector<double> xs, ys;
    for (size_t i = a; i < e; ++i) {
      xs.push_back(pts[i].x);
      ys.push_back(pts[i].y);
    }
    size_t len = e - a;
    int w = static_cast<int>(std::min<size_t>(9, len % 2 ? len : len - 1));
    if (w < 5) continue;
    std::vector<double> sx = num::SavGol2(xs, w);
    std::vector<double> sy = num::SavGol2(ys, w);
    for (size_t i = a; i < e; ++i) {
      if (pts[i].observed) {
        pts[i].x = 0.7 * pts[i].x + 0.3 * sx[i - a];
        pts[i].y = 0.7 * pts[i].y + 0.3 * sy[i - a];
      } else {
        pts[i].x = sx[i - a];
        pts[i].y = sy[i - a];
      }
    }
  }
}

std::vector<Track> FinalizeTracks(std::vector<Track> tracks, int width,
                                  const TrackerConfig& cfg,
                                  const CourtGeom* court) {
  tracks = FillGaps(std::move(tracks), cfg);
  for (auto& t : tracks) DespikeTrack(t, width);
  // Merge on FILLED tracks (sparse tracklets share too few frames).
  tracks = MergeOverlapHandovers(std::move(tracks), width);
  for (auto& t : tracks) DespikeTrack(t, width);
  for (auto& t : tracks) {
    // Shots first: the handover-touchdown rule suppresses hit-adjacent
    // candidates (a hit's turnaround mimics fall + flat + jump).
    std::vector<int> shots = DetectShots(t, width);
    for (int jh : t.junction_hits) {
      bool near = false;
      for (int h : shots)
        if (std::abs(jh - h) <= 5) {
          near = true;
          break;
        }
      if (!near) shots.push_back(jh);
    }
    if (const char* dd = std::getenv("TENNIS_DUMP_PRE")) {
      char path[512];
      snprintf(path, sizeof(path), "%s_track%d.txt", dd, t.id);
      FILE* fh = fopen(path, "w");
      if (fh) {
        fprintf(fh, "shots:");
        for (int h : shots) fprintf(fh, " %d", h);
        fprintf(fh, "\n");
        for (const auto& p : t.points)
          fprintf(fh, "%d %.2f %.2f %d\n", p.frame, p.x, p.y,
                  p.observed ? 1 : 0);
        fclose(fh);
      }
    }
    t.bounces = DetectBounces(t, width, court, shots);
    t.hits.clear();
    for (int h : shots) {
      bool near_bounce = false;
      for (int b : t.bounces)
        if (std::abs(h - b) <= 4) {
          near_bounce = true;
          break;
        }
      if (!near_bounce) t.hits.push_back(h);
    }
    std::sort(t.hits.begin(), t.hits.end());
    SmoothTrack(t);
  }
  return tracks;
}

}  // namespace tennis
