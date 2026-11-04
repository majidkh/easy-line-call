// DedupTracks: duplicate links merge, parallel objects survive.
//
// Regression: a ball tracked in parallel with its ghost/shadow (same
// frames, ~13px apart for 16 frames) was absorbed per-frame into the
// smoother ghost, erasing the ball's V (rally-3 frames 1252-1268 went
// silent). Long overlaps with sustained separation are distinct objects.
#include <cstdio>
#include <vector>

#include "tennis/tracker.hpp"

namespace {

int failures = 0;
void Check(bool ok, const char* name) {
  if (!ok) {
    ++failures;
    printf("FAIL %s\n", name);
  }
}

tennis::Track Mk(int id, int f0, int f1, double x0, double y0, double dx,
                 double dy) {
  tennis::Track t;
  t.id = id;
  for (int f = f0; f <= f1; ++f) {
    tennis::TrackPoint p;
    p.frame = f;
    p.x = x0 + dx * (f - f0);
    p.y = y0 + dy * (f - f0);
    p.observed = true;
    p.conf = 0.9;
    t.points.push_back(p);
  }
  return t;
}

}  // namespace

int main() {
  // Duplicate links of one ball (median ~2px over 16 frames) merge.
  {
    std::vector<tennis::Track> ts;
    ts.push_back(Mk(1, 100, 115, 500, 400, 2.0, 1.0));
    ts.push_back(Mk(2, 100, 115, 501, 402, 2.0, 1.0));
    auto out = tennis::DedupTracks(std::move(ts), 1280);
    Check(out.size() == 1, "duplicate links merge");
  }
  // Parallel ball + ghost (median ~13px over 16 frames) both survive.
  {
    std::vector<tennis::Track> ts;
    ts.push_back(Mk(1, 100, 125, 500, 400, 3.0, 1.0));  // ghost (longer)
    ts.push_back(Mk(2, 105, 120, 505, 412, 3.0, 1.5));  // ball
    auto out = tennis::DedupTracks(std::move(ts), 1280);
    Check(out.size() == 2, "parallel objects survive");
  }
  // Short handover-style overlaps still merge (existing behavior).
  {
    std::vector<tennis::Track> ts;
    ts.push_back(Mk(1, 100, 110, 500, 400, 2.0, 1.0));
    ts.push_back(Mk(2, 106, 116, 512, 406, 2.0, 1.0));
    auto out = tennis::DedupTracks(std::move(ts), 1280);
    Check(out.size() == 1, "short overlaps merge");
  }
  // Temporal handovers merge even with sustained separation (one starts
  // inside the other and extends past it — the merger finishes those).
  {
    std::vector<tennis::Track> ts;
    ts.push_back(Mk(1, 100, 124, 500, 400, 2.0, 1.0));
    ts.push_back(Mk(2, 113, 140, 520, 420, 2.0, 1.0));
    auto out = tennis::DedupTracks(std::move(ts), 1280);
    Check(out.size() == 1, "temporal handovers merge");
  }
  if (failures == 0) printf("link tests pass\n");
  return failures ? 1 : 0;
}
