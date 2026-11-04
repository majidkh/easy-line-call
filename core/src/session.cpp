#include "tennis/session.hpp"

#include "tennis/rally.hpp"

namespace tennis {

Session::Session(double fps, int width, const CourtGeom* court,
                 const TrackerConfig& cfg, bool court_filter)
    : fps_(fps),
      width_(width),
      court_(court),
      cfg_(cfg),
      court_filter_(court_filter),
      linker_(fps, width, cfg) {}

void Session::set_stitch(int gap, double resid) {
  cfg_.stitch_gap = gap;
  cfg_.stitch_resid = resid;
}

void Session::set_min_length(int n) {
  cfg_.min_length = n;
  linker_.set_min_length(n);
}

void Session::Ingest(const FrameCands& new_cands) {
  if (new_cands.empty()) return;
  for (const auto& [f, cs] : new_cands) n_cands_ += (long)cs.size();
  std::vector<Track> t = DedupTracks(linker_.Ingest(new_cands), width_);
  for (auto& tr : t) DespikeTrack(tr, width_);
  t = StitchTracklets(std::move(t), cfg_);
  t = DedupTracks(std::move(t), width_);
  // NOTE: the Python twin finalizes with a default config here (not the
  // session's) — mirrored exactly.
  t = FinalizeTracks(std::move(t), width_, TrackerConfig(), court_);
  t = ResolveIntruders(std::move(t), width_, court_);
  if (court_filter_ && court_ && court_->valid)
    t = FilterTracksToCourt(std::move(t), court_, width_);
  rallies = SegmentAllTracks(t, fps_, width_, court_);
  tracks = std::move(t);
}

}  // namespace tennis
