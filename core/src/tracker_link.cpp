#include "tennis/tracker.hpp"

#include <algorithm>
#include <cmath>
#include <set>
#include <stdexcept>

#include "tennis/num.hpp"

namespace tennis {

IncrementalLinker::IncrementalLinker(double fps, int width,
                                     const TrackerConfig& cfg)
    : cfg_(cfg),
      gate_base_(cfg.gate_base * width / 1280.0),
      s_(width / 1280.0) {
  (void)fps;
}

void IncrementalLinker::Kill(const Live& tr) {
  if (tr.hits >= cfg_.min_hits &&
      static_cast<int>(tr.pts.size()) >= cfg_.min_length)
    done_.emplace_back(tr.uid, tr.pts);
}

bool IncrementalLinker::Snapshot(const Live& tr, Track& out) const {
  if (tr.hits >= cfg_.min_hits &&
      static_cast<int>(tr.pts.size()) >= cfg_.min_length) {
    out.id = tr.uid;
    out.points.clear();
    for (const auto& p : tr.pts) out.points.push_back({p.f, p.x, p.y, true, p.c});
    return true;
  }
  return false;
}

std::vector<Track> IncrementalLinker::Ingest(const FrameCands& frames_cands) {
  for (const auto& [f, cands_in] : frames_cands) {
    if (f <= coverage_)
      throw std::invalid_argument("frames must be ingested once in order");
    coverage_ = f;
    std::vector<Candidate> cands = cands_in;
    std::stable_sort(cands.begin(), cands.end(),
                     [](const Candidate& a, const Candidate& b) {
                       return a.conf > b.conf;
                     });
    struct Pred {
      double x, y;
    };
    std::vector<Pred> preds;
    // Gap-aware motion (mirrors Python): velocity is per-frame, so
    // predict across the whole gap since this track's last update.
    for (const auto& tr : live_) {
      double g = std::max(1, f - tr.last_f);
      preds.push_back({tr.x + tr.vx * g, tr.y + tr.vy * g});
    }
    struct Triple {
      double score, d;
      int i, j;
    };
    std::vector<Triple> triples;
    for (size_t i = 0; i < live_.size(); ++i) {
      const auto& tr = live_[i];
      double spd = std::hypot(tr.vx, tr.vy);
      double gr = gate_base_ + cfg_.gate_speed * spd;
      // Low-confidence observations (ROI recovery) fill gaps but must
      // agree closely — a loose gate lets one misfire yank the velocity
      // and split the track. High-conf path unchanged.
      double gr_lo =
          std::min(gr, 12.0 * s_ + 1.2 * spd);
      for (size_t j = 0; j < cands.size(); ++j) {
        double d = std::hypot(cands[j].x - preds[i].x, cands[j].y - preds[i].y);
        double gate = cands[j].conf >= 0.75 ? gr : gr_lo;
        if (d <= gate)
          triples.push_back({d - 3.0 * cands[j].conf, d, (int)i, (int)j});
      }
    }
    // Same greedy order as Python's tuple sort: score, then d, i, j.
    std::sort(triples.begin(), triples.end(), [](const Triple& a, const Triple& b) {
      if (a.score != b.score) return a.score < b.score;
      if (a.d != b.d) return a.d < b.d;
      if (a.i != b.i) return a.i < b.i;
      return a.j < b.j;
    });
    std::set<int> used_tr, used_cd;
    for (const auto& t : triples) {
      if (used_tr.count(t.i) || used_cd.count(t.j)) continue;
      used_tr.insert(t.i);
      used_cd.insert(t.j);
      Live& tr = live_[t.i];
      const Candidate& cd = cands[t.j];
      double gap = std::max(1, f - tr.last_f);
      double nvx = (cd.x - tr.x) / gap, nvy = (cd.y - tr.y) / gap;
      double a = cfg_.vel_alpha;
      tr.vx = a * nvx + (1 - a) * tr.vx;
      tr.vy = a * nvy + (1 - a) * tr.vy;
      tr.x = cd.x;
      tr.y = cd.y;
      tr.hits += 1;
      tr.misses = 0;
      tr.conf = cd.conf;
      tr.last_f = f;
      tr.pts.push_back({f, cd.x, cd.y, cd.conf});
    }
    std::vector<Live> still;
    for (size_t i = 0; i < live_.size(); ++i) {
      Live& tr = live_[i];
      if (used_tr.count((int)i)) {
        still.push_back(tr);
        continue;
      }
      double gap = std::max(1, f - tr.last_f);
      tr.misses += (int)gap;  // real frames (dense: gap 1, unchanged)
      tr.x += tr.vx * gap;
      tr.y += tr.vy * gap;
      tr.last_f = f;
      if (tr.misses > cfg_.max_miss)
        Kill(tr);
      else
        still.push_back(tr);
    }
    live_ = still;
    for (size_t j = 0; j < cands.size(); ++j) {
      if (used_cd.count((int)j) || cands[j].conf < cfg_.birth_conf) continue;
      bool clash = false;
      for (const auto& tr : live_)
        if (std::hypot(cands[j].x - tr.x, cands[j].y - tr.y) < gate_base_) {
          clash = true;
          break;
        }
      if (!clash) {
        Live tr;
        tr.x = cands[j].x;
        tr.y = cands[j].y;
        tr.conf = cands[j].conf;
        tr.first = f;
        tr.pts.push_back({f, cands[j].x, cands[j].y, cands[j].conf});
        tr.born_frame = f;
        tr.uid = next_id_++;
        tr.last_f = f;
        live_.push_back(tr);
      }
    }
  }
  return Tracklets();
}

std::vector<Track> IncrementalLinker::Tracklets() const {
  std::vector<Track> out;
  for (const auto& [uid, pts] : done_) {
    if (static_cast<int>(pts.size()) >= cfg_.min_length) {
      Track t;
      t.id = uid;
      for (const auto& p : pts) t.points.push_back({p.f, p.x, p.y, true, p.c});
      out.push_back(std::move(t));
    }
  }
  for (const auto& tr : live_) {
    Track t;
    if (Snapshot(tr, t)) out.push_back(std::move(t));
  }
  std::vector<Track> kept;
  for (auto& t : out) {
    if (t.end() - t.start() + 1 <= cfg_.confirm_window &&
        static_cast<int>(t.points.size()) < cfg_.min_hits)
      continue;
    kept.push_back(std::move(t));
  }
  return kept;
}

std::vector<Track> LinkCandidates(const FrameCands& fc, double fps, int width,
                                  const TrackerConfig& cfg) {
  IncrementalLinker linker(fps, width, cfg);
  linker.Ingest(fc);
  return linker.Tracklets();
}

namespace {

// Linear interpolation over strictly increasing frame samples.
void InterpPts(const std::vector<TrackPoint>& pts, int lo, int hi,
               std::vector<double>& xs, std::vector<double>& ys) {
  xs.clear();
  ys.clear();
  size_t k = 0;
  for (int g = lo; g <= hi; ++g) {
    if (g < pts.front().frame || g > pts.back().frame) continue;
    while (k + 1 < pts.size() && pts[k + 1].frame <= g) ++k;
    if (pts[k].frame == g) {
      xs.push_back(pts[k].x);
      ys.push_back(pts[k].y);
    } else if (k + 1 < pts.size()) {
      double t = static_cast<double>(g - pts[k].frame) /
                 (pts[k + 1].frame - pts[k].frame);
      xs.push_back(pts[k].x + t * (pts[k + 1].x - pts[k].x));
      ys.push_back(pts[k].y + t * (pts[k + 1].y - pts[k].y));
    }
  }
}

}  // namespace

std::vector<Track> DedupTracks(std::vector<Track> tracks, int width) {
  double s = width / 1280.0;
  std::stable_sort(tracks.begin(), tracks.end(),
                   [](const Track& a, const Track& b) {
                     return a.points.size() > b.points.size();
                   });
  std::vector<Track> out;
  std::vector<double> xs, ys;
  for (auto& t : tracks) {
    bool merged = false;
    for (auto& u : out) {
      int ov0 = std::max(t.start(), u.start());
      int ov1 = std::min(t.end(), u.end());
      if (ov1 - ov0 + 1 < 3) continue;
      // Per-frame maps (u's points may be unsorted; scan linearly).
      auto at = [](const std::vector<TrackPoint>& ps, int f) -> const TrackPoint* {
        for (const auto& p : ps)
          if (p.frame == f) return &p;
        return nullptr;
      };
      std::vector<double> dists;
      for (int f = ov0; f <= ov1; ++f) {
        const TrackPoint* a = at(t.points, f);
        const TrackPoint* b = at(u.points, f);
        if (a && b) dists.push_back(std::hypot(a->x - b->x, a->y - b->y));
      }
      double med;
      if (dists.size() >= 3) {
        med = num::Median(dists);
      } else {
        std::vector<double> ax, ay, bx, by;
        // interp needs frame-sorted points; copy+sort (Python's np.interp
        // over unsorted xp is undefined, but inputs here are sorted in
        // practice — sorting only fixes pathological order).
        std::vector<TrackPoint> ts = t.points, us = u.points;
        auto byf = [](const TrackPoint& a, const TrackPoint& b) {
          return a.frame < b.frame;
        };
        std::sort(ts.begin(), ts.end(), byf);
        std::sort(us.begin(), us.end(), byf);
        InterpPts(ts, ov0, ov1, ax, ay);
        InterpPts(us, ov0, ov1, bx, by);
        if (ax.size() < 3 || ax.size() != bx.size()) continue;
        dists.clear();
        for (size_t k = 0; k < ax.size(); ++k)
          dists.push_back(std::hypot(ax[k] - bx[k], ay[k] - by[k]));
        med = num::Median(dists);
      }
      // Long overlaps with sustained separation are distinct objects
      // (a ball tracked in parallel with its ghost/shadow/head — the
      // median stays well above duplicate noise for many frames), not
      // duplicate links: keep both so the ball branch survives instead
      // of being absorbed per-frame into the smoother ghost. Temporal
      // handovers (one track starts inside the other and extends past
      // it) still merge — the merger downstream finishes those.
      bool hand = (t.start() < u.start() && u.start() <= t.end() &&
                   t.end() < u.end()) ||
                  (u.start() < t.start() && t.start() <= u.end() &&
                   u.end() < t.end());
      if (med < 25.0 * s &&
          !(ov1 - ov0 + 1 >= 10 && med >= 8.0 * s && !hand)) {
        for (const auto& p : t.points) {
          TrackPoint* dst = nullptr;
          for (auto& q : u.points)
            if (q.frame == p.frame) {
              dst = &q;
              break;
            }
          if (!dst)
            u.points.push_back(p);
          else if (p.conf > dst->conf) {
            dst->x = p.x;
            dst->y = p.y;
            dst->conf = p.conf;
          }
        }
        std::sort(u.points.begin(), u.points.end(),
                  [](const TrackPoint& a, const TrackPoint& b) {
                    return a.frame < b.frame;
                  });
        merged = true;
        break;
      }
    }
    if (!merged) out.push_back(std::move(t));
  }
  return out;
}

}  // namespace tennis
