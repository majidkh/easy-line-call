// Bounce-event recall: a V bottom that is observed while its shoulders
// fall in an observation gap must still be detected.
//
// Regression (input/rally-1.mov, frame ~1127): the detector sees the ball
// at the bounce bottom but misses 2 frames before and 5 after (impact
// blur/occlusion). The observed-bottom path needs observed neighbors
// within 3 frames each side (the far shoulder is 6 away), and the hidden-
// cusp path measures amplitude against the gap-adjacent points (which sit
// at the bottom, collapsing it). The bounce fell through both paths.
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

tennis::TrackPoint Pt(int frame, double x, double y, bool observed) {
  tennis::TrackPoint p;
  p.frame = frame;
  p.x = x;
  p.y = y;
  p.observed = observed;
  p.conf = observed ? 0.9 : 0.5;
  return p;
}

// img2court homography of input/rally-1.mov (1280x720 calibration).
const double kRally1H[9] = {
    -0.0040041279, 0.0077073680, -1.1895533213,
    0.0014785261, 0.0429620081, -20.2136885977,
    -0.0000156479, -0.0025173394, 1.0000000000,
};

void Mat3Mul(const double a[9], const double b[9], double o[9]) {
  for (int r = 0; r < 3; ++r)
    for (int c = 0; c < 3; ++c)
      o[3 * r + c] = a[3 * r] * b[c] + a[3 * r + 1] * b[3 + c] +
                     a[3 * r + 2] * b[6 + c];
}

// A far/grazing camera looking at the same world point: image scale c
// about the bottom b, i.e. H' = H * S^-1 with S(p) = c*(p-b)+b.
tennis::CourtGeom ScaledCourt(double c, double bx, double by) {
  double inv[9] = {1 / c, 0, bx * (1 - 1 / c), 0, 1 / c,
                   by * (1 - 1 / c), 0, 0, 1};
  tennis::CourtGeom g;
  g.valid = true;
  Mat3Mul(kRally1H, inv, g.h_img2court);
  return g;
}

tennis::CourtGeom RealCourt() {
  tennis::CourtGeom g;
  g.valid = true;
  for (int i = 0; i < 9; ++i) g.h_img2court[i] = kRally1H[i];
  return g;
}

// Tight synthetic V: 1.3px amplitude (below the 2.5px floor), 0.75/0.65
// leg slopes, static x, all observed. Passes every gate except pixels.
// Flanked by far observed points (outside the fit windows) to clear the
// 7-observation minimum without touching the amplitude.
tennis::Track TightV(double bx, double by, int f0) {
  tennis::Track t;
  t.id = 9;
  t.points.push_back(Pt(f0 - 9, bx, by - 0.75 * 9, true));
  t.points.push_back(Pt(f0 - 8, bx, by - 0.75 * 8, true));
  const double dys[5] = {-1.5, -0.75, 0.0, -0.65, -1.3};
  for (int i = 0; i < 5; ++i)
    t.points.push_back(Pt(f0 - 2 + i, bx, by + dys[i], true));
  t.points.push_back(Pt(f0 + 8, bx, by - 0.65 * 8, true));
  t.points.push_back(Pt(f0 + 9, bx, by - 0.65 * 9, true));
  return t;
}

}  // namespace

