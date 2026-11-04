// Rally segmentation must not drop validated bounces.
//
// Regression (input/rally-1.mov, current code): the engine finds 8 track
// bounces but the app shows 3. Two segmentation defects drop the other 5:
//
//  1. The liveness gate requires image-X range > 100px. From behind the
//     court the ball travels in depth (small x-range, large y-range),
//     so live depth segments with bounces are rejected.
//  2. A bounce sitting in a dead zone between two cuts belongs to NO
//     live bound (bounds are the complement of cuts), so point-ending
//     OUT bounces in the roll-out are orphaned.
#include <cstdio>
#include <vector>

#include "tennis/rally.hpp"
#include "tennis/types.hpp"

namespace {

int failures = 0;
void Check(bool ok, const char* name) {
  if (!ok) {
    ++failures;
    printf("FAIL %s\n", name);
  }
}

tennis::TrackPoint Pt(int frame, double x, double y) {
  tennis::TrackPoint p;
  p.frame = frame;
  p.x = x;
  p.y = y;
  p.observed = true;
  p.conf = 0.9;
  return p;
}

// img2court homography of input/rally-1.mov (1280x720 calibration).
const double kRally1H[9] = {
    -0.0040041279, 0.0077073680, -1.1895533213,
    0.0014785261, 0.0429620081, -20.2136885977,
    -0.0000156479, -0.0025173394, 1.0000000000,
};

tennis::CourtGeom RealCourt() {
  tennis::CourtGeom g;
  g.valid = true;
  for (int i = 0; i < 9; ++i) g.h_img2court[i] = kRally1H[i];
  return g;
}

// A live depth segment: 5px/frame V in y, ~18px total x-range, one
// validated bounce at the bottom. No dead zones (single bound).
void DepthRallyKept() {
  tennis::Track t;
  t.id = 1;
  for (int i = 0; i < 60; ++i) {
    double x = 500 + 0.3 * i;
    double y = 300 + 5.0 * (i < 30 ? 30 - i : i - 30);
    t.points.push_back(Pt(i, x, y));
  }
  t.bounces = {30};
  auto rs = tennis::SegmentRallies(t, 25.0, 1280, nullptr);
  Check(rs.size() == 1, "depth: one rally");
  if (rs.empty()) return;
  Check(rs[0].bounces.size() == 1 && rs[0].bounces[0].frame == 30,
        "depth: bounce listed");
}

// A bounce at frame 40 inside a static zone [21-61]: the zone splits at
// the event into cuts [21-39] and [41-61], orphaning frame 40 between
// bounds (0-20) and (62-99). It must attach to the previous bound.
void OrphanBounceAttached() {
  tennis::Track t;
  t.id = 1;
  for (int i = 0; i < 20; ++i) t.points.push_back(Pt(i, 100 + 10 * i, 400));
  for (int i = 20; i < 63; ++i) t.points.push_back(Pt(i, 300, 400));
  for (int i = 63; i < 100; ++i)
    t.points.push_back(Pt(i, 310 + 10 * (i - 63), 400));
  t.bounces = {40};
  auto rs = tennis::SegmentRallies(t, 25.0, 1280, nullptr);
  Check(rs.size() == 1, "orphan: one rally");
  if (rs.empty()) return;
  Check(rs[0].start == 0 && rs[0].end == 40, "orphan: attached to previous");
  Check(rs[0].bounces.size() == 1 && rs[0].bounces[0].frame == 40,
        "orphan: bounce listed");
}

}  // namespace

// Cross-track echo (rally-3.mov, 869/891): a touchdown on a contained
// ghost branch 15f after the outer V at 33 m/s implied is the same
// impact echoed — dropped, and the emptied rally re-gated away. A slow
// (5 m/s) contained touchdown is a real event — kept.
void EchoDrop() {
  tennis::CourtGeom court = RealCourt();
  tennis::Track t1;
  t1.id = 1;
  for (int f = 0; f <= 130; ++f) {
    double x = 640.0 + 0.3 * (f - 50);
    double y = f <= 50 ? 500.0 - 2.5 * (50 - f) : 500.0 - 2.5 * (f - 50);
    t1.points.push_back(Pt(f, x, y));
  }
  t1.bounces = {50};
  tennis::Track t2;
  t2.id = 2;
  for (int f = 40; f <= 65; ++f)
    t2.points.push_back(Pt(f, 700.0, 450.0 - 2.0 * (65 - f)));
  for (int f = 66; f <= 110; ++f)
    t2.points.push_back(Pt(f, 700.0 + 1.0 * (f - 65), 450.0));
  t2.bounces = {65};
  tennis::Track t3;
  t3.id = 3;
  for (int f = 40; f <= 66; ++f)
    t3.points.push_back(Pt(f, 650.0, 520.0 - 2.0 * (66 - f)));
  for (int f = 67; f <= 110; ++f)
    t3.points.push_back(Pt(f, 650.0 + 1.0 * (f - 66), 520.0));
  t3.bounces = {66};
  std::vector<tennis::Track> ts = {t1, t2, t3};
  auto rs = tennis::SegmentAllTracks(ts, 60.0, 1280, &court);
  Check(rs.size() == 2, "echo: two rallies");
  if (rs.size() != 2) return;
  Check(rs[0].track_id == 1, "echo: outer first");
  Check(rs[0].bounces.size() == 1 && rs[0].bounces[0].frame == 50,
        "echo: outer V kept");
  Check(rs[1].track_id == 3, "echo: keeper second");
  Check(rs[1].bounces.size() == 1 && rs[1].bounces[0].frame == 66,
        "echo: slow touchdown kept");
}

// Directional line-call uncertainty (rally-3.mov, frames 760/1340): the
// grazing view resolves sideline distance 16x better than baseline
// distance (4.6 vs 74 cm/px), so a single worst-case sigma vetoes
// confident sideline calls. Judge each axis against its own sigma.
void DirectionalCall() {
  tennis::CourtGeom court = RealCourt();
  struct Case {
    double x, y;
    const char* want;
    const char* name;
  };
  const Case cases[] = {
      // 1.79m past the doubles sideline at 4.6cm/px: confident OUT.
      {697.0, 429.5, "OUT", "call: 1340 sideline OUT"},
      // 2.2m inside the baseline at 74cm/px: 2.96 sigma, just inside
      // the 3-sigma uncallable band — honestly too close to call.
      {556.1, 430.5, "?", "call: 760 borderline uncallable"},
      // Existing calls stand.
      {538.0, 485.0, "IN", "call: 498 IN"},
      // 4m past the far baseline — but the depth sigma now folds in
      // the extrapolated far-line error (~1px at 1.2m/px), so 2.2
      // sigma lands honestly uncallable, like 760.
      {567.7, 423.4, "?", "call: 371 far-marginal uncallable"},
      // 5.2m past at 1.3m/px: 2.6 sigma with the far-line error
      // folded in — honestly too close to call at this resolution.
      {574.8, 422.2, "?", "call: 592 far-marginal uncallable"},
  };
  for (const auto& c : cases) {
    std::string call;
    double wx, wy;
    tennis::JudgeBounce(c.x, c.y, &court, call, wx, wy);
    Check(call == c.want, c.name);
  }
}

int main() {
  DepthRallyKept();
  OrphanBounceAttached();
  EchoDrop();
  DirectionalCall();
  if (failures == 0) printf("rally_test: all passed\n");
  return failures ? 1 : 0;
}
