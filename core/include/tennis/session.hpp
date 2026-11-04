// Incremental session: feed candidates in frame order, get tracks +
// rallies re-derived exactly as the batch pipeline would. Port of
// StreamSession (streaming.py).
#pragma once

#include <vector>

#include "tennis/tracker.hpp"
#include "tennis/types.hpp"

namespace tennis {

class Session {
 public:
  Session(double fps, int width, const CourtGeom* court = nullptr,
          const TrackerConfig& cfg = TrackerConfig(),
          bool court_filter = true);

  void Ingest(const FrameCands& new_cands);
  // Retune gap stitching for sparse (stride-3) candidates. Takes effect on
  // the next Ingest, which re-derives over all tracklets. Defaults
  // (gap 30, resid 5.0) are unchanged unless this is called.
  void set_stitch(int gap, double resid);
  // Lower the tracklet confirmation floor (sparse candidates keep
  // shorter but real stubs: serve tosses). Reaches the linker and the
  // stitch filter; finalize never floors on length.
  void set_min_length(int n);
  int coverage() const { return linker_.coverage(); }
  long n_cands() const { return n_cands_; }

  std::vector<Track> tracks;
  std::vector<Rally> rallies;

 private:
  double fps_;
  int width_;
  const CourtGeom* court_;
  TrackerConfig cfg_;
  bool court_filter_;
  IncrementalLinker linker_;
  long n_cands_ = 0;
};

}  // namespace tennis
