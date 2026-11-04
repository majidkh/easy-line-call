#include "tennis/tracker.hpp"

#include <algorithm>
#include <cmath>
#include <map>
#include <set>

#include "tennis/num.hpp"

namespace tennis {
namespace {

struct Window {
  std::vector<double> t, x, y;
};

// 3-pt moving average of a tail/head window (keeps endpoints).
Window Denoise(const std::vector<TrackPoint>& pts) {
  Window w;
  for (const auto& p : pts) {
    w.t.push_back(p.frame);
    w.x.push_back(p.x);
    w.y.push_back(p.y);
  }
  if (w.t.size() >= 3) {
    std::vector<double> ox = w.x, oy = w.y;
    for (size_t i = 1; i + 1 < w.t.size(); ++i) {
      w.x[i] = (ox[i - 1] + 2 * ox[i] + ox[i + 1]) / 4;
      w.y[i] = (oy[i - 1] + 2 * oy[i] + oy[i + 1]) / 4;
    }
  }
  return w;
}

// Fit residual (and coefficients); deg-2 like _fit_resid.
bool FitResid(const std::vector<double>& t, const std::vector<double>& v,
              double& resid, std::vector<double>& coef) {
  if (t.size() <= 2) return false;
  if (!num::PolyFit(t, v, 2, coef)) return false;
  double s = 0;
  for (size_t i = 0; i < t.size(); ++i) {
    double d = num::PolyVal(coef, t[i]) - v[i];
    s += d * d;
  }
  resid = std::sqrt(s / t.size());
  return true;
}

struct Bridge {
  bool ok = false;
  double resid = 0;
  std::vector<double> xs, ys, gf;
};

// Best smooth-quadratic bridge across [gap0, gap1].
Bridge SmoothPair(const std::vector<TrackPoint>& a_tail,
                  const std::vector<TrackPoint>& b_head, int gap0, int gap1) {
  Bridge br;
  Window A = Denoise(a_tail), B = Denoise(b_head);
  std::vector<double> t = A.t, xa = A.x, ya = A.y;
  t.insert(t.end(), B.t.begin(), B.t.end());
  xa.insert(xa.end(), B.x.begin(), B.x.end());
  ya.insert(ya.end(), B.y.begin(), B.y.end());
  double rx, ry;
  std::vector<double> cx, cy;
  if (!FitResid(t, xa, rx, cx) || !FitResid(t, ya, ry, cy)) return br;
  br.ok = true;
  br.resid = std::max(rx, ry);
  for (int g = gap0; g <= gap1; ++g) {
    br.gf.push_back(g);
    br.xs.push_back(num::PolyVal(cx, g));
    br.ys.push_back(num::PolyVal(cy, g));
  }
  return br;
}

// Best single-cusp (hidden bounce) bridge.
Bridge BouncePair(const std::vector<TrackPoint>& a_tail,
                  const std::vector<TrackPoint>& b_head, int gap0, int gap1) {
  Bridge best;
  Window A = Denoise(a_tail), B = Denoise(b_head);
  std::vector<double> t = A.t, xa = A.x;
  t.insert(t.end(), B.t.begin(), B.t.end());
  xa.insert(xa.end(), B.x.begin(), B.x.end());
  double rx;
  std::vector<double> cx;
  if (!FitResid(t, xa, rx, cx)) return best;
  std::vector<double> gf;
  for (int g = gap0; g <= gap1; ++g) gf.push_back(g);
  for (int cusp = gap0; cusp <= gap1; ++cusp) {
    std::vector<double> lt, lx, ly, rt, rxv, ryv;
    for (size_t i = 0; i < A.t.size(); ++i)
      if (A.t[i] < cusp) {
        lt.push_back(A.t[i]);
        lx.push_back(A.x[i]);
        ly.push_back(A.y[i]);
      }
    for (size_t i = 0; i < B.t.size(); ++i)
      if (B.t[i] > cusp) {
        rt.push_back(B.t[i]);
        rxv.push_back(B.x[i]);
        ryv.push_back(B.y[i]);
      }
    (void)lx;
    (void)rxv;
    if (lt.size() < 2 || rt.size() < 2) continue;
    std::vector<double> cl, cr;
    if (!num::PolyFit(lt, ly, 1, cl) || !num::PolyFit(rt, ryv, 1, cr)) continue;
    double lv = cl[0], rv = cr[0];
    if (!(lv > 0.5 && rv < -0.5)) continue;
    std::vector<double> lc, rc;
    if (!num::PolyFit(lt, ly,
                        static_cast<int>(std::min<size_t>(2, lt.size() - 1)),
                        lc))
      continue;
    if (!num::PolyFit(rt, ryv,
                        static_cast<int>(std::min<size_t>(2, rt.size() - 1)),
                        rc))
      continue;
    double yc = (num::PolyVal(lc, cusp) + num::PolyVal(rc, cusp)) / 2;
    double el = 0, er = 0;
    for (size_t i = 0; i < lt.size(); ++i) {
      double d = num::PolyVal(lc, lt[i]) - ly[i];
      el += d * d;
    }
    for (size_t i = 0; i < rt.size(); ++i) {
      double d = num::PolyVal(rc, rt[i]) - ryv[i];
      er += d * d;
    }
    double resid =
        std::max({std::sqrt(el / lt.size()), std::sqrt(er / rt.size()), rx});
    // Bridge: linear from tail end to cusp to head start.
    double y0 = A.y.back(), y1 = B.y.front();
    double t0 = A.t.back(), t1 = B.t.front();
    Bridge cand;
    cand.ok = true;
    cand.resid = resid;
    cand.gf = gf;
    for (double g : gf) {
      cand.xs.push_back(num::PolyVal(cx, g));
      if (g <= cusp)
        cand.ys.push_back(y0 + (yc - y0) * (g - t0) /
                                   std::max(1e-6, cusp - t0));
      else
        cand.ys.push_back(yc + (y1 - yc) * (g - cusp) /
                                   std::max(1e-6, t1 - cusp));
    }
    if (!best.ok || cand.resid < best.resid) best = std::move(cand);
  }
  return best;
}

// Free-kink (hidden hit) bridge.
Bridge KinkPair(const std::vector<TrackPoint>& a_tail,
                const std::vector<TrackPoint>& b_head, int gap0, int gap1) {
  Bridge br;
  Window A = Denoise(a_tail), B = Denoise(b_head);
  if (A.t.size() < 3 || B.t.size() < 3) return br;
  std::vector<double> alx, aly, blx, bly;
  if (!num::PolyFit(A.t, A.x, 1, alx) || !num::PolyFit(A.t, A.y, 1, aly) ||
      !num::PolyFit(B.t, B.x, 1, blx) || !num::PolyFit(B.t, B.y, 1, bly))
    return br;
  auto rms = [](const std::vector<double>& t, const std::vector<double>& v,
                const std::vector<double>& c) {
    double s = 0;
    for (size_t i = 0; i < t.size(); ++i) {
      double d = num::PolyVal(c, t[i]) - v[i];
      s += d * d;
    }
    return std::sqrt(s / t.size());
  };
  double ra = std::max(rms(A.t, A.x, alx), rms(A.t, A.y, aly));
  double rb = std::max(rms(B.t, B.x, blx), rms(B.t, B.y, bly));
  if (std::max(ra, rb) > 3.0) return br;
  double dx = alx[0] - blx[0], dy = aly[0] - bly[0];
  std::vector<double> tv;
  if (std::fabs(dx) > 1e-6) tv.push_back((blx[1] - alx[1]) / dx);
  if (std::fabs(dy) > 1e-6) tv.push_back((bly[1] - aly[1]) / dy);
  if (tv.empty()) return br;
  double v = 0;
  for (double t : tv) v += t;
  v /= tv.size();
  if (!(gap0 - 3 <= v && v <= gap1 + 3)) return br;
  double vx = num::PolyVal(alx, v), vy = num::PolyVal(aly, v);
  if (std::hypot(vx - A.x.back(), vy - A.y.back()) > 90 ||
      std::hypot(vx - B.x.front(), vy - B.y.front()) > 90)
    return br;
  br.ok = true;
  br.resid = std::max(ra, rb);
  for (int g = gap0; g <= gap1; ++g) {
    br.gf.push_back(g);
    br.xs.push_back(g <= v ? num::PolyVal(alx, g) : num::PolyVal(blx, g));
    br.ys.push_back(g <= v ? num::PolyVal(aly, g) : num::PolyVal(bly, g));
  }
  return br;
}

struct Scored {
  double score;
  std::vector<double> xs, ys, gf;
};

bool BestBridge(const std::vector<TrackPoint>& a_pts,
                const std::vector<TrackPoint>& b_pts, int gap0, int gap1,
                const TrackerConfig& cfg, Scored& out) {
  int gap = gap1 - gap0 + 1;
  if (gap <= 2) {
    // Linear: a quadratic through 1-2 frames overfits beside bounce
    // bottoms (overshoot spikes hide real bounces); linear cannot.
    const auto& A = a_pts.back();
    const auto& B = b_pts.front();
    Scored lin;
    lin.score = 0.0;
    double dt = B.frame - A.frame;
    if (dt < 1e-9) dt = 1e-9;
    for (int g = gap0; g <= gap1; ++g) {
      double w = (g - A.frame) / dt;
      lin.gf.push_back(g);
      lin.xs.push_back(A.x + (B.x - A.x) * w);
      lin.ys.push_back(A.y + (B.y - A.y) * w);
    }
    out = std::move(lin);
    return true;
  }
  std::vector<Scored> opts;
  for (int nw : {8, 5, 4}) {
    std::vector<TrackPoint> a_tail(
        a_pts.end() - std::min<size_t>(nw, a_pts.size()), a_pts.end());
    std::vector<TrackPoint> b_head(
        b_pts.begin(), b_pts.begin() + std::min<size_t>(nw, b_pts.size()));
    Bridge sm = SmoothPair(a_tail, b_head, gap0, gap1);
    Bridge bn = BouncePair(a_tail, b_head, gap0, gap1);
    Bridge kk = KinkPair(a_tail, b_head, gap0, gap1);
    if (sm.ok && sm.resid <= cfg.stitch_resid)
      opts.push_back({sm.resid + gap * 0.05 + (8 - nw) * 0.1, sm.xs, sm.ys, sm.gf});
    if (bn.ok && bn.resid <= cfg.stitch_resid)
      opts.push_back(
          {bn.resid + gap * 0.05 + 0.5 + (8 - nw) * 0.1, bn.xs, bn.ys, bn.gf});
    if (kk.ok && kk.resid <= cfg.stitch_resid)
      opts.push_back(
          {kk.resid + gap * 0.05 + 1.0 + (8 - nw) * 0.1, kk.xs, kk.ys, kk.gf});
  }
  if (opts.empty()) return false;
  // min() keeps the FIRST minimal element — scan strictly.
  size_t bi = 0;
  for (size_t i = 1; i < opts.size(); ++i)
    if (opts[i].score < opts[bi].score) bi = i;
  out = std::move(opts[bi]);
  return true;
}

double Displacement(const Track& t) {
  double x0 = t.points[0].x, x1 = x0, y0 = t.points[0].y, y1 = y0;
  for (const auto& p : t.points) {
    x0 = std::min(x0, p.x);
    x1 = std::max(x1, p.x);
    y0 = std::min(y0, p.y);
    y1 = std::max(y1, p.y);
  }
  return std::hypot(x1 - x0, y1 - y0);
}

}  // namespace

std::vector<Track> FillGaps(std::vector<Track> tracks, const TrackerConfig& cfg) {
  for (auto& t : tracks) {
    std::sort(t.points.begin(), t.points.end(),
              [](const TrackPoint& a, const TrackPoint& b) {
                return a.frame < b.frame;
              });
    std::vector<TrackPoint> out;
    out.push_back(t.points[0]);
    for (size_t k = 0; k + 1 < t.points.size(); ++k) {
      int f0 = t.points[k].frame, f1 = t.points[k + 1].frame;
      int gap = f1 - f0 - 1;
      if (gap >= 1 && gap <= cfg.stitch_gap) {
        size_t lo = k >= 7 ? k - 7 : 0;
        std::vector<TrackPoint> tail(t.points.begin() + lo,
                                     t.points.begin() + k + 1);
        std::vector<TrackPoint> head(
            t.points.begin() + k + 1,
            t.points.begin() + std::min(t.points.size(), k + 9));
        Scored br;
        std::vector<double> xs, ys, gf;
        if (BestBridge(tail, head, f0 + 1, f1 - 1, cfg, br)) {
          xs = br.xs;
          ys = br.ys;
          gf = br.gf;
        } else {
          for (int g = f0 + 1; g < f1; ++g) {
            double u = static_cast<double>(g - f0) / (f1 - f0);
            gf.push_back(g);
            xs.push_back(t.points[k].x + u * (t.points[k + 1].x - t.points[k].x));
            ys.push_back(t.points[k].y + u * (t.points[k + 1].y - t.points[k].y));
          }
        }
        for (size_t i = 0; i < gf.size(); ++i)
          out.push_back({(int)gf[i], xs[i], ys[i], false, 0.5});
      }
      out.push_back(t.points[k + 1]);
    }
    t.points = std::move(out);
  }
  return tracks;
}

std::vector<Track> StitchTracklets(std::vector<Track> tracks,
                                   const TrackerConfig& cfg) {
  std::sort(tracks.begin(), tracks.end(),
            [](const Track& a, const Track& b) { return a.start() < b.start(); });
  struct Cand {
    double score;
    int i, j;
    std::vector<double> gf, xs, ys;
  };
  std::vector<Cand> cands;
  for (size_t i = 0; i < tracks.size(); ++i) {
    for (size_t j = 0; j < tracks.size(); ++j) {
      if (i == j || tracks[j].start() <= tracks[i].end()) continue;
      int gap = tracks[j].start() - tracks[i].end() - 1;
      if (gap < 1 || gap > cfg.stitch_gap) continue;
      Scored br;
      if (!BestBridge(tracks[i].points, tracks[j].points, tracks[i].end() + 1,
                       tracks[j].start() - 1, cfg, br))
        continue;
      const TrackPoint& ae = tracks[i].points.back();
      const TrackPoint& bs = tracks[j].points.front();
      if (std::fabs(br.xs.front() - ae.x) + std::fabs(br.ys.front() - ae.y) > 60)
        continue;
      if (std::fabs(br.xs.back() - bs.x) + std::fabs(br.ys.back() - bs.y) > 60)
        continue;
      cands.push_back({br.score, (int)i, (int)j, br.gf, br.xs, br.ys});
    }
  }
  // Python sorts by score only (stable: ties keep i,j loop order).
  std::stable_sort(cands.begin(), cands.end(),
                   [](const Cand& a, const Cand& b) { return a.score < b.score; });
  std::map<int, size_t> used_as_next;  // i -> cands index
  std::set<int> used_as_prev;
  for (size_t c = 0; c < cands.size(); ++c) {
    int i = cands[c].i, j = cands[c].j;
    if (used_as_prev.count(j) || used_as_next.count(i)) continue;
    used_as_next[i] = c;
    used_as_prev.insert(j);
  }
  std::set<int> has_prev;
  for (const auto& [i, c] : used_as_next) has_prev.insert(cands[c].j);
  std::vector<int> heads;
  for (size_t k = 0; k < tracks.size(); ++k)
    if (!has_prev.count((int)k)) heads.push_back((int)k);
  std::vector<Track> out;
  int nid = 1;
  for (int h : heads) {
    std::vector<TrackPoint> pts = tracks[h].points;
    std::vector<int> jh = tracks[h].junction_hits;
    int k = h;
    while (used_as_next.count(k)) {
      const Cand& c = cands[used_as_next[k]];
      for (size_t q = 0; q < c.gf.size(); ++q)
        pts.push_back({(int)c.gf[q], c.xs[q], c.ys[q], false, 0.5});
      pts.insert(pts.end(), tracks[c.j].points.begin(), tracks[c.j].points.end());
      jh.insert(jh.end(), tracks[c.j].junction_hits.begin(),
                tracks[c.j].junction_hits.end());
      k = c.j;
    }
    std::sort(pts.begin(), pts.end(), [](const TrackPoint& a, const TrackPoint& b) {
      return a.frame < b.frame;
    });
    Track nt;
    nt.id = nid++;
    nt.points = std::move(pts);
    nt.junction_hits = std::move(jh);
    out.push_back(std::move(nt));
  }
  // Cycle safety: tracks neither emitted as heads nor consumed... mirror
  // the Python orphan check (k in has_prev but never anyone's target —
  // unreachable by construction, kept for fidelity).
  for (size_t k = 0; k < tracks.size(); ++k) {
    if (!has_prev.count((int)k) && !used_as_next.count((int)k)) continue;
    if (has_prev.count((int)k)) {
      bool is_target = false;
      for (const auto& [i, c] : used_as_next)
        if (cands[c].j == (int)k) {
          is_target = true;
          break;
        }
      if (!is_target) {
        Track nt;
        nt.id = nid++;
        nt.points = tracks[k].points;
        nt.junction_hits = tracks[k].junction_hits;
        out.push_back(std::move(nt));
      }
    }
  }
  std::vector<Track> real;
  for (auto& t : out) {
    if (static_cast<int>(t.points.size()) >= cfg.min_length &&
        (Displacement(t) >= cfg.min_disp || (int)t.points.size() >= 30))
      real.push_back(std::move(t));
  }
  std::sort(real.begin(), real.end(),
            [](const Track& a, const Track& b) { return a.start() < b.start(); });
  for (size_t n = 0; n < real.size(); ++n) real[n].id = (int)n + 1;
  return real;
}

std::vector<Track> MergeOverlapHandovers(std::vector<Track> tracks, int width) {
  double s = width / 1280.0;
  std::stable_sort(tracks.begin(), tracks.end(), [](const Track& a, const Track& b) {
    if (a.start() != b.start()) return a.start() < b.start();
    return a.end() < b.end();
  });
  std::vector<Track> out;
  for (auto& b : tracks) {
    bool merged = false;
    for (size_t k = 0; k < out.size() && !merged; ++k) {
      Track& a = out[k];
      if (!(a.start() < b.start() && b.start() <= a.end() && a.end() < b.end()))
        continue;
      std::map<int, const TrackPoint*> am, bm;
      for (const auto& p : a.points) am[p.frame] = &p;
      for (const auto& p : b.points) bm[p.frame] = &p;
      std::vector<int> common;
      for (const auto& [f, p] : am)
        if (bm.count(f) && b.start() <= f && f <= a.end()) common.push_back(f);
      if (common.size() < 3) continue;
      std::vector<double> ds;
      for (int f : common)
        ds.push_back(std::hypot(am[f]->x - bm[f]->x, am[f]->y - bm[f]->y));
      size_t nt = std::min<size_t>(5, ds.size());
      std::vector<double> tail(ds.end() - nt, ds.end());
      std::sort(tail.begin(), tail.end());
      double tail_med =
          nt % 2 ? tail[nt / 2] : 0.5 * (tail[nt / 2 - 1] + tail[nt / 2]);
      if (tail_med >= 12.0 * s) continue;  // never meet: different balls
      size_t nh = std::min<size_t>(5, ds.size());
      double head_max = *std::max_element(ds.begin(), ds.begin() + nh);
      std::vector<double> all = ds;
      std::sort(all.begin(), all.end());
      size_t na = all.size();
      double med =
          na % 2 ? all[na / 2] : 0.5 * (all[na / 2 - 1] + all[na / 2]);
      if (head_max < 20.0 * s && med < 25.0 * s) continue;  // dedup's job
      size_t ji = 0;
      for (size_t i = 1; i < ds.size(); ++i)
        if (ds[i] < ds[ji]) ji = i;  // argmin keeps FIRST minimum
      int j = common[ji];
      std::vector<TrackPoint> pts;
      for (const auto& p : a.points)
        if (p.frame < b.start()) pts.push_back(p);
      for (int f = b.start(); f <= a.end(); ++f) {
        auto pa = am.find(f), pb = bm.find(f);
        if (pa == am.end())
          pts.push_back(*pb->second);
        else if (pb == bm.end())
          pts.push_back(*pa->second);
        else
          pts.push_back(pa->second->conf >= pb->second->conf ? *pa->second
                                                             : *pb->second);
      }
      for (const auto& p : b.points)
        if (p.frame > a.end()) pts.push_back(p);
      std::sort(pts.begin(), pts.end(), [](const TrackPoint& p, const TrackPoint& q) {
        return p.frame < q.frame;
      });
      Track m;
      m.id = a.id;
      m.points = std::move(pts);
      m.junction_hits = a.junction_hits;
      m.junction_hits.insert(m.junction_hits.end(), b.junction_hits.begin(),
                             b.junction_hits.end());
      // The handover IS the hit evidence (see Python twin for the
      // argument); both sides must be observed near the junction.
      bool a_seen = false, b_seen = false;
      for (const auto& p : a.points)
        if (p.observed && std::abs(p.frame - j) <= 2) {
          a_seen = true;
          break;
        }
      for (const auto& p : b.points)
        if (p.observed && std::abs(p.frame - j) <= 2) {
          b_seen = true;
          break;
        }
      if (a_seen && b_seen) m.junction_hits.push_back(j);
      out[k] = std::move(m);
      merged = true;
    }
    if (!merged) out.push_back(std::move(b));
  }
  return out;
}

namespace {

bool PointInQuad(double x, double y, const double q[4][2]) {
  bool inside = false;
  for (int i = 0; i < 4; ++i) {
    double x0 = q[i][0], y0 = q[i][1];
    double x1 = q[(i + 1) % 4][0], y1 = q[(i + 1) % 4][1];
    if ((y0 > y) != (y1 > y)) {
      double xin = x0 + (x1 - x0) * (y - y0) / (y1 - y0);
      if (x < xin) inside = !inside;
    }
  }
  return inside;
}

void ApplyHmat(const double h[9], double x, double y, double& wx, double& wy,
               bool& ok) {
  double q0 = h[0] * x + h[1] * y + h[2];
  double q1 = h[3] * x + h[4] * y + h[5];
  double q2 = h[6] * x + h[7] * y + h[8];
  ok = std::fabs(q2) >= 1e-9;
  wx = ok ? q0 / q2 : 0;
  wy = ok ? q1 / q2 : 0;
}

}  // namespace

std::vector<Track> ResolveIntruders(std::vector<Track> tracks, int width,
                                    const CourtGeom* court) {
  double s = width / 1280.0;
  double quad[4][2];
  bool have_quad = false;
  if (court && court->valid) {
    const double ws[4][2] = {{-kHalfDbl, -kHalfLen},
                             {kHalfDbl, -kHalfLen},
                             {kHalfDbl, kHalfLen},
                             {-kHalfDbl, kHalfLen}};
    have_quad = true;
    for (int i = 0; i < 4; ++i) {
      bool ok = false;
      double qx = 0, qy = 0;
      ApplyHmat(court->h_court2img, ws[i][0], ws[i][1], qx, qy, ok);
      if (!ok) {
        have_quad = false;
        break;
      }
      quad[i][0] = qx;
      quad[i][1] = qy;
    }
  }
  auto score = [&](const Track& t) {
    int nob = 0, inq = 0;
    for (const auto& p : t.points)
      if (p.observed) {
        ++nob;
        if (have_quad && PointInQuad(p.x, p.y, quad)) ++inq;
      }
    double frac = nob ? (double)inq / nob : 0.0;
    return 100.0 * t.hits.size() + 200.0 * frac + nob;
  };
  std::set<size_t> stray;
  for (size_t i = 0; i < tracks.size(); ++i) {
    for (size_t j = 0; j < tracks.size(); ++j) {
      if (i >= j || stray.count(i) || stray.count(j)) continue;
      const Track &a = tracks[i], &b = tracks[j];
      int ov0 = std::max(a.start(), b.start());
      int ov1 = std::min(a.end(), b.end());
      if (ov1 - ov0 + 1 < 40) continue;
      std::map<int, const TrackPoint*> am, bm;
      for (const auto& p : a.points) am[p.frame] = &p;
      for (const auto& p : b.points) bm[p.frame] = &p;
      std::vector<double> ds;
      for (int f = ov0; f <= ov1; ++f) {
        auto pa = am.find(f), pb = bm.find(f);
        if (pa != am.end() && pb != bm.end())
          ds.push_back(std::hypot(pa->second->x - pb->second->x,
                                  pa->second->y - pb->second->y));
      }
      if (ds.size() < 20) continue;
      std::sort(ds.begin(), ds.end());
      size_t n = ds.size();
      double med = n % 2 ? ds[n / 2] : 0.5 * (ds[n / 2 - 1] + ds[n / 2]);
      if (med < 40.0 * s) continue;  // same ball that missed merging
      double sa = score(a), sb = score(b);
      if (std::max(sa, sb) < 30) continue;  // both weak: keep both
      if (sa > 1.5 * sb)
        stray.insert(j);
      else if (sb > 1.5 * sa)
        stray.insert(i);
    }
  }
  for (size_t i : stray) tracks[i].stray = true;
  return tracks;
}

}  // namespace tennis
