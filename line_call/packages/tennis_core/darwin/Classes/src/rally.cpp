#include "tennis/rally.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

#include "tennis/geom.hpp"
#include "tennis/num.hpp"

namespace tennis {
namespace {

std::vector<double> Speeds(const Track& track) {
  size_t n = track.points.size();
  std::vector<double> fs(n), xs(n), ys(n);
  for (size_t i = 0; i < n; ++i) {
    fs[i] = track.points[i].frame;
    xs[i] = track.points[i].x;
    ys[i] = track.points[i].y;
  }
  std::vector<double> vx = num::Gradient(xs, fs);
  std::vector<double> vy = num::Gradient(ys, fs);
  std::vector<double> sp(n);
  for (size_t i = 0; i < n; ++i) sp[i] = std::hypot(vx[i], vy[i]);
  return sp;
}

// V-class: observed-only rise (3px within +8f) after the bounce
// bottom. Bridges lie (extrapolated rise); takes don't.
bool BounceHasRise(const Track& track, int frame, double s) {
  double y0 = 0;
  bool have = false;
  for (const auto& p : track.points)
    if (p.frame == frame) {
      y0 = p.y;
      have = true;
      break;
    }
  if (!have) return false;
  for (const auto& p : track.points)
    if (p.observed && frame < p.frame && p.frame <= frame + 8 &&
        y0 - p.y >= 3.0 * s)
      return true;
  return false;
}

int FindServe(const Track& track, int start, double fps, int width,
              bool& found) {
  found = false;
  double s = width / 1280.0;
  std::vector<const TrackPoint*> pts;
  for (const auto& p : track.points)
    if (p.frame >= start - static_cast<int>(fps * 3) &&
        p.frame <= start + static_cast<int>(fps * 1))
      pts.push_back(&p);
  if (pts.size() < 10) return -1;
  double x0 = pts[0]->x, x1 = x0, y0 = pts[0]->y, y1 = y0;
  for (const auto* p : pts) {
    x0 = std::min(x0, p->x);
    x1 = std::max(x1, p->x);
    y0 = std::min(y0, p->y);
    y1 = std::max(y1, p->y);
  }
  if (x1 - x0 > 120 * s) return -1;
  if (y1 - y0 < 15 * s) return -1;
  // A toss RELEASE (static -> rise) is a real kink but its leg
  // apexes within a few frames when aborted; a struck ball never
  // apexes that fast.
  auto apexes_after = [&](int h) {
    double yy[13];
    for (int j = 0; j < 13; ++j) {
      const TrackPoint* q = nullptr;
      for (const auto& p : track.points)
        if (p.frame == h + j) {
          q = &p;
          break;
        }
      if (!q) return false;
      yy[j] = q->y;
    }
    int k = 0;
    for (int j = 1; j < 13; ++j)
      if (yy[j] < yy[k]) k = j;
    return 0 < k && k < 12 && yy[0] - yy[k] > 8.0 &&
           yy[12] - yy[k] > 4.0;
  };
  for (int h : track.hits) {
    if (pts.front()->frame <= h && h <= pts.back()->frame + 5 &&
        !apexes_after(h)) {
      found = true;
      return h;
    }
  }
  size_t n = pts.size();
  std::vector<double> ys(n), fs(n);
  for (size_t i = 0; i < n; ++i) {
    ys[i] = pts[i]->y;
    fs[i] = pts[i]->frame;
  }
  std::vector<double> vy = num::Gradient(ys, fs);
  size_t k = 0;
  for (size_t i = 1; i < n; ++i)
    if (vy[i] < vy[k]) k = i;
  if (vy[k] < -3.0 * s && k >= 10 && !apexes_after(pts[k]->frame)) {
    found = true;
    return pts[k]->frame;
  }
  return -1;
}

}  // namespace

const Track* PickMainTrack(const std::vector<Track>& tracks,
                           const CourtGeom* court, int width) {
  if (tracks.empty()) return nullptr;
  double s = width / 1280.0;
  const Track* best = nullptr;
  double best_score = -1.0;
  for (const auto& t : tracks) {
    std::vector<double> sp = Speeds(t);
    double moving = 0;
    for (double v : sp)
      if (v > 2.0 * s) moving += 1;
    double score =
        moving + 20 * t.hits.size() + 10 * t.bounces.size();
    if (court && court->valid) {
      int near = 0, tot = 0;
      for (size_t i = 0; i < t.points.size(); i += 3) {
        const auto& p = t.points[i];
        double wx, wy;
        ++tot;
        if (ApplyH(court->h_img2court, p.x, p.y, wx, wy) &&
            std::fabs(wx) < 9.0 && std::fabs(wy) < 16.0)
          ++near;
      }
      // points[::3] is empty only for an empty track; guard anyway.
      if (t.points.empty()) tot = 1;
      score += 100.0 * near / std::max(1, tot);
    }
    if (score > best_score) {
      best_score = score;
      best = &t;
    }
  }
  return best;
}

std::vector<Rally> SegmentRallies(const Track& track, double fps, int width,
                                  const CourtGeom* court) {
  if (track.points.size() < 8) return {};
  double s = width / 1280.0;
  std::vector<double> sp = Speeds(track);
  // Dead zones: slow for >= 0.75s.
  int need = static_cast<int>(fps * 0.75);
  std::vector<std::pair<int, int>> cuts;
  size_t i = 0;
  while (i < sp.size()) {
    if (!(sp[i] < 2.0 * s)) {
      ++i;
      continue;
    }
    size_t j = i;
    while (j < sp.size() && sp[j] < 2.0 * s) ++j;
    if (static_cast<int>(j - i) >= need) {
      // A zone never spans an event (impact = alive): split slow
      // far-court bottoms at their bounce/hit instead of zoning
      // out the live rally. Mirrors the Python twin exactly.
      int z0 = track.points[i].frame, z1 = track.points[j - 1].frame;
      std::vector<int> bd = {z0 - 1};
      for (int h : track.hits)
        if (z0 <= h && h <= z1) bd.push_back(h);
      for (int b : track.bounces)
        if (z0 <= b && b <= z1) bd.push_back(b);
      bd.push_back(z1 + 1);
      std::sort(bd.begin(), bd.end());
      bd.erase(std::unique(bd.begin(), bd.end()), bd.end());
      for (size_t k = 0; k + 1 < bd.size(); ++k)
        if (bd[k + 1] - bd[k] - 1 >= need)
          cuts.emplace_back(bd[k] + 1, bd[k + 1] - 1);
    }
    i = j;
  }
  // Live intervals = complement of dead zones.
  int first = track.points.front().frame, last = track.points.back().frame;
  std::vector<std::pair<int, int>> bounds;
  std::sort(cuts.begin(), cuts.end());
  int cur = first;
  for (const auto& [z0, z1] : cuts) {
    if (z0 > cur + 5) bounds.emplace_back(cur, z0 - 1);
    cur = std::max(cur, z1 + 1);
  }
  if (cur <= last - 5) bounds.emplace_back(cur, last);
  // Events orphaned in cut gaps (a point-ending OUT bounce sits in the
  // dead roll-out, never in live play) belong to the nearest bound.
  // Strict < keeps the earliest bound on ties: the point that ended.
  if (!bounds.empty()) {
    std::vector<int> events = track.hits;
    events.insert(events.end(), track.bounces.begin(), track.bounces.end());
    for (int e : events) {
      bool covered = false;
      for (const auto& [a, b] : bounds)
        if (a <= e && e <= b) {
          covered = true;
          break;
        }
      if (covered) continue;
      size_t bi = 0;
      int bd = std::numeric_limits<int>::max();
      for (size_t k = 0; k < bounds.size(); ++k) {
        int d = e < bounds[k].first ? bounds[k].first - e
                                    : e - bounds[k].second;
        if (d < bd) {
          bd = d;
          bi = k;
        }
      }
      bounds[bi].first = std::min(bounds[bi].first, e);
      bounds[bi].second = std::max(bounds[bi].second, e);
    }
  }
  std::vector<Rally> rallies;
  for (const auto& [a, b] : bounds) {
    if (b - a + 1 < static_cast<int>(fps * 0.4)) continue;
    std::vector<int> hits;
    for (int h : track.hits)
      if (a <= h && h <= b) hits.push_back(h);
    std::vector<BounceCall> bounces;
    for (int bf : track.bounces) {
      if (!(a <= bf && bf <= b)) continue;
      const TrackPoint* p = nullptr;
      for (const auto& q : track.points)
        if (q.frame == bf) {
          p = &q;
          break;
        }
      if (!p) continue;  // Python would raise; unreachable in practice
      std::string call;
      double wx, wy;
      JudgeBounce(p->x, p->y, court, call, wx, wy);
      BounceCall bc;
      bc.frame = bf;
      bc.x = p->x;
      bc.y = p->y;
      std::strncpy(bc.call, call.c_str(), sizeof(bc.call) - 1);
      bc.wx = wx;
      bc.wy = wy;
      bounces.push_back(bc);
    }
    // Evidence gate.
    std::vector<const TrackPoint*> seg;
    std::vector<double> seg_sp;
    for (size_t k = 0; k < track.points.size(); ++k) {
      int f = track.points[k].frame;
      if (a <= f && f <= b) {
        seg.push_back(&track.points[k]);
        seg_sp.push_back(sp[k]);
      }
    }
    double peak = 0;
    for (double v : seg_sp) peak = std::max(peak, v);
    double x0 = seg[0]->x, x1 = x0, y0 = seg[0]->y, y1 = y0;
    for (const auto* p : seg) {
      x0 = std::min(x0, p->x);
      x1 = std::max(x1, p->x);
      y0 = std::min(y0, p->y);
      y1 = std::max(y1, p->y);
    }
    double xr = x1 - x0;
    double range = std::hypot(xr, y1 - y0);
    // A bound holding a validated impact is live play: from behind the
    // court the ball travels in depth (small image-x range), so an
    // x-only motion gate vetoes real rallies. The floor below only
    // rejects sub-jitter ghosts; the court-fraction gate still rejects
    // off-court ones.
    bool live = ((!hits.empty() || !bounces.empty()) &&
                 (peak > 2.5 * s || range > 10 * s)) ||
                (peak > 30 * s && xr > 150 * s);
    if (!live) continue;
    if (court && court->valid) {
      if (OnCourtFraction(track, a, b, *court, width) < 0.15) continue;
    }
    bool sfound = false;
    int serve = FindServe(track, a, fps, width, sfound);
    Rally r;
    r.index = static_cast<int>(rallies.size()) + 1;
    r.track_id = track.id;
    r.start = a;
    r.end = b;
    r.hits = std::move(hits);
    r.bounces = std::move(bounces);
    r.serve_frame = sfound ? serve : -1;
    rallies.push_back(std::move(r));
  }
  return rallies;
}

bool TrackOnCourt(const Track& track, const CourtGeom* court) {
  if (!court || !court->valid) return true;
  // NOTE: width is baked into the calibration; the Python twin reads it
  // from the court object context (1280 in every shipped path). The
  // quad test itself is resolution-independent.
  if (OnCourtCount(track, *court, 1280) >= 10) return true;
  if (OnCourtFraction(track, 0, 1000000000, *court, 1280) >= 0.15) return true;
  for (int bf : track.bounces) {
    const TrackPoint* p = nullptr;
    for (const auto& q : track.points)
      if (q.frame == bf) {
        p = &q;
        break;
      }
    if (!p) continue;
    double wx, wy;
    if (!ApplyH(court->h_img2court, p->x, p->y, wx, wy)) continue;
    if (std::fabs(wx) <= kHalfDbl + 2.5 && std::fabs(wy) <= kHalfLen + 2.5)
      return true;
  }
  return false;
}

std::vector<Track> FilterTracksToCourt(std::vector<Track> tracks,
                                       const CourtGeom* court, int width) {
  (void)width;
  if (!court || !court->valid) return tracks;
  std::vector<Track> out;
  for (auto& t : tracks)
    if (TrackOnCourt(t, court)) out.push_back(std::move(t));
  return out;
}

void JudgeBounce(double x, double y, const CourtGeom* court, std::string& call,
                 double& wx, double& wy) {
  if (!court || !court->valid) {
    call = "?";
    wx = wy = 0;
    return;
  }
  if (!ApplyH(court->h_img2court, x, y, wx, wy)) {
    call = "?";
    wx = wy = 0;
    return;
  }
  // Per-axis local meters-per-pixel: a grazing view resolves sideline
  // distance far better than baseline distance (rally-3.mov mid-frame:
  // 4.6 vs 74 cm/px), so a single worst-case sigma vetoes confident
  // sideline calls many times over. Judge each axis on its own sigma.
  double mppx = 0, mppy = 0;
  for (int i = 0; i < 2; ++i) {
    double px = 0, py = 0;
    if (!ApplyH(court->h_img2court, x + (i ? -2.0 : 2.0), y, px, py))
      mppx = 1e300;
    else
      mppx = std::max(mppx, std::hypot(px - wx, py - wy) / 2.0);
    if (!ApplyH(court->h_img2court, x, y + (i ? -2.0 : 2.0), px, py))
      mppy = 1e300;
    else
      mppy = std::max(mppy, std::hypot(px - wx, py - wy) / 2.0);
  }
  double dx_out = std::fabs(wx) - kHalfDbl;
  double dy_out = std::fabs(wy) - kHalfLen;
  bool out_x = dx_out > 0.06, out_y = dy_out > 0.06;
  call = (out_x || out_y) ? "OUT" : "IN";
  // The far baseline is extrapolated (service-anchored, tape-occluded),
  // never paint-pinned like the near corners: its line error grows with
  // depth (~0.3px near, ~1px at the far baseline), and at 60-90cm/px of
  // far-court depth resolution that error dominates the 1px detection
  // noise mpp assumes. Fold it into the depth sigma (RSS) so far-marginal
  // balls (rally-3.mov 592: 3.3m past at 0.9m/px) land honestly
  // uncallable instead of confidently OUT. Lateral mapping stays as-is:
  // the sidelines are directly detected at every depth.
  double fdepth = (wy + kHalfLen) / (2.0 * kHalfLen);
  if (fdepth < 0.0) fdepth = 0.0;
  double hpx = 0.3 + 0.7 * fdepth;
  double sigy = mppy * std::sqrt(1.0 + hpx * hpx);
  // Uncallable within 3-sigma of the deciding line at local resolution,
  // or past any callable geometry. OUT stands on any confident out
  // axis; IN needs both axes confidently inside.
  bool conf_x = mppx <= 2.0 && std::fabs(dx_out - 0.06) >= 3.0 * mppx;
  bool conf_y = mppy <= 2.0 && std::fabs(dy_out - 0.06) >= 3.0 * sigy;
  bool ok = (out_x && conf_x) || (out_y && conf_y) ||
            (!out_x && !out_y && conf_x && conf_y);
  if (!ok) call = "?";
}

std::vector<Rally> SegmentAllTracks(const std::vector<Track>& tracks,
                                    double fps, int width,
                                    const CourtGeom* court) {
  double s = width / 1280.0;
  std::vector<Rally> all;
  for (const auto& t : tracks) {
    if (t.stray) continue;  // intruders never become rallies
    std::vector<double> sp = Speeds(t);
    double moving = 0;
    for (double v : sp)
      if (v > 2.0 * s) moving += 1;
    if (moving < fps * 0.5 && t.hits.empty() && t.bounces.empty()) continue;
    std::vector<Rally> rs = SegmentRallies(t, fps, width, court);
    all.insert(all.end(), rs.begin(), rs.end());
  }
  // Cross-track echo drop: a touchdown-class bounce on a fully-contained
  // short track within 30f after a V-class bounce on the outer track at
  // an unphysical implied speed (>20 m/s sustained post-impact) is the
  // same impact echoed on a ghost branch — drop the echo, then re-gate
  // emptied rallies (a bounceless motionless rally is dead).
  for (auto& r : all) {
    const Track* inner = nullptr;
    for (const auto& t : tracks)
      if (t.id == r.track_id) {
        inner = &t;
        break;
      }
    if (!inner) continue;
    std::vector<BounceCall> kept;
    for (const auto& b2 : r.bounces) {
      bool echo = false;
      if (!BounceHasRise(*inner, b2.frame, s)) {
        for (const auto& q : all) {
          if (q.track_id == r.track_id) continue;
          const Track* outer = nullptr;
          for (const auto& t : tracks)
            if (t.id == q.track_id) {
              outer = &t;
              break;
            }
          if (!outer) continue;
          if (!(outer->start() <= inner->start() - 10 &&
                inner->end() + 10 <= outer->end()))
            continue;
          for (const auto& b1 : q.bounces) {
            if (!(b1.frame < b2.frame && b2.frame <= b1.frame + 30)) continue;
            if (!BounceHasRise(*outer, b1.frame, s)) continue;
            double dt = (b2.frame - b1.frame) / fps;
            if (dt <= 0) continue;
            double v = std::hypot(b2.wx - b1.wx, b2.wy - b1.wy) / dt;
            if (v > 20.0) {
              echo = true;
              break;
            }
          }
          if (echo) break;
        }
      }
      if (!echo) kept.push_back(b2);
    }
    r.bounces = std::move(kept);
  }
  {
    std::vector<Rally> live;
    for (auto& r : all) {
      const Track* tr = nullptr;
      for (const auto& t : tracks)
        if (t.id == r.track_id) {
          tr = &t;
          break;
        }
      double moving = 0;
      if (tr) {
        for (double v : Speeds(*tr))
          if (v > 2.0 * s) moving += 1;
      }
      if (r.bounces.empty() && r.hits.empty() && moving < fps * 0.5) continue;
      live.push_back(std::move(r));
    }
    all = std::move(live);
  }
  std::stable_sort(all.begin(), all.end(),
                   [](const Rally& a, const Rally& b) { return a.start < b.start; });
  for (size_t n = 0; n < all.size(); ++n) all[n].index = (int)n + 1;
  return all;
}

}  // namespace tennis