int main() {
  // Exact track points around the rally-1.mov bounce (bottom observed at
  // 1126, shoulders interpolated 1124-1125 and 1127-1131).
  const double raw[][4] = {
      // frame, x, y, observed
      {1115, 537.8, 401.6, 1}, {1116, 536.6, 404.0, 1},
      {1117, 535.3, 406.5, 1}, {1118, 534.0, 409.0, 1},
      {1119, 532.8, 411.5, 1}, {1120, 531.5, 413.6, 1},
      {1121, 530.2, 416.4, 1}, {1122, 529.5, 418.3, 1},
      {1123, 528.8, 419.0, 1}, {1124, 527.3, 422.9, 0},
      {1125, 526.2, 425.5, 0}, {1126, 524.7, 428.6, 1},
      {1127, 524.1, 428.8, 0}, {1128, 523.4, 428.5, 0},
      {1129, 522.6, 427.2, 0}, {1130, 521.8, 425.4, 0},
      {1131, 521.1, 424.2, 0}, {1132, 520.2, 422.7, 1},
      {1133, 520.1, 422.4, 0}, {1134, 519.9, 422.1, 1},
      {1135, 519.4, 419.9, 0}, {1136, 519.1, 417.8, 1},
      {1137, 518.7, 416.2, 1}, {1138, 518.1, 414.2, 0},
      {1139, 517.6, 412.5, 1}, {1140, 517.3, 411.2, 1},
      {1141, 516.6, 409.6, 1}, {1142, 516.3, 408.3, 1},
      {1143, 515.7, 407.3, 1}, {1144, 515.6, 406.3, 1},
      {1145, 515.0, 405.5, 1}, {1146, 514.6, 404.0, 1},
      {1147, 514.3, 403.2, 1}, {1148, 513.8, 402.2, 1},
      {1149, 514.5, 400.2, 1}, {1150, 512.7, 400.8, 1},
  };
  tennis::Track v;
  v.id = 1;
  for (const auto& r : raw)
    v.points.push_back(
        Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> bounces = tennis::DetectBounces(v, 1280, nullptr);
  printf("gapped-V bounces:");
  for (int b : bounces) printf(" %d", b);
  printf("\n");
  Check(bounces.size() == 1, "gapped V finds one bounce");
  Check(!bounces.empty() && 1124 <= bounces[0] && bounces[0] <= 1132,
        "gapped-V bounce at the bottom");

  // Negative: a smooth descent with an identical gap pattern but no V
  // (monotone y) must not fire.
  tennis::Track line;
  line.id = 2;
  for (int i = 0; i < 36; ++i) {
    int f = 1115 + i;
    bool obs = !(1124 <= f && f <= 1125) && !(1127 <= f && f <= 1131);
    if (f == 1126) obs = true;
    line.points.push_back(
        Pt(f, 538.0 - 0.7 * i, 401.0 + 0.8 * i, obs));
  }
  std::vector<int> none = tennis::DetectBounces(line, 1280, nullptr);
  Check(none.empty(), "smooth descent stays silent");

  // Negative: a clean symmetric V that GAINS speed through the bottom is a
  // foot/shuffle artifact, never a bounce (impacts absorb energy). Exact
  // rally-1.mov track-5 points around frame 1023; world speed rises
  // 9.3 -> 10.1 m/s through the V, so it must stay silent.
  const double kick[][4] = {
      {1018, 741.0, 506.0, 1}, {1019, 741.0, 510.0, 1},
      {1020, 742.0, 511.0, 1}, {1021, 745.0, 516.0, 1},
      {1022, 743.0, 516.0, 0}, {1023, 742.0, 517.0, 1},
      {1024, 743.0, 516.0, 1}, {1025, 744.0, 513.0, 0},
      {1026, 746.0, 511.0, 0}, {1027, 748.0, 508.0, 1},
      {1028, 749.0, 506.0, 1}, {1029, 750.0, 504.0, 0},
      {1030, 752.0, 502.0, 0}, {1031, 753.0, 501.0, 0},
      {1032, 754.0, 499.0, 0}, {1033, 755.0, 497.0, 0},
  };
  tennis::Track shuf;
  shuf.id = 5;
  for (const auto& r : kick)
    shuf.points.push_back(
        Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> nofire = tennis::DetectBounces(shuf, 1280, nullptr);
  Check(nofire.empty(), "speed-gain V stays silent");

  // Negative: a V bottom with reversing x and sparse shoulders is a hit
  // (racket contact), not a bounce. Exact rally-1.mov points around the
  // frame-656 volley kink, 6 frames after the detected hit at 650.
  const double vol[][4] = {
      {648, 588.1, 413.3, 1}, {649, 588.8, 412.5, 1},
      {650, 590.9, 412.2, 1}, {651, 589.8, 414.1, 1},
      {652, 579.5, 423.3, 0}, {653, 575.2, 427.5, 0},
      {654, 572.5, 429.5, 1}, {655, 569.9, 432.9, 0},
      {656, 571.8, 433.1, 1}, {657, 574.5, 431.8, 0},
      {658, 574.1, 431.3, 1}, {659, 582.6, 428.0, 0},
      {660, 590.2, 425.0, 0}, {661, 595.4, 422.2, 0},
      {662, 597.2, 419.4, 0}, {663, 596.9, 415.7, 0},
      {664, 596.8, 412.0, 0}, {665, 597.6, 408.1, 0},
      {666, 596.7, 406.1, 0},
  };
  tennis::Track bok;
  bok.id = 6;
  for (const auto& r : vol)
    bok.points.push_back(
        Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> nohit = tennis::DetectBounces(bok, 1280, nullptr);
  Check(nohit.empty(), "volley kink stays silent");

  // Camera-aware amplitude: the same tight V under three calibrations.
  // Mid-court bottom (1008's neighborhood): 1.3px = 0.24 physical meters.
  tennis::Track mid = TightV(687.0, 467.0, 100);
  tennis::CourtGeom real = RealCourt();
  std::vector<int> mid_px = tennis::DetectBounces(mid, 1280, &real);
  Check(mid_px.size() == 1 && mid_px[0] == 100, "physical V counts");
  std::vector<int> mid_nc = tennis::DetectBounces(mid, 1280, nullptr);
  Check(mid_nc.empty(), "no court, no relief");
  // Far-view simulation (0.08x about the bottom): the V spans meters.
  tennis::CourtGeom far = ScaledCourt(0.08, 687.0, 467.0);
  std::vector<int> mid_far = tennis::DetectBounces(mid, 1280, &far);
  Check(mid_far.size() == 1 && mid_far[0] == 100, "far V rescued");
  // Near-baseline bottom: 1.3px = 2cm of sub-ball-scale noise.
  tennis::Track near = TightV(600.0, 640.0, 100);
  std::vector<int> near_px = tennis::DetectBounces(near, 1280, &real);
  Check(near_px.empty(), "near micro-V stays silent");

  // Descent-anchored rescue (rally-3.mov, frame 1258): a steep occluded
  // descent (18px/frame through a leg occlusion) lands on the baseline
  // and hops. The classic ±6 fit windows see only flat roll-onset, so
  // the slope significance and elastic gates reject the clean 11px V.
  // The rescue anchors on the visible descent and accepts it.
  const double land[][4] = {
      {1246, 858.0, 436.2, 1}, {1247, 872.6, 444.0, 1},
      {1248, 894.8, 456.8, 0}, {1249, 911.2, 468.3, 1},
      {1250, 925.4, 481.8, 0}, {1251, 939.0, 489.9, 1},
      {1252, 949.9, 521.9, 1}, {1253, 952.7, 526.8, 1},
      {1254, 954.7, 528.9, 1}, {1255, 956.4, 528.5, 1},
      {1256, 954.0, 530.4, 1}, {1257, 957.5, 525.8, 1},
      {1258, 958.7, 533.3, 1}, {1259, 964.0, 529.8, 1},
      {1260, 967.7, 520.9, 1}, {1261, 977.1, 518.5, 0},
      {1262, 989.9, 516.4, 1}, {1263, 1005.1, 516.4, 1},
      {1264, 1023.1, 524.7, 0}, {1265, 1040.5, 533.2, 0},
      {1266, 1064.9, 546.1, 1},
  };
  tennis::Track rv;
  rv.id = 11;
  for (const auto& r : land)
    rv.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> rescued = tennis::DetectBounces(rv, 1280, &real);
  Check(rescued.size() == 1 && rescued[0] == 1258, "occluded V rescued");

  // Touchdown into roll (rally-3.mov, frame ~1266): the hop apex falls
  // 30px in 3 frames, touches down, rolls to a stop. No rebound leg
  // exists, so only the fall-then-slow touchdown rule can catch it.
  const double roll[][4] = {
      {1260, 967.7, 520.9, 1}, {1261, 977.1, 518.5, 0},
      {1262, 989.9, 516.4, 1}, {1263, 1005.1, 516.4, 1},
      {1264, 1023.1, 524.7, 0}, {1265, 1040.5, 533.2, 0},
      {1266, 1064.9, 546.1, 1}, {1267, 1080.4, 559.5, 0},
      {1268, 1075.5, 564.5, 1}, {1269, 1080.9, 564.4, 1},
      {1270, 1086.5, 564.6, 1}, {1271, 1091.7, 564.7, 1},
      {1272, 1092.1, 562.8, 0}, {1273, 1092.9, 562.8, 0},
      {1274, 1092.5, 561.3, 1}, {1275, 1090.6, 563.8, 0},
      {1276, 1087.5, 564.7, 0},
  };
  tennis::Track td;
  td.id = 12;
  for (const auto& r : roll)
    td.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> rolled = tennis::DetectBounces(td, 1280, &real);
  Check(rolled.size() == 1 && 1266 <= rolled[0] && rolled[0] <= 1268,
        "touchdown into roll caught");

  // Touchdown into stop (rally-3.mov, frame 866): a dead ball falls
  // 70px behind the player's legs, lands at his shoe and stays. The
  // track ends on the static shoe, so no V exists to find.
  const double dead[][4] = {
      {855, 656.6, 465.6, 1}, {856, 660.7, 472.2, 1},
      {857, 664.1, 478.6, 1}, {858, 668.5, 484.7, 1},
      {859, 670.8, 493.3, 0}, {860, 673.4, 500.6, 0},
      {861, 675.4, 506.6, 0}, {862, 676.9, 512.0, 0},
      {863, 678.3, 517.5, 0}, {864, 679.1, 521.1, 1},
      {865, 680.0, 529.9, 0}, {866, 680.7, 538.1, 1},
      {867, 681.1, 541.7, 0}, {868, 680.7, 545.1, 0},
      {869, 680.6, 547.1, 1}, {870, 677.8, 545.5, 0},
      {871, 675.6, 543.2, 1}, {872, 674.9, 543.8, 1},
      {873, 675.6, 543.5, 0}, {874, 676.8, 540.9, 1},
      {875, 674.6, 545.0, 1},
  };
  tennis::Track dd;
  dd.id = 13;
  for (const auto& r : dead)
    dd.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> landed = tennis::DetectBounces(dd, 1280, &real);
  Check(landed.size() == 1 && 866 <= landed[0] && landed[0] <= 868,
        "dead landing caught");

  // Hop pair (rally-3.mov, 1258 + 1266): two touchdowns 8 frames apart
  // with a genuine 17px hop between them are distinct events; the
  // dedup must not merge across the hop.
  tennis::Track pair;
  pair.id = 14;
  for (const auto& r : land)
    pair.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  for (const auto& r : roll) {
    if (r[0] <= 1266) continue;  // land[] already covers through 1266
    pair.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  }
  std::vector<int> both = tennis::DetectBounces(pair, 1280, &real);
  Check(both.size() == 2 && both[0] == 1258 && 1266 <= both[1] &&
            both[1] <= 1268,
        "hop pair both kept");

  // Occluded drop (rally-3.mov, frame ~1256): a steep fall vanishes
  // behind the player's legs — the tracker stalls on a ground speck,
  // then a void — and slow roll takes reappear along the flight path.
  // No rise is ever observed, so only the occluded-drop inference can
  // fire, at the entry line's ground crossing.
  const double occdrop[][4] = {
      {1245, 848.5, 431.0, 1}, {1246, 858.0, 436.2, 1},
      {1247, 872.6, 444.0, 1}, {1248, 894.8, 456.8, 0},
      {1249, 911.2, 468.3, 1}, {1250, 925.4, 481.8, 0},
      {1251, 939.0, 489.9, 1}, {1252, 949.9, 521.2, 1},
      {1253, 953.0, 525.6, 1}, {1254, 955.0, 528.5, 1},
      {1255, 956.5, 529.4, 1}, {1256, 953.0, 530.6, 1},
      {1257, 958.5, 525.2, 1}, {1258, 968.6, 526.0, 0},
      {1259, 977.7, 524.9, 0}, {1260, 987.6, 524.7, 0},
      {1261, 998.1, 524.7, 0}, {1262, 1008.8, 525.3, 0},
      {1263, 1022.1, 527.6, 0}, {1264, 1036.8, 532.9, 0},
      {1265, 1050.6, 541.2, 0}, {1266, 1065.6, 547.3, 1},
      {1267, 1070.8, 555.4, 0}, {1268, 1076.2, 563.0, 1},
      {1269, 1081.3, 564.4, 1}, {1270, 1086.5, 565.3, 1},
      {1271, 1091.8, 565.4, 1},
  };
  tennis::Track od;
  od.id = 20;
  for (const auto& r : occdrop)
    od.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> dropped = tennis::DetectBounces(od, 1280, &real);
  Check(dropped.size() == 1 && 1255 <= dropped[0] && dropped[0] <= 1257,
        "occluded drop inferred");

  // Observed V past a bridge spike (rally-3.mov, frame 873): the ball
  // falls hidden behind the player (the linker fills the 13-frame void
  // with a wild 100px spike), lands emerging at 873 and hops into the
  // 881 pickup. The V bottom and rise are observed, so the V path owns
  // it: exactly one fire. The bridge spike must not read as run-up
  // bobbles, and the occluded-drop rule must not double-fire early off
  // the V bottom sitting inside its exit leg.
  const double bfall[][4] = {
      {850, 638.7, 437.8, 1}, {851, 642.1, 442.7, 1},
      {852, 646.4, 449.0, 1}, {853, 649.0, 453.3, 1},
      {854, 652.9, 459.5, 1}, {855, 657.0, 468.3, 1},
      {856, 660.5, 474.7, 1}, {857, 664.2, 476.1, 1},
      {858, 668.5, 474.9, 1}, {859, 670.8, 423.2, 0},
      {860, 673.5, 398.1, 0}, {861, 675.9, 380.2, 0},
      {862, 677.9, 375.2, 0}, {863, 680.0, 389.2, 0},
      {864, 681.8, 407.6, 0}, {865, 683.2, 419.2, 0},
      {866, 684.4, 430.9, 0}, {867, 685.3, 442.6, 0},
      {868, 685.9, 454.3, 0}, {869, 686.4, 466.4, 0},
      {870, 686.5, 479.1, 0}, {871, 686.5, 490.5, 0},
      {872, 686.5, 500.4, 1}, {873, 685.1, 505.8, 1},
      {874, 684.8, 504.1, 1}, {875, 682.7, 500.1, 0},
      {876, 680.6, 493.7, 1}, {877, 679.6, 492.4, 0},
      {878, 678.0, 488.3, 1}, {879, 676.9, 486.0, 1},
      {880, 675.0, 480.9, 1}, {881, 676.0, 487.5, 1},
      {882, 679.5, 498.5, 1}, {883, 690.2, 498.4, 1},
      {884, 691.2, 497.8, 0}, {885, 692.2, 497.1, 1},
      {886, 693.7, 496.3, 1},
  };
  tennis::Track bf;
  bf.id = 21;
  for (const auto& r : bfall)
    bf.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> nobf = tennis::DetectBounces(bf, 1280, &real);
  Check(nobf.size() == 1 && nobf[0] == 873, "one fire past the spike");

  // Negative: a lob apex (rise, stall, fall, still falling at track
  // end) never touches down, so the touchdown rule must stay silent.
  tennis::Track apex;
  apex.id = 15;
  for (int i = 0; i <= 50; ++i) {
    int f = 30 + i;
    double y = 400.0 + 0.2 * (f - 50) * (f - 50);
    apex.points.push_back(Pt(f, 700.0 + 2.0 * i, y, true));
  }
  std::vector<int> noapex = tennis::DetectBounces(apex, 1280, &real);
  Check(noapex.empty(), "apex stays silent");

  // Negative: a steep fall that JUMPS 40px sideways onto a static shoe
  // is a tracker handover, not a touchdown (continuity gate).
  tennis::Track sw;
  sw.id = 16;
  for (int i = 0; i < 10; ++i)
    sw.points.push_back(Pt(i, 600.0, 400.0 + 6.0 * i, true));
  for (int i = 10; i < 18; ++i)
    sw.points.push_back(Pt(i, 640.0, 460.0, true));
  std::vector<int> nosw = tennis::DetectBounces(sw, 1280, &real);
  Check(nosw.empty(), "handover jump stays silent");

  // Negative: head-lock drift through a volley exchange (rally-3.mov
  // frames 630-660): slow drift plus static holds, never a steep
  // fall, so neither the V path nor the rescue may fire.
  const double drift[][4] = {
      {630, 548.6, 405.6, 1}, {631, 559.1, 403.1, 0},
      {632, 573.4, 400.6, 0}, {633, 580.9, 399.4, 0},
      {634, 587.3, 397.1, 1}, {635, 580.3, 404.7, 0},
      {636, 576.8, 408.7, 0}, {637, 569.0, 416.5, 1},
      {638, 568.0, 417.5, 1}, {639, 566.7, 419.0, 0},
      {640, 568.2, 419.2, 0}, {641, 570.8, 419.6, 0},
      {642, 574.6, 420.4, 0}, {643, 578.5, 420.1, 0},
      {644, 582.1, 418.9, 0}, {645, 585.0, 417.2, 0},
      {646, 585.5, 414.6, 1}, {647, 586.9, 414.0, 1},
      {648, 588.1, 413.3, 1}, {649, 588.8, 412.5, 1},
      {650, 590.9, 412.2, 1}, {651, 589.8, 414.1, 1},
      {652, 579.5, 423.3, 0}, {653, 575.2, 427.5, 0},
      {654, 572.5, 429.5, 1}, {655, 569.9, 432.9, 0},
      {656, 571.8, 433.1, 1}, {657, 574.5, 431.8, 0},
      {658, 574.1, 431.3, 1}, {659, 582.6, 428.0, 0},
      {660, 590.2, 425.0, 0},
  };
  tennis::Track hd;
  hd.id = 17;
  for (const auto& r : drift)
    hd.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> nodrift = tennis::DetectBounces(hd, 1280, &real);
  Check(nodrift.empty(), "head-lock drift stays silent");

  // Scoop through an occlusion gap (rally-3.mov, frame 701): the ball
  // descends into an 8-frame void (691-697, hidden), lands emerging at
  // 701 and is scooped at 703-704. The void-fill interpolation rises,
  // but interpolation is not body motion: judged on sightings, the
  // run-up is monotone and the V fires. (Head-lock body motion stays
  // covered by the drift test above.)
  const double bob[][4] = {
      {684, 621.4, 425.9, 1}, {685, 623.6, 424.6, 1},
      {686, 625.1, 425.1, 1}, {687, 625.8, 425.9, 1},
      {688, 623.3, 432.1, 1}, {689, 622.5, 436.0, 1},
      {690, 623.9, 431.8, 1}, {691, 625.0, 428.0, 0},
      {692, 627.2, 421.9, 0}, {693, 629.6, 414.1, 0},
      {694, 631.5, 408.1, 0}, {695, 632.6, 404.9, 0},
      {696, 632.9, 404.9, 0}, {697, 632.5, 408.4, 0},
      {698, 630.7, 416.9, 1}, {699, 630.9, 425.0, 0},
      {700, 630.2, 432.0, 1}, {701, 630.3, 438.1, 1},
      {702, 630.7, 437.2, 0}, {703, 630.4, 436.9, 0},
      {704, 631.8, 437.0, 1}, {705, 632.5, 431.5, 1},
      {706, 638.8, 433.6, 1}, {707, 646.7, 431.5, 1},
      {708, 643.0, 428.1, 1}, {709, 639.0, 422.1, 1},
      {710, 634.6, 418.2, 1}, {711, 630.3, 413.6, 1},
      {712, 625.2, 408.9, 1},
  };
  tennis::Track hb;
  hb.id = 18;
  for (const auto& r : bob)
    hb.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> nobob = tennis::DetectBounces(hb, 1280, &real);
  Check(nobob.size() == 1 && nobob[0] == 701, "scoop fires at 701");

  // Half-volley x-reversal override (rally-3.mov, frame 702): the ball
  // lands moving right and the scoop sends it back left — a genuine
  // x-reversal across an observed bottom. Long observed legs both
  // sides prove a bounced ball, not a mid-air hit (a hit's legs are a
  // 1-3 frame impulse), so the reversal veto stands down.
  const double halfvol[][4] = {
      {694, 660.5, 442.1, 1}, {695, 662.6, 443.7, 1},
      {696, 665.9, 447.0, 1}, {697, 666.1, 447.1, 1},
      {698, 668.3, 449.2, 1}, {699, 671.0, 452.9, 1},
      {700, 673.4, 456.2, 1}, {701, 675.7, 459.5, 1},
      {702, 676.8, 462.6, 1}, {703, 674.5, 460.1, 1},
      {704, 669.8, 456.9, 0}, {705, 663.7, 452.3, 1},
      {706, 659.4, 444.6, 1}, {707, 654.0, 438.1, 1},
      {708, 648.1, 431.2, 1}, {709, 639.0, 422.0, 1},
      {710, 634.2, 417.9, 1},
  };
  tennis::Track hv2;
  hv2.id = 22;
  for (const auto& r : halfvol)
    hv2.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> halfvolleyed = tennis::DetectBounces(hv2, 1280, &real);
  Check(halfvolleyed.size() == 1 && halfvolleyed[0] == 702,
        "half-volley reversal overridden");

  // FP window (rally-3.mov, frames 640-748): the 701/702 scoop with
  // neighboring wobble. Exactly one fire at the scoop; 654/677/721
  // are apexes and ghost-stall artifacts, never bounces.
  // FP window (rally-3.mov, frames 640-740, pre-smoothing takes): the
  // 701/702 scoop with neighboring wobble. Exactly one fire at the
  // scoop; 654/721 are handover apex artifacts and 677 a touchdown
  // on a bridge fall, never bounces.
  const double win64[][4] = {
      {640, 591.89, 399.06, 0},       {641, 591.88, 400.08, 0},
      {642, 591.81, 401.21, 0},       {643, 591.68, 402.47, 0},
      {644, 596.48, 400.53, 1},       {645, 593.11, 404.93, 0},
      {646, 589.75, 409.33, 0},       {647, 586.39, 413.72, 1},
      {648, 587.76, 413.26, 0},       {649, 589.13, 412.80, 1},
      {650, 590.35, 412.57, 1},       {651, 591.78, 412.52, 1},
      {652, 592.80, 412.28, 0},       {653, 593.82, 412.04, 0},
      {654, 594.84, 411.80, 1},       {655, 596.22, 411.22, 0},
      {656, 611.15, 421.58, 0},       {657, 616.25, 424.64, 1},
      {658, 617.23, 425.04, 1},       {659, 612.03, 418.50, 1},
      {660, 606.83, 411.95, 0},       {661, 604.32, 408.73, 0},
      {662, 601.81, 405.51, 1},       {663, 601.58, 408.37, 1},
      {664, 603.31, 404.67, 1},       {665, 601.68, 405.34, 1},
      {666, 607.00, 407.49, 1},       {667, 603.82, 405.44, 1},
      {668, 601.00, 409.49, 1},       {669, 604.71, 405.95, 1},
      {670, 609.20, 409.19, 1},       {671, 606.81, 406.87, 1},
      {672, 611.76, 412.61, 0},       {673, 616.71, 418.34, 1},
      {674, 617.77, 427.26, 0},       {675, 617.55, 433.39, 0},
      {676, 617.32, 439.53, 0},       {677, 617.10, 445.67, 0},
      {678, 623.95, 446.49, 0},       {679, 630.80, 447.32, 0},
      {680, 635.72, 443.98, 0},       {681, 640.64, 440.64, 1},
      {682, 641.30, 437.36, 1},       {683, 639.53, 438.00, 1},
      {684, 643.41, 438.63, 1},       {685, 642.69, 436.66, 1},
      {686, 643.70, 436.66, 1},       {687, 645.53, 436.50, 1},
      {688, 646.69, 436.35, 1},       {689, 650.88, 436.77, 0},
      {690, 655.07, 437.18, 1},       {691, 656.66, 438.95, 1},
      {692, 656.39, 439.12, 1},       {693, 660.28, 441.48, 1},
      {694, 660.32, 441.83, 1},       {695, 662.44, 443.65, 1},
      {696, 666.36, 447.51, 1},       {697, 665.98, 446.86, 1},
      {698, 668.03, 448.86, 1},       {699, 670.92, 452.82, 1},
      {700, 673.24, 456.00, 1},       {701, 675.62, 459.46, 1},
      {702, 677.33, 463.33, 1},       {703, 675.01, 460.14, 1},
      {704, 669.00, 456.32, 0},       {705, 663.00, 452.50, 1},
      {706, 659.50, 444.50, 1},       {707, 654.50, 438.24, 1},
      {708, 648.67, 431.54, 1},       {709, 638.16, 421.34, 1},
      {710, 633.86, 417.74, 1},       {711, 630.41, 413.58, 1},
      {712, 625.94, 410.22, 1},       {713, 621.94, 406.43, 0},
      {714, 617.88, 402.71, 0},       {715, 613.82, 399.00, 0},
      {716, 603.86, 388.71, 0},       {717, 604.17, 390.05, 0},
      {718, 604.11, 394.38, 0},       {719, 604.78, 396.55, 0},
      {720, 602.22, 395.43, 0},       {721, 599.66, 394.32, 1},
      {722, 597.14, 393.85, 1},       {723, 594.88, 393.37, 0},
      {724, 593.00, 393.23, 0},       {725, 591.19, 393.18, 0},
      {726, 589.46, 393.23, 0},       {727, 587.80, 393.37, 0},
      {728, 586.21, 393.61, 0},       {729, 584.42, 393.34, 1},
      {730, 582.87, 393.86, 1},       {731, 582.51, 394.46, 0},
      {732, 581.03, 394.99, 0},       {733, 579.56, 395.62, 0},
      {734, 577.80, 396.15, 1},       {735, 577.12, 398.88, 1},
      {736, 575.19, 397.62, 1},       {737, 573.80, 398.60, 1},
      {738, 574.42, 400.68, 1},       {739, 571.55, 400.51, 1},
      {740, 570.78, 401.62, 1},
  };
  tennis::Track w64;
  w64.id = 23;
  for (const auto& r : win64)
    w64.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> wfires = tennis::DetectBounces(w64, 1280, &real, {613, 857, 881});
  Check(wfires.size() == 1 && wfires[0] == 702, "window fires 702 only");


  // Half-volley (rally-3.mov, frame 371): the ball lands at the far
  // player's feet and is scooped immediately, so the rise leaves much
  // faster than the descent arrived (ratio 2.7). Only a near-elastic
  // ratio (~1x, an in-air wobble) is a rejection; hit-assisted
  // (ratio > 1.5x) still counts the bounce.
  const double hv[][4] = {
      {358, 550.1, 405.0, 1}, {359, 551.8, 406.4, 1},
      {360, 553.2, 407.8, 1}, {361, 554.8, 409.2, 1},
      {362, 556.5, 410.6, 1}, {363, 558.0, 412.0, 1},
      {364, 559.2, 413.4, 1}, {365, 560.7, 415.0, 1},
      {366, 561.5, 417.4, 0}, {367, 563.1, 420.3, 1},
      {368, 564.5, 429.5, 0}, {369, 565.5, 431.3, 0},
      {370, 566.0, 430.2, 0}, {371, 566.8, 423.4, 1},
      {372, 565.7, 414.5, 0}, {373, 565.5, 409.7, 0},
      {374, 564.4, 402.5, 1}, {375, 565.4, 408.9, 1},
      {376, 565.0, 409.0, 0}, {377, 564.0, 410.9, 0},
      {378, 564.6, 414.3, 0}, {379, 564.0, 417.3, 1},
      {380, 568.9, 419.8, 0},
  };
  tennis::Track half;
  half.id = 19;
  for (const auto& r : hv)
    half.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> halfed = tennis::DetectBounces(half, 1280, &real);
  Check(halfed.size() == 1 && halfed[0] == 371, "half-volley counts");

  // Handover touchdown (rally-3.mov, frame 678): a weak depth-flight
  // fall (10px over 11 frames) lands and rolls, but the tracker jumps
  // 10px sideways onto the near player's head on the next frame, so no
  // V and no steep fall exist. Fall + flat onset + lateral jump still
  // marks the landing.
  const double hand[][4] = {
      {660, 590.2, 425.0, 0}, {661, 595.4, 422.2, 0},
      {662, 597.2, 419.4, 0}, {663, 596.9, 415.7, 0},
      {664, 596.8, 412.0, 0}, {665, 597.6, 408.1, 0},
      {666, 596.7, 406.1, 0}, {667, 603.1, 405.4, 1},
      {668, 604.5, 405.6, 1}, {669, 608.5, 408.2, 1},
      {670, 609.2, 409.2, 1}, {671, 610.2, 409.9, 1},
      {672, 610.7, 410.7, 0}, {673, 610.9, 411.3, 1},
      {674, 610.6, 411.2, 0}, {675, 610.1, 411.1, 1},
      {676, 610.7, 412.6, 0}, {677, 613.6, 414.1, 1},
      {678, 614.5, 415.1, 1}, {679, 614.0, 414.0, 1},
      {680, 624.5, 417.7, 1}, {681, 620.7, 422.7, 1},
      {682, 622.7, 423.1, 1}, {683, 622.3, 424.6, 1},
      {684, 621.4, 425.9, 1}, {685, 623.6, 424.6, 1},
      {686, 625.1, 425.1, 1},
  };
  tennis::Track ho;
  ho.id = 20;
  for (const auto& r : hand)
    ho.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> handed = tennis::DetectBounces(ho, 1280, &real);
  Check(handed.size() == 1 && handed[0] == 678, "handover touchdown counts");

  // Handover guard (rally-3.mov, frame 1244): the same fall + flat +
  // jump shape 2 frames before the detected hit at 1246 is the hit's
  // turnaround, not a landing, so hit-adjacent candidates stay silent.
  const double pre[][4] = {
      {1235, 758.5, 388.9, 1}, {1236, 767.3, 393.5, 1},
      {1237, 775.9, 395.8, 1}, {1238, 785.3, 400.0, 1},
      {1239, 796.0, 405.0, 1}, {1240, 804.7, 408.8, 1},
      {1241, 815.4, 414.1, 1}, {1242, 825.3, 418.7, 1},
      {1243, 836.1, 424.5, 1}, {1244, 846.3, 429.9, 1},
      {1245, 848.5, 431.0, 1}, {1246, 858.0, 436.2, 1},
      {1247, 872.6, 444.0, 1}, {1248, 894.8, 456.8, 0},
      {1249, 911.2, 468.3, 1}, {1250, 925.4, 481.8, 0},
      {1251, 939.0, 489.9, 1}, {1252, 949.9, 521.9, 1},
      {1253, 952.7, 526.8, 1}, {1254, 954.7, 528.9, 1},
      {1255, 956.4, 528.5, 1}, {1256, 954.0, 530.4, 1},
  };
  tennis::Track ph;
  ph.id = 21;
  for (const auto& r : pre)
    ph.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  const std::vector<int> shots1246 = {1246};
  std::vector<int> unguarded = tennis::DetectBounces(ph, 1280, &real);
  Check(unguarded.size() == 1 && unguarded[0] == 1244,
        "pre-hit touchdown shape fires unguarded");
  std::vector<int> guarded =
      tennis::DetectBounces(ph, 1280, &real, shots1246);
  Check(guarded.empty(), "hit-adjacent touchdown stays silent");

  // Negative: a V with a much faster rise off a rolled-in descent
  // (clip27a8 track 7, frame 881: 11 frames flat on the ground, then a
  // depth approach, then a 4x launch) is a pickup hit, never airborne
  // to bounce, so the hit-assisted keep must stay silent.
  const double pick[][4] = {
      {849, 608.7, 347.3, 1}, {850, 607.4, 347.1, 0},
      {851, 606.2, 346.9, 0}, {852, 605.0, 346.7, 0},
      {853, 603.6, 346.6, 1}, {854, 602.8, 346.8, 1},
      {855, 602.3, 345.6, 1}, {856, 600.9, 345.7, 0},
      {857, 599.7, 345.7, 0}, {858, 598.3, 345.7, 1},
      {859, 596.8, 346.3, 0}, {860, 595.2, 346.8, 1},
      {861, 593.9, 347.0, 0}, {862, 592.7, 347.3, 1},
      {863, 591.0, 347.8, 1}, {864, 589.9, 348.6, 0},
      {865, 588.5, 349.6, 1}, {866, 586.8, 351.3, 1},
      {867, 585.7, 352.9, 1}, {868, 583.1, 354.8, 1},
      {869, 581.1, 355.2, 1}, {870, 579.2, 357.1, 1},
      {871, 578.6, 359.1, 1}, {872, 576.7, 361.3, 1},
      {873, 574.8, 362.9, 1}, {874, 572.6, 366.4, 1},
      {875, 570.6, 368.2, 1}, {876, 568.4, 371.7, 1},
      {877, 565.4, 374.5, 0}, {878, 562.4, 377.5, 1},
      {879, 560.4, 378.7, 0}, {880, 558.7, 378.6, 0},
      {881, 557.1, 378.3, 1}, {882, 557.2, 373.3, 1},
      {883, 556.7, 369.1, 1}, {884, 556.0, 364.4, 1},
      {885, 555.4, 359.5, 1}, {886, 555.6, 355.9, 1},
      {887, 555.1, 351.1, 1}, {888, 554.9, 346.8, 1},
      {889, 554.6, 342.4, 1}, {890, 554.5, 338.4, 1},
      {891, 553.8, 334.4, 1}, {892, 553.7, 331.6, 1},
      {893, 552.7, 328.4, 1}, {894, 552.7, 324.9, 1},
      {895, 552.4, 322.8, 1}, {896, 551.2, 319.2, 1},
      {897, 551.1, 316.9, 1},
  };
  tennis::Track pk;
  pk.id = 22;
  for (const auto& r : pick)
    pk.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> nopick = tennis::DetectBounces(pk, 1280, nullptr);
  Check(nopick.empty(), "rolled-in pickup stays silent");

  // Shallow 4-frame gap cusp (rally-3.mov, frame 640): the ball drops
  // behind the near player and reappears 4 frames later barely risen
  // (a roll behind the occlusion, not an impact). The narrowest gap
  // demands a deep cusp, so this stays silent.
  const double shal[][4] = {
      {628, 541.8, 402.2, 1}, {629, 544.5, 404.2, 0},
      {630, 547.2, 406.2, 1}, {631, 550.1, 407.8, 1},
      {632, 553.1, 409.9, 0}, {633, 556.0, 411.9, 1},
      {634, 559.5, 413.6, 0}, {635, 562.4, 415.0, 0},
      {636, 564.9, 416.2, 0}, {637, 567.5, 417.6, 1},
      {638, 568.3, 417.7, 1}, {639, 570.0, 419.8, 0},
      {640, 572.7, 420.8, 0}, {641, 577.2, 421.5, 0},
      {642, 582.1, 421.7, 0}, {643, 588.7, 419.8, 1},
      {644, 590.5, 419.1, 1}, {645, 588.7, 416.7, 0},
      {646, 585.9, 414.3, 1}, {647, 586.5, 413.7, 1},
      {648, 588.0, 413.0, 1}, {649, 589.3, 412.6, 1},
      {650, 590.0, 412.9, 1}, {651, 590.6, 413.4, 1},
      {652, 584.8, 418.3, 0}, {653, 585.3, 418.6, 0},
      {654, 586.6, 418.2, 0}, {655, 588.9, 417.1, 0},
  };
  tennis::Track sh;
  sh.id = 23;
  for (const auto& r : shal)
    sh.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> noshal = tennis::DetectBounces(sh, 1280, &real);
  Check(noshal.empty(), "shallow 4-frame gap cusp stays silent");

  // Handover touchdown on pre-smooth engine input (rally-3.mov,
  // frame 678): jagged pre-apex handover garbage (653-666) plus
  // observation jitter (the 678-679 onset dips 2.3px). The
  // apex-anchored fall ignores pre-apex noise and still counts it.
  const double rehand[][4] = {
      {653, 579.0, 423.6, 0}, {654, 583.7, 419.9, 0},
      {655, 585.1, 420.0, 0}, {656, 597.7, 411.0, 1},
      {657, 598.3, 410.1, 0}, {658, 599.0, 409.2, 1},
      {659, 612.0, 418.5, 1}, {660, 630.2, 425.1, 1},
      {661, 622.9, 421.8, 0}, {662, 615.5, 418.5, 1},
      {663, 602.0, 408.5, 1}, {664, 602.5, 408.0, 1},
      {665, 604.3, 404.7, 1}, {666, 604.1, 405.1, 0},
      {667, 603.8, 405.4, 1}, {668, 604.0, 405.5, 1},
      {669, 608.7, 408.7, 1}, {670, 609.2, 409.2, 1},
      {671, 610.2, 409.8, 1}, {672, 610.7, 410.7, 0},
      {673, 611.1, 411.6, 1}, {674, 610.4, 411.1, 0},
      {675, 609.6, 410.6, 1}, {676, 611.8, 412.7, 0},
      {677, 614.0, 414.7, 1}, {678, 614.3, 415.3, 1},
      {679, 612.3, 413.0, 1}, {680, 626.5, 417.5, 1},
      {681, 620.5, 423.5, 1}, {682, 622.8, 423.0, 1},
      {683, 622.0, 424.3, 1}, {684, 621.0, 426.5, 1},
      {685, 623.5, 424.8, 1}, {686, 625.5, 424.5, 1},
      {687, 626.5, 424.5, 1}, {688, 623.0, 432.5, 1},
      {689, 622.0, 437.5, 1}, {690, 623.8, 432.0, 1},
  };
  tennis::Track rh;
  rh.id = 24;
  for (const auto& r : rehand)
    rh.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> rehanded = tennis::DetectBounces(rh, 1280, &real);
  Check(rehanded.size() == 1 && rehanded[0] == 678,
        "pre-smooth handover touchdown counts");

  // Mid-flight correction (rally-3.mov, frame 844): a smooth 30px
  // descent into the 863 landing takes a small flat step and a 6px
  // lateral correction. Below the 8px handover discontinuity, so no
  // touchdown fires mid-flight.
  const double midfl[][4] = {
      {819, 572.5, 384.5, 1}, {820, 574.0, 384.2, 1},
      {821, 575.5, 384.0, 1}, {822, 577.2, 383.6, 1},
      {823, 578.8, 383.6, 1}, {824, 580.1, 384.1, 1},
      {825, 581.7, 384.0, 1}, {826, 583.1, 384.5, 1},
      {827, 584.7, 385.0, 1}, {828, 586.8, 385.6, 1},
      {829, 588.3, 386.0, 1}, {830, 590.1, 387.1, 1},
      {831, 592.0, 387.7, 1}, {832, 594.0, 389.0, 1},
      {833, 595.7, 390.1, 1}, {834, 598.0, 391.3, 1},
      {835, 599.8, 393.0, 1}, {836, 601.9, 394.4, 1},
      {837, 604.2, 396.1, 1}, {838, 606.0, 398.2, 1},
      {839, 608.8, 400.5, 1}, {840, 611.0, 402.8, 1},
      {841, 613.3, 405.1, 1}, {842, 615.8, 408.0, 1},
      {843, 618.3, 410.9, 1}, {844, 621.2, 414.3, 1},
      {845, 623.3, 416.6, 1}, {846, 629.5, 424.7, 1},
      {847, 629.4, 424.3, 1},
  };
  tennis::Track mf;
  mf.id = 25;
  for (const auto& r : midfl)
    mf.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> nomid = tennis::DetectBounces(mf, 1280, &real);
  Check(nomid.empty(), "mid-flight correction stays silent");

  // Lone-take union (rally-3.mov, frame ~596): a shadow take at 595
  // splits the void 592->600 into sub-gaps that each fail alone (the
  // ghost flattens the descent slope below the noise gate). The union
  // ignores the interior take and fires at the leg intersection.
  tennis::Track lu;
  lu.id = 26;
  for (int k = 0; k < 8; ++k)
    lu.points.push_back(Pt(100 + k, 570.0 + 0.5 * k, 408.0 + 2.0 * k, true));
  lu.points.push_back(Pt(110, 572.0, 417.0, true));
  for (int k = 0; k < 8; ++k)
    lu.points.push_back(
        Pt(115 + k, 576.0 + 0.2 * k, 430.0 - 1.6 * k, true));
  std::vector<int> lun = tennis::DetectBounces(lu, 1280, nullptr);
  Check(lun.size() == 1 && lun[0] == 113, "lone-take union fires");

  // Lone take ON the descent line (rally-3.mov, frame ~761): the
  // sub-gap 753->761 dies on the t* edge, 761->766 on the gap-4
  // amplitude rule. The union spans the ghost and fires.
  tennis::Track lo;
  lo.id = 27;
  for (int k = 0; k < 11; ++k)
    lo.points.push_back(
        Pt(200 + k, 566.0 - 0.8 * k, 404.0 + 1.4 * k, true));
  lo.points.push_back(Pt(218, 551.6, 429.2, true));
  for (int k = 0; k < 11; ++k)
    lo.points.push_back(
        Pt(223 + k, 553.0 - 0.27 * k, 431.0 - 1.0 * k, true));
  std::vector<int> lon = tennis::DetectBounces(lo, 1280, nullptr);
  Check(lon.size() == 1 && lon[0] == 221, "on-line lone take unions");

  // Negative: monotone descent through a lone take (no V leg) stays
  // silent on every path including the union.
  tennis::Track lm;
  lm.id = 28;
  for (int k = 0; k < 8; ++k)
    lm.points.push_back(Pt(300 + k, 570.0 + 0.5 * k, 400.0 + 2.0 * k, true));
  lm.points.push_back(Pt(310, 575.0, 420.0, true));
  for (int k = 0; k < 8; ++k)
    lm.points.push_back(
        Pt(313 + k, 577.0 + 0.3 * k, 424.0 + 1.5 * k, true));
  std::vector<int> lmn = tennis::DetectBounces(lm, 1280, nullptr);
  Check(lmn.empty(), "monotone lone take stays silent");

  // Overlapping unions (rally-3.mov, frame ~371): two unions fire a
  // frame apart off the same drop-shot mush; dedup-deepest keeps one.
  const double mush[][4] = {
      {360, 553.10, 407.91, 1}, {361, 554.67, 409.26, 1},
      {362, 556.43, 410.74, 1}, {363, 558.14, 411.91, 1},
      {364, 559.35, 413.27, 1}, {365, 560.71, 414.98, 1},
      {367, 563.01, 418.34, 1}, {371, 567.17, 423.59, 1},
      {375, 572.39, 430.83, 1}, {378, 574.86, 433.10, 1},
      {384, 578.97, 422.57, 1}, {385, 578.70, 421.13, 1},
      {387, 579.61, 417.64, 1}, {388, 580.12, 417.14, 1},
      {390, 580.90, 414.92, 1},
  };
  tennis::Track mu;
  mu.id = 29;
  for (const auto& r : mush)
    mu.points.push_back(
        Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> mun = tennis::DetectBounces(mu, 1280, nullptr);
  Check(mun.size() == 1 && mun[0] == 377, "overlapping unions dedup");

  // Teleport bounce (rally-3.mov, frame ~678): a ghost-locked crawl
  // jumps 27px onto the deflected ball and rolls. The switch point is
  // the impact. The jump's own fake hit (self +-2) never vetoes; a
  // real nearby hit does.
  const double tp[][4] = {
      {670, 604.0, 405.0, 1}, {671, 604.9, 406.0, 1},
      {672, 605.8, 407.0, 1}, {673, 606.7, 408.0, 1},
      {674, 607.6, 409.0, 1}, {675, 608.5, 410.0, 1},
      {676, 609.4, 411.0, 1}, {677, 610.5, 412.9, 1},
      // Pre-smooth crawl into the switch: nearly flat (drop 1.0).
      {678, 611.0, 413.0, 1}, {679, 612.0, 413.2, 1},
      {680, 612.5, 413.4, 1}, {681, 613.0, 413.6, 1},
      {682, 614.0, 414.0, 1}, {683, 639.0, 438.0, 1},
      {684, 640.8, 435.6, 1}, {685, 642.5, 436.5, 1},
      {686, 644.5, 437.3, 1}, {687, 645.5, 436.5, 1},
      {688, 646.8, 436.6, 1}, {689, 648.3, 436.9, 1},
      {690, 649.8, 437.2, 1}, {691, 651.3, 437.5, 1},
      {692, 652.8, 437.8, 1},
  };
  tennis::Track te;
  te.id = 30;
  for (const auto& r : tp)
    te.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> self = {682};
  std::vector<int> ten = tennis::DetectBounces(te, 1280, nullptr, self);
  Check(ten.size() == 1 && ten[0] == 682, "teleport bounce fires");
  std::vector<int> real7 = {675};
  std::vector<int> tivet =
      tennis::DetectBounces(te, 1280, nullptr, real7);
  Check(tivet.empty(), "nearby real hit vetoes teleport");

  // Supplement: a teleport into a V rises (classic fires) — the
  // teleport stays suppressed, no double.
  tennis::Track tv;
  tv.id = 31;
  for (int k = 0; k < 5; ++k)
    tv.points.push_back(Pt(100 + k, 600.0 + k, 400.0 + 2.0 * k, true));
  tv.points.push_back(Pt(105, 630.0, 410.0, true));
  for (int k = 1; k <= 7; ++k)
    tv.points.push_back(Pt(105 + k, 630.0 + 2.0 * k, 410.0 - 8.0 * k, true));
  std::vector<int> tvn = tennis::DetectBounces(tv, 1280, nullptr);
  Check(tvn.size() == 1 && tvn[0] == 105, "teleport defers to classic V");

  // Negative: a 6px mid-flight correction (under the 12px step floor)
  // onto a roll stays silent.
  tennis::Track ts;
  ts.id = 32;
  for (int k = 0; k < 5; ++k)
    ts.points.push_back(
        Pt(200 + k, 600.0 + 0.5 * k, 400.0 + 0.75 * k, true));
  ts.points.push_back(Pt(205, 609.0, 404.5, true));
  for (int k = 1; k <= 6; ++k)
    ts.points.push_back(
        Pt(205 + k, 609.0 + 1.5 * k, 404.5 + 0.2 * k, true));
  std::vector<int> tsn = tennis::DetectBounces(ts, 1280, nullptr);
  Check(tsn.empty(), "small step stays silent");

  // Negative: a mid-roll track-switch (flat pre, drop 0.2) onto the
  // same roll is no impact — the 0.5px pre-drop floor kills it.
  tennis::Track mr;
  mr.id = 33;
  for (int k = 0; k < 5; ++k)
    mr.points.push_back(
        Pt(300 + k, 600.0 + 2.0 * k, 450.0 + 0.05 * k, true));
  mr.points.push_back(Pt(305, 633.0, 451.0, true));
  for (int k = 1; k <= 6; ++k)
    mr.points.push_back(
        Pt(305 + k, 633.0 + 2.0 * k, 451.0 + 0.2 * k, true));
  std::vector<int> mrn = tennis::DetectBounces(mr, 1280, nullptr);
  Check(mrn.empty(), "mid-roll switch stays silent");

  // Rise persistence (rally-3.mov, frame 920): a racket-head track
  // falls steeply then flickers up 3 takes over 6 frames — Rescue-V
  // stays silent. The same fall with a sustained 12-frame rise fires.
  const double rk[][4] = {
      {908, 684.0, 435.0, 1}, {909, 684.0, 435.0, 1},
      {910, 684.0, 435.0, 1}, {911, 684.0, 435.0, 1},
      {912, 684.6, 435.7, 1}, {913, 678.4, 451.9, 1},
      {914, 680.0, 457.0, 0}, {915, 679.8, 464.0, 0},
      {916, 679.5, 472.0, 0}, {917, 679.6, 481.0, 0},
      {918, 679.0, 490.0, 0}, {919, 678.0, 499.0, 0},
      {920, 676.3, 507.3, 1}, {921, 678.0, 502.0, 0},
      {922, 677.7, 496.2, 1}, {923, 676.0, 490.0, 0},
      {924, 674.0, 485.0, 0}, {925, 670.0, 480.0, 0},
      {926, 658.7, 474.8, 1}, {927, 652.0, 470.0, 0},
  };
  tennis::Track rf;
  rf.id = 34;
  for (const auto& r : rk)
    rf.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> rfn = tennis::DetectBounces(rf, 1280, nullptr);
  Check(rfn.empty(), "6-frame flicker rise stays silent");
  tennis::Track rs;
  rs.id = 35;
  for (const auto& r : rk)
    rs.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  rs.points.push_back(Pt(928, 655.0, 468.0, true));
  rs.points.push_back(Pt(930, 652.0, 462.0, true));
  rs.points.push_back(Pt(932, 650.0, 456.0, true));
  std::vector<int> rsn = tennis::DetectBounces(rs, 1280, nullptr);
  Check(rsn.size() == 1 && rsn[0] == 920, "sustained rise fires rescue-V");

  // Despike valley spare (rally-3.mov, frame 371): the linker catches the
  // true impact bottom (567.7, 423.4) between the 368 ghost peak the shoe
  // flash yanked the velocity onto and the 372 rise. A 1-take upward
  // flicker is physically impossible (a ghost), but a 1-take downward
  // spike is a candidate impact bottom — despike must kill the peak and
  // spare the valley so the event paths can judge it.
  const double vk[][4] = {
      {365, 560.8, 415.3, 1}, {366, 562.1, 417.4, 1},
      {367, 563.0, 418.2, 1}, {368, 560.5, 399.5, 1},
      {371, 567.7, 423.4, 1}, {372, 563.0, 400.5, 1},
      {375, 565.5, 409.4, 1}, {376, 566.5, 410.7, 1},
  };
  tennis::Track vt;
  vt.id = 36;
  for (const auto& r : vk)
    vt.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  tennis::DespikeTrack(vt, 1280);
  bool valley_kept = false, peak_killed = false;
  for (const auto& p : vt.points) {
    if (p.frame == 371 && p.observed && p.y == 423.4) valley_kept = true;
    if (p.frame == 368 && !p.observed) peak_killed = true;
  }
  Check(valley_kept, "impact valley survives despike");
  Check(peak_killed, "ghost peak still despiked");

  // Hand-held hold (rally-3.mov, frame 371): the far player lowers the
  // ball in hand (25px over 12 frames) and holds it — the old trap rule
  // fired the hold bottom as a landing. But a trapped ball can never
  // rise above the apex it fell from, and this one relaunches 86px
  // (the 404+ toss): energy creation, so a hand, never a landing. The
  // trap-down energy gate suppresses it; nothing else fires on the
  // hand-bounce wobble either, so the window is empty.
  const double holdpts[][4] = {
      {355, 544.94, 401.47, 1}, {356, 546.76, 402.57, 1},
      {357, 548.50, 403.52, 1}, {358, 550.03, 404.98, 1},
      {359, 551.79, 406.39, 1}, {360, 554.00, 406.30, 1},
      {361, 554.62, 409.26, 1}, {362, 556.43, 410.80, 1},
      {363, 558.00, 412.00, 1}, {364, 559.22, 413.39, 1},
      {365, 560.70, 414.97, 1}, {366, 562.16, 417.32, 1},
      {367, 563.01, 418.32, 1}, {368, 563.85, 419.31, 0},
      {369, 565.14, 420.68, 0}, {370, 566.42, 422.05, 0},
      {371, 567.71, 423.41, 1}, {372, 563.00, 400.49, 1},
      {373, 563.84, 403.66, 0}, {374, 564.68, 406.83, 0},
      {375, 565.51, 410.00, 1}, {376, 566.51, 411.00, 1},
      {377, 566.51, 410.00, 1}, {378, 567.40, 410.62, 1},
      {379, 566.00, 416.54, 1}, {380, 563.26, 417.51, 1},
      {381, 568.48, 410.00, 1}, {382, 573.70, 402.49, 0},
      {383, 578.92, 394.98, 0}, {384, 574.44, 405.65, 0},
      {385, 569.96, 416.33, 0}, {386, 565.48, 427.00, 1},
      {387, 566.24, 421.74, 0}, {388, 567.00, 416.47, 1},
      {389, 568.84, 415.47, 0}, {390, 570.67, 414.47, 0},
      {391, 572.51, 413.48, 1}, {392, 582.44, 413.51, 1},
      {393, 582.66, 412.72, 1}, {394, 583.29, 412.34, 1},
      {395, 583.66, 411.70, 1}, {396, 584.44, 411.49, 1},
      {397, 584.50, 411.00, 1}, {398, 584.51, 410.49, 1},
      {399, 585.48, 410.50, 1}, {400, 585.40, 410.29, 1},
      {401, 586.49, 410.51, 1}, {402, 586.54, 410.47, 1},
      {403, 587.60, 410.30, 1}, {404, 587.52, 410.52, 1},
      {405, 586.69, 410.68, 1}, {406, 588.35, 410.73, 1},
      {407, 588.52, 410.48, 1}, {408, 588.28, 407.65, 1},
      {409, 587.54, 404.52, 1}, {410, 587.38, 402.16, 1},
      {411, 587.80, 401.25, 1}, {412, 586.61, 396.79, 1},
      {413, 586.46, 394.48, 1}, {414, 586.76, 393.76, 1},
      {415, 585.49, 389.47, 1}, {416, 584.71, 386.66, 1},
      {417, 585.39, 384.85, 1}, {418, 584.00, 382.01, 1},
      {419, 583.53, 379.53, 1}, {420, 583.49, 377.51, 1},
      {421, 583.00, 375.48, 1}, {422, 582.49, 373.00, 1},
      {423, 582.24, 370.99, 1}, {424, 581.67, 368.70, 1},
      {425, 581.32, 366.69, 1}, {426, 580.70, 364.70, 1},
      {427, 580.49, 363.00, 1}, {428, 580.00, 361.46, 1},
      {429, 579.50, 359.48, 1}, {430, 579.33, 357.33, 1},
      {431, 578.54, 355.52, 1}, {432, 578.29, 354.24, 1},
      {433, 577.70, 352.35, 1}, {434, 577.20, 350.85, 0},
      {435, 576.70, 349.36, 1}, {436, 576.64, 348.31, 1},
      {437, 575.68, 346.68, 1}, {438, 575.50, 345.49, 1},
      {439, 574.53, 344.48, 1}, {440, 574.49, 343.46, 1},
      {441, 574.23, 342.01, 1}, {442, 573.50, 341.00, 1},
      {443, 573.00, 340.24, 1}, {444, 572.68, 339.34, 1},
      {445, 572.45, 338.49, 1}, {446, 571.51, 337.52, 1},
      {447, 570.52, 337.52, 1}, {448, 570.35, 336.68, 1},
      {449, 569.49, 336.49, 1}, {450, 569.53, 335.53, 1},
      {451, 569.09, 335.42, 0}, {452, 568.66, 335.32, 1},
      {453, 568.10, 335.38, 0}, {454, 567.55, 335.45, 1},
      {455, 566.00, 335.49, 1}, {456, 566.31, 335.36, 1},
      {457, 565.97, 335.67, 1}, {458, 565.48, 336.48, 1},
      {459, 564.66, 336.72, 1}, {460, 564.30, 337.66, 1},
  };
  tennis::Track thold;
  thold.id = 37;
  for (const auto& r : holdpts)
    thold.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> heldb = tennis::DetectBounces(thold, 1280, nullptr);
  Check(heldb.empty(), "hand hold fires nothing");

  // Real trapped landing (rally-3.mov, frame 592): a lob descends 59px
  // over 50 clean frames, lands, and rebounds 26px — rise stays well
  // under the drop, so the energy gate keeps the trap-down fire.
  const double landpts[][4] = {
      {540, 508.86, 371.01, 1}, {541, 510.13, 367.03, 1},
      {542, 514.03, 365.54, 1}, {543, 519.45, 365.58, 1},
      {544, 520.51, 363.64, 1}, {545, 523.31, 363.21, 1},
      {546, 527.02, 363.07, 1}, {547, 528.48, 362.68, 1},
      {548, 530.82, 362.79, 1}, {549, 534.91, 364.23, 1},
      {550, 535.16, 363.00, 1}, {551, 537.34, 363.49, 1},
      {552, 540.88, 364.88, 1}, {553, 540.94, 364.51, 1},
      {554, 542.13, 365.16, 1}, {555, 545.10, 367.15, 1},
      {556, 545.28, 366.98, 1}, {557, 546.81, 367.81, 1},
      {558, 550.31, 369.69, 1}, {559, 549.29, 369.96, 1},
      {560, 550.69, 370.97, 1}, {561, 553.12, 373.12, 1},
      {562, 552.82, 373.18, 1}, {563, 553.99, 374.50, 1},
      {564, 556.88, 376.88, 1}, {565, 556.16, 377.13, 1},
      {566, 557.19, 378.39, 1}, {567, 558.01, 379.96, 1},
      {568, 559.19, 381.40, 1}, {569, 559.84, 382.62, 1},
      {570, 562.70, 384.79, 1}, {571, 561.61, 385.79, 1},
      {572, 562.51, 387.48, 1}, {573, 564.92, 391.03, 1},
      {574, 564.43, 390.50, 1}, {575, 564.68, 392.30, 1},
      {576, 566.70, 394.70, 1}, {577, 566.48, 395.50, 1},
      {578, 567.02, 397.24, 1}, {579, 568.98, 399.10, 1},
      {580, 568.49, 400.52, 1}, {581, 569.28, 402.63, 1},
      {582, 569.68, 404.30, 1}, {583, 570.35, 405.71, 1},
      {584, 570.72, 407.67, 1}, {585, 570.00, 409.75, 1},
      {586, 572.00, 411.48, 1}, {587, 572.69, 413.32, 1},
      {588, 573.30, 415.30, 1}, {589, 573.56, 417.47, 1},
      {590, 574.36, 419.64, 0}, {591, 575.15, 421.81, 1},
      {592, 575.50, 422.56, 1}, {593, 571.24, 420.37, 0},
      {594, 566.98, 418.17, 0}, {595, 562.72, 415.98, 1},
      {596, 564.00, 415.55, 1}, {597, 564.97, 414.03, 0},
      {598, 564.57, 413.64, 0}, {599, 564.53, 413.54, 0},
      {600, 566.18, 410.64, 1}, {601, 568.96, 413.65, 1},
      {602, 565.52, 416.52, 1}, {603, 566.00, 417.31, 1},
      {604, 566.67, 415.37, 0}, {605, 567.33, 413.42, 0},
      {606, 568.00, 411.47, 1}, {607, 574.50, 411.50, 0},
      {608, 581.00, 411.53, 1}, {609, 581.30, 410.67, 1},
      {610, 581.50, 409.53, 1}, {611, 581.67, 408.72, 1},
      {612, 574.00, 410.53, 1}, {613, 572.82, 409.18, 1},
      {614, 573.66, 409.00, 1}, {615, 583.00, 406.47, 1},
      {616, 582.71, 405.63, 1}, {617, 583.47, 404.47, 1},
      {618, 583.52, 403.45, 1}, {619, 583.71, 402.33, 1},
      {620, 584.44, 401.50, 1}, {621, 584.50, 400.52, 1},
      {622, 584.70, 399.70, 1}, {623, 585.31, 399.30, 1},
      {624, 585.50, 398.50, 1}, {625, 585.89, 397.90, 0},
      {626, 586.29, 397.30, 0}, {627, 586.68, 396.70, 1},
      {628, 587.63, 396.56, 0}, {629, 588.15, 396.29, 0},
      {630, 588.67, 396.09, 0}, {631, 588.67, 395.68, 1},
      {632, 590.00, 395.53, 1}, {633, 589.33, 395.32, 1},
      {634, 590.79, 395.46, 0}, {635, 591.11, 395.76, 0},
      {636, 591.38, 396.18, 0}, {637, 591.59, 396.72, 0},
      {638, 591.74, 397.38, 0}, {639, 591.84, 398.16, 0},
      {640, 591.89, 399.06, 0}, {641, 591.88, 400.08, 0},
      {642, 591.81, 401.21, 0}, {643, 591.68, 402.47, 0},
      {644, 596.48, 400.53, 1}, {645, 593.11, 404.93, 0},
      {646, 589.75, 409.33, 0}, {647, 586.39, 413.72, 1},
      {648, 587.76, 413.26, 0}, {649, 589.13, 412.80, 1},
      {650, 590.35, 412.57, 1}, {651, 591.78, 412.52, 1},
      {652, 592.80, 412.28, 0},
  };
  tennis::Track tland;
  tland.id = 38;
  for (const auto& r : landpts)
    tland.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> landed592 = tennis::DetectBounces(tland, 1280, nullptr);
  Check(landed592.size() == 1 && landed592[0] == 592, "real trap still fires 592");

  // Trap + re-dip merge (rally-3.mov, frames 942 + 950): the landing
  // fires the trap path and the deflection 8 frames later fires the
  // classic V; one rising take between is the same event (not a
  // sustained hop), so they merge into 942.
  const double redippts[][4] = {
      {917, 582.00, 394.30, 1}, {918, 581.66, 394.78, 1},
      {919, 578.15, 395.82, 1}, {920, 576.22, 396.59, 1},
      {921, 575.12, 397.12, 1}, {922, 572.51, 398.48, 1},
      {923, 571.02, 399.26, 1}, {924, 570.85, 401.03, 1},
      {925, 567.81, 401.39, 1}, {926, 566.49, 402.48, 1},
      {927, 565.16, 403.99, 1}, {928, 563.68, 404.68, 1},
      {929, 562.41, 405.82, 1}, {930, 562.11, 407.30, 1},
      {931, 560.00, 408.48, 1}, {932, 558.97, 409.75, 1},
      {933, 558.85, 410.89, 1}, {934, 556.53, 412.48, 1},
      {935, 555.37, 413.72, 1}, {936, 555.98, 414.89, 1},
      {937, 553.51, 416.52, 1}, {938, 552.81, 418.37, 1},
      {939, 552.49, 419.00, 1}, {940, 551.24, 420.91, 0},
      {941, 550.00, 422.83, 1}, {942, 549.48, 424.00, 1},
      {943, 544.44, 419.10, 0}, {944, 543.47, 419.32, 0},
      {945, 542.63, 419.47, 0}, {946, 533.00, 410.53, 1},
      {947, 533.00, 412.02, 1}, {948, 536.67, 415.86, 0},
      {949, 540.33, 419.71, 0}, {950, 544.00, 423.55, 1},
      {951, 545.07, 422.89, 1}, {952, 544.42, 421.63, 0},
      {953, 543.77, 420.37, 0}, {954, 543.11, 419.11, 1},
      {955, 542.49, 417.93, 1}, {956, 542.00, 416.46, 1},
      {957, 541.69, 415.33, 1}, {958, 541.49, 414.49, 1},
      {959, 541.70, 413.66, 1}, {960, 543.50, 412.50, 1},
      {961, 545.00, 411.51, 1}, {962, 546.51, 410.52, 1},
      {963, 549.09, 409.68, 1}, {964, 550.00, 409.00, 1},
      {965, 551.97, 408.24, 1}, {966, 554.05, 407.10, 1},
      {967, 555.49, 406.54, 1}, {968, 557.34, 406.28, 1},
      {969, 560.00, 405.56, 1}, {970, 561.32, 405.30, 1},
      {971, 563.00, 404.51, 1}, {972, 565.58, 405.20, 1},
      {973, 567.32, 403.71, 1}, {974, 569.48, 403.55, 1},
      {975, 572.79, 404.14, 1}, {976, 573.53, 403.48, 1},
      {977, 576.44, 403.49, 1}, {978, 578.48, 403.49, 1},
      {979, 580.52, 403.50, 1}, {980, 583.03, 403.54, 1},
      {981, 587.06, 405.45, 1}, {982, 588.04, 404.51, 1},
      {983, 590.84, 405.16, 1}, {984, 594.73, 406.17, 1},
      {985, 596.05, 406.49, 1}, {986, 599.03, 407.48, 1},
      {987, 602.89, 408.89, 1}, {988, 605.01, 409.49, 1},
      {989, 608.11, 410.84, 1}, {990, 613.26, 412.63, 1},
      {991, 614.31, 413.57, 1}, {992, 617.73, 415.33, 1},
      {993, 621.28, 416.62, 1}, {994, 624.68, 419.04, 1},
      {995, 627.71, 420.73, 1}, {996, 632.02, 422.88, 1},
      {997, 640.00, 428.50, 1}, {998, 640.00, 428.49, 1},
      {999, 645.11, 432.89, 1}, {1000, 648.01, 433.85, 1},
      {1001, 652.65, 437.88, 1}, {1002, 658.78, 443.32, 1},
  };
  tennis::Track tredip;
  tredip.id = 39;
  for (const auto& r : redippts)
    tredip.points.push_back(Pt((int)r[0], r[1], r[2], r[3] != 0.0));
  std::vector<int> merged942 = tennis::DetectBounces(tredip, 1280, nullptr);
  Check(merged942.size() == 1 && merged942[0] == 942, "trap + redip merge to 942");

  return failures ? 1 : 0;
}
