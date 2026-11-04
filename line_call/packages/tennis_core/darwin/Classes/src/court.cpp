#include "tennis/court.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <numeric>
#include <random>
#include <set>

#include "tennis/img.hpp"
#include "tennis/num.hpp"
#include "tennis/types.hpp"

namespace tennis {
namespace {

constexpr double kHalfSgl = 8.23 / 2;
// Service line |y| from the CENTRE: the service line is 6.40 m from the net,
// i.e. 5.485 m from its baseline. (Was kHalfLen - 6.40 = 5.485, which is the
// baseline distance, not the centre distance — every service projection sat
// ~0.9 m off.)
constexpr double kServY = 6.40;
constexpr double kPi = 3.14159265358979323846;

using img::Bgr;
using img::Gray;

Gray PurpleVote(const Bgr& hsv) {
  const uint8_t lo[3] = {115, 25, 40}, hi[3] = {165, 255, 255};
  return img::InRange(hsv, lo, hi);
}

// -> (wide roi, strict roi). Empty (w==0) when no surface found.
std::pair<Gray, Gray> PurpleRoi(const Bgr& hsv) {
  int W = hsv.w, H = hsv.h;
  Gray mask = img::MorphClose(PurpleVote(hsv), 15);
  std::vector<int> lab;
  std::vector<int> areas;
  img::ConnectedComponents(mask, lab, areas);
  if (areas.size() <= 1) return {{}, {}};
  const double probes[4][2] = {{0.50, 0.65}, {0.42, 0.60}, {0.58, 0.60}, {0.50, 0.55}};
  std::map<int, int> votes;
  for (auto& pr : probes) {
    int pid = lab[int(H * pr[1]) * W + int(W * pr[0])];
    if (pid > 0) votes[pid]++;
  }
  int best = 1;
  if (votes.empty()) {
    int bi = 1;
    for (size_t i = 2; i < areas.size(); ++i)
      if (areas[i] > areas[bi]) bi = (int)i;
    best = bi;
  } else {
    int bv = -1, ba = -1;
    for (auto& [pid, v] : votes) {
      if (v > bv || (v == bv && areas[pid] > ba)) {
        bv = v;
        ba = areas[pid];
        best = pid;
      }
    }
  }
  Gray comp{W, H, std::vector<uint8_t>(W * H)};
  for (int i = 0; i < W * H; ++i) comp.px[i] = lab[i] == best ? 255 : 0;
  return {img::Dilate(comp, 11), img::Dilate(comp, 3)};
}

bool IsBanned(double ax, double ay, double dx, double dy,
              const std::vector<std::array<double, 4>>& banned) {
  for (auto& bd : banned) {
    double da = std::fabs(std::atan2(dy, dx) - std::atan2(bd[3], bd[2]));
    da = std::min({da, kPi - da, 2 * kPi - da});
    if (da > 3.0 * kPi / 180) continue;
    double nx = -bd[3], ny = bd[2];
    if (std::fabs(nx * (ax - bd[0]) + ny * (ay - bd[1])) < 6.0) return true;
  }
  return false;
}

// Peeling RANSAC over white pixels -> segments (x1,y1,x2,y2).
std::vector<std::array<double, 4>> RansacLines(const Gray& thin, int rounds = 14,
                                               int min_inliers = 50,
                                               int iters = 800) {
  int W = thin.w, H = thin.h;
  std::vector<double> px, py;
  for (int y = 0; y < H; ++y)
    for (int x = 0; x < W; ++x)
      if (thin.px[y * W + x]) {
        px.push_back(x);
        py.push_back(y);
      }
  std::vector<std::array<double, 4>> out;
  const int n = (int)px.size();
  if (n < min_inliers) return out;
  std::vector<char> alive(n, 1);
  std::mt19937 rng(7);
  std::vector<std::array<double, 4>> banned;  // cenx,ceny,dx,dy
  std::vector<int> idx;
  std::vector<double> dist;
  for (int round = 0; round < rounds; ++round) {
    idx.clear();
    for (int i = 0; i < n; ++i)
      if (alive[i]) idx.push_back(i);
    if ((int)idx.size() < min_inliers) break;
    std::vector<int> best_inl;
    int best_n = 0;
    std::uniform_int_distribution<int> pick(0, (int)idx.size() - 1);
    for (int it = 0; it < iters; ++it) {
      int ia = idx[pick(rng)], ib = idx[pick(rng)];
      double dx = px[ib] - px[ia], dy = py[ib] - py[ia];
      double L = std::hypot(dx, dy);
      if (L < 30.0) continue;
      dx /= L;
      dy /= L;
      if (IsBanned(px[ia], py[ia], dx, dy, banned)) continue;
      double nx = -dy, ny = dx;
      std::vector<int> inl;
      inl.reserve(idx.size() / 4);
      for (int i : idx)
        if (std::fabs((px[i] - px[ia]) * nx + (py[i] - py[ia]) * ny) < 2.0)
          inl.push_back(i);
      if ((int)inl.size() > best_n) {
        best_n = (int)inl.size();
        best_inl = std::move(inl);
      }
    }
    if (best_n < min_inliers) break;
    // Bimodal split.
    {
      double cx = 0, cy = 0;
      for (int i : best_inl) {
        cx += px[i];
        cy += py[i];
      }
      cx /= best_n;
      cy /= best_n;
      double e00 = 0, e01 = 0, e11 = 0;
      for (int i : best_inl) {
        double ux = px[i] - cx, uy = py[i] - cy;
        e00 += ux * ux;
        e01 += ux * uy;
        e11 += uy * uy;
      }
      double val, vx, vy;
      num::Eigh2Top(e00, e01, e11, val, vx, vy);
      double nx = -vy, ny = vx;
      std::vector<std::pair<double, int>> oo;
      for (size_t k = 0; k < best_inl.size(); ++k) {
        int i = best_inl[k];
        oo.emplace_back((px[i] - cx) * nx + (py[i] - cy) * ny, (int)k);
      }
      std::sort(oo.begin(), oo.end());
      double gmax = 0;
      int gpos = -1;
      for (size_t k = 1; k < oo.size(); ++k) {
        double g = oo[k].first - oo[k - 1].first;
        if (g > gmax) {
          gmax = g;
          gpos = (int)k;
        }
      }
      if (gmax > 8.0 && gpos >= 40 && (int)best_inl.size() - gpos >= 40) {
        std::vector<int> keep;
        if (gpos < (int)best_inl.size() - gpos) {
          for (size_t k = gpos; k < oo.size(); ++k) keep.push_back(best_inl[oo[k].second]);
        } else {
          for (int k = 0; k < gpos; ++k) keep.push_back(best_inl[oo[k].second]);
        }
        best_inl = std::move(keep);
        best_n = (int)best_inl.size();
      }
    }
    double cx = 0, cy = 0;
    for (int i : best_inl) {
      cx += px[i];
      cy += py[i];
    }
    cx /= best_n;
    cy /= best_n;
    double e00 = 0, e01 = 0, e11 = 0;
    for (int i : best_inl) {
      double ux = px[i] - cx, uy = py[i] - cy;
      e00 += ux * ux;
      e01 += ux * uy;
      e11 += uy * uy;
    }
    double val, vx, vy;
    num::Eigh2Top(e00, e01, e11, val, vx, vy);
    double tmin = 1e18, tmax = -1e18;
    for (int i : best_inl) {
      double t = (px[i] - cx) * vx + (py[i] - cy) * vy;
      tmin = std::min(tmin, t);
      tmax = std::max(tmax, t);
    }
    double extent = tmax - tmin;
    if (extent > 1 && best_n / extent < 0.5) {
      banned.push_back({cx, cy, vx, vy});
      continue;
    }
    out.push_back({cx + vx * tmin, cy + vy * tmin, cx + vx * tmax, cy + vy * tmax});
    double nx = -vy, ny = vx;
    for (int i = 0; i < n; ++i)
      if (alive[i] &&
          std::fabs((px[i] - cx) * nx + (py[i] - cy) * ny) < 2.0)
        alive[i] = 0;
  }
  return out;
}

std::vector<std::array<double, 4>> RidgeFilter(
    const std::vector<std::array<double, 4>>& segs, const Bgr& hsv) {
  int W = hsv.w, H = hsv.h;
  std::vector<std::array<double, 4>> kept;
  for (auto& s : segs) {
    double x1 = s[0], y1 = s[1], x2 = s[2], y2 = s[3];
    double dx = x2 - x1, dy = y2 - y1;
    double L = std::hypot(dx, dy);
    if (L == 0) L = 1e-6;
    double nx = -dy / L, ny = dx / L;
    int n = std::max(3, (int)(L / 4));
    int votes = 0;
    for (int k = 0; k < n; ++k) {
      double t = n == 1 ? 0 : (double)k / (n - 1);
      int cx = (int)(x1 + dx * t), cy = (int)(y1 + dy * t);
      int ax = (int)(cx + nx * 5), ay = (int)(cy + ny * 5);
      int bx = (int)(cx - nx * 5), by = (int)(cy - ny * 5);
      if (!(0 <= ax && ax < W && 0 <= ay && ay < H && 0 <= bx && bx < W &&
            0 <= by && by < H))
        continue;
      int vc = hsv.px[(cy * W + cx) * 3 + 2];
      int va = hsv.px[(ay * W + ax) * 3 + 2];
      int vb = hsv.px[(by * W + bx) * 3 + 2];
      int hi = std::max(va, vb), lo = std::min(va, vb);
      if (vc > hi + 7 || (hi - vc < 15 && vc - lo > 25)) votes++;
    }
    if (votes >= std::max(2, (int)(n * 0.4))) kept.push_back(s);
  }
  return kept;
}

struct WhiteOut {
  std::vector<std::array<double, 4>> segs;
  Gray thin, white;
};

WhiteOut WhiteSegments(const Bgr& hsv, const Gray& roi) {
  int W = hsv.w, H = hsv.h;
  std::vector<int> s(W * H), v(W * H);
  for (int i = 0; i < W * H; ++i) {
    s[i] = hsv.px[3 * i + 1];
    v[i] = hsv.px[3 * i + 2];
  }
  Gray vv{W, H, {}};
  vv.px.resize(W * H);
  for (int i = 0; i < W * H; ++i) vv.px[i] = (uint8_t)v[i];
  Gray vmed = img::MedianBlur21(vv);
  Gray white{W, H, std::vector<uint8_t>(W * H)};
  for (int i = 0; i < W * H; ++i) {
    bool bright = s[i] <= 28 && v[i] >= 190;
    bool contrast = s[i] <= 48 && (v[i] - (int)vmed.px[i]) >= 28 && v[i] >= 150;
    white.px[i] = (bright || contrast) && roi.px[i] ? 255 : 0;
  }
  std::vector<float> f(W * H);
  for (int i = 0; i < W * H; ++i) f[i] = white.px[i] ? 1.0f : 0.0f;
  std::vector<float> density = img::BoxMean13(f, W, H);
  Gray thin{W, H, std::vector<uint8_t>(W * H)};
  for (int i = 0; i < W * H; ++i)
    thin.px[i] = (white.px[i] && density[i] < 0.55f) ? 255 : 0;
  WhiteOut o;
  o.segs = RidgeFilter(RansacLines(thin), hsv);
  o.thin = std::move(thin);
  o.white = std::move(white);
  return o;
}

struct SegFeat {
  double ang, rho, t0, t1, L, dx, dy;
};

SegFeat SegFeatures(const std::array<double, 4>& s) {
  double x1 = s[0], y1 = s[1], x2 = s[2], y2 = s[3];
  double dx = x2 - x1, dy = y2 - y1;
  double L = std::hypot(dx, dy);
  if (L == 0) L = 1e-6;
  dx /= L;
  dy /= L;
  double ang = std::fmod(std::atan2(dy, dx), kPi);
  if (ang < 0) ang += kPi;
  double nx = -dy, ny = dx;
  double rho = nx * x1 + ny * y1;
  if (rho < 0) rho = -rho;
  double t1 = dx * x1 + dy * y1, t2 = dx * x2 + dy * y2;
  return {ang, rho, std::min(t1, t2), std::max(t1, t2), L, dx, dy};
}

CourtLine RefitGroup(const std::vector<std::array<double, 4>>& segs,
                     const std::vector<int>& group,
                     const std::vector<SegFeat>& feats) {
  double sx = 0, sy = 0, sw = 0;
  for (int g : group) {
    double L = feats[g].L;
    sx += (segs[g][0] + segs[g][2]) * L;
    sy += (segs[g][1] + segs[g][3]) * L;
    sw += 2 * L;
  }
  double cx = sx / sw, cy = sy / sw;
  double e00 = 0, e01 = 0, e11 = 0;
  for (int g : group) {
    double L = feats[g].L;
    for (int e = 0; e < 2; ++e) {
      double ux = segs[g][2 * e] - cx, uy = segs[g][2 * e + 1] - cy;
      e00 += L * ux * ux;
      e01 += L * ux * uy;
      e11 += L * uy * uy;
    }
  }
  e00 /= sw;
  e01 /= sw;
  e11 /= sw;
  double val, vx, vy;
  num::Eigh2Top(e00, e01, e11, val, vx, vy);
  double nx = -vy, ny = vx;
  double c = -(nx * cx + ny * cy);
  double ang = std::fmod(std::atan2(vy, vx), kPi);
  if (ang < 0) ang += kPi;
  double tmin = 1e18, tmax = -1e18, tl = 0;
  for (int g : group) {
    tl += feats[g].L;
    for (int e = 0; e < 2; ++e) {
      double t = (segs[g][2 * e] - cx) * vx + (segs[g][2 * e + 1] - cy) * vy;
      tmin = std::min(tmin, t);
      tmax = std::max(tmax, t);
    }
  }
  CourtLine ln;
  ln.a = nx;
  ln.b = ny;
  ln.c = c;
  ln.angle = ang;
  ln.length = tl;
  ln.px = cx;
  ln.py = cy;
  ln.dx = vx;
  ln.dy = vy;
  ln.t0 = tmin;
  ln.t1 = tmax;
  return ln;
}

std::vector<CourtLine> MergeSegments(
    const std::vector<std::array<double, 4>>& segs) {
  std::vector<SegFeat> feats;
  for (auto& s : segs) feats.push_back(SegFeatures(s));
  std::vector<int> order(segs.size());
  std::iota(order.begin(), order.end(), 0);
  std::stable_sort(order.begin(), order.end(),
                   [&](int i, int j) { return feats[i].L > feats[j].L; });
  std::vector<char> used(segs.size(), 0);
  std::vector<CourtLine> lines;
  for (int i : order) {
    if (used[i]) continue;
    used[i] = 1;
    std::vector<int> group = {i};
    for (int j : order) {
      if (used[j]) continue;
      double da = std::fabs(feats[i].ang - feats[j].ang);
      da = std::min(da, kPi - da);
      if (da > 1.6 * kPi / 180 || std::fabs(feats[i].rho - feats[j].rho) > 6.0)
        continue;
      double t0i = 1e18, t1i = -1e18;
      for (int g : group) {
        t0i = std::min(t0i, feats[g].t0);
        t1i = std::max(t1i, feats[g].t1);
      }
      if (feats[j].t0 - t1i > 60.0 || t0i - feats[j].t1 > 60.0) continue;
      used[j] = 1;
      group.push_back(j);
    }
    lines.push_back(RefitGroup(segs, group, feats));
  }
  return lines;
}

std::pair<double, double> LineMid(const CourtLine& ln, double w, double h) {
  double cx = w / 2, cy = h / 2;
  double d = ln.a * cx + ln.b * cy + ln.c;
  return {cx - ln.a * d, cy - ln.b * d};
}

std::vector<CourtLine> DedupLines(std::vector<CourtLine> lines, double w,
                                  double h) {
  std::stable_sort(lines.begin(), lines.end(),
                   [](const CourtLine& a, const CourtLine& b) {
                     return a.length > b.length;
                   });
  std::vector<CourtLine> kept;
  for (auto& ln : lines) {
    bool dup = false;
    for (auto& k : kept) {
      double da = std::fabs(ln.angle - k.angle);
      da = std::min(da, kPi - da);
      if (da > 1.5 * kPi / 180) continue;
      auto [mx, my] = LineMid(k, w, h);
      if (std::fabs(ln.a * mx + ln.b * my + ln.c) < 5.0) {
        k.length += ln.length;
        dup = true;
        break;
      }
    }
    if (!dup) kept.push_back(ln);
  }
  return kept;
}

bool Intersect(const CourtLine& l1, const CourtLine& l2, double& x, double& y) {
  double det = l1.a * l2.b - l2.a * l1.b;
  if (std::fabs(det) < 1e-9) return false;
  x = (l1.b * l2.c - l2.b * l1.c) / det;
  y = (l2.a * l1.c - l1.a * l2.c) / det;
  return true;
}

void WorldOfPoint(const double H[9], double x, double y, double& wx,
                  double& wy) {
  double q0 = H[0] * x + H[1] * y + H[2];
  double q1 = H[3] * x + H[4] * y + H[5];
  double q2 = H[6] * x + H[7] * y + H[8];
  wx = q0 / q2;
  wy = q1 / q2;
}

}  // namespace

namespace {

// Least-squares homography (h33 = 1) from >= 4 correspondences.
bool DltHomography(const std::vector<std::array<double, 4>>& corr,
                   double H[9]) {
  // Unknowns h11..h32 (row-major, h33 = 1).
  double ata[64] = {0};
  double atb[8] = {0};
  for (auto& c : corr) {
    double x = c[0], y = c[1], wx = c[2], wy = c[3];
    double r1[8] = {x, y, 1, 0, 0, 0, -wx * x, -wx * y};
    double r2[8] = {0, 0, 0, x, y, 1, -wy * x, -wy * y};
    for (int a = 0; a < 8; ++a) {
      atb[a] += r1[a] * wx + r2[a] * wy;
      for (int b = 0; b < 8; ++b) ata[a * 8 + b] += r1[a] * r1[b] + r2[a] * r2[b];
    }
  }
  std::vector<double> A(ata, ata + 64), B(atb, atb + 8), X;
  if (!num::SolveN(A, B, 8, X)) return false;
  for (int i = 0; i < 8; ++i) H[i] = X[i];
  H[8] = 1.0;
  return true;
}

// RANSAC homography, threshold in WORLD units (mirrors findHomography).
bool RansacHomography(const std::vector<std::array<double, 4>>& corr,
                      double thresh, double H[9], std::vector<char>& inl,
                      std::mt19937& rng) {
  const int n = (int)corr.size();
  if (n < 4) return false;
  double bestH[9] = {0};
  int best_n = 0;
  std::vector<char> best_inl(n, 0), cur(n, 0);
  std::uniform_int_distribution<int> pick(0, n - 1);
  int iters = 1000;
  for (int it = 0; it < iters; ++it) {
    std::set<int> s;
    while ((int)s.size() < 4) s.insert(pick(rng));
    std::vector<std::array<double, 4>> sub;
    for (int i : s) sub.push_back(corr[i]);
    double Hc[9];
    if (!DltHomography(sub, Hc)) continue;
    int cnt = 0;
    for (int i = 0; i < n; ++i) {
      double wx, wy;
      WorldOfPoint(Hc, corr[i][0], corr[i][1], wx, wy);
      bool ok = std::hypot(wx - corr[i][2], wy - corr[i][3]) < thresh;
      cur[i] = ok;
      if (ok) cnt++;
    }
    if (cnt > best_n) {
      best_n = cnt;
      std::copy(Hc, Hc + 9, bestH);
      best_inl = cur;
      // Standard early exit (confidence 0.995).
      double w = (double)cnt / n;
      if (w > 0.999) break;
      double p_no = 1 - w * w * w * w;
      if (p_no < 1e-12) break;
      int need = (int)std::ceil(std::log(1 - 0.995) / std::log(p_no));
      iters = std::min(iters, std::max(it + 1, std::min(need, 1000)));
    }
  }
  if (best_n < 4) return false;
  std::vector<std::array<double, 4>> sub;
  for (int i = 0; i < n; ++i)
    if (best_inl[i]) sub.push_back(corr[i]);
  if (!DltHomography(sub, H)) return false;
  inl = best_inl;
  return true;
}

const double kAcrossY[5] = {-kHalfLen, -kServY, 0.0, kServY, kHalfLen};
const char* kAcrossName[5] = {"baseline-S", "service-S", "net", "service-N",
                              "baseline-N"};
const double kAlongX[5] = {-kHalfDbl, -kHalfSgl, 0.0, kHalfSgl, kHalfDbl};
const char* kAlongName[5] = {"doubles-W", "singles-W", "center", "singles-E",
                             "doubles-E"};

struct QuadFit {
  double H[9];
  double rms;
  std::vector<CourtKeypoint> kps;
  int n_inl;
};

bool FitFromQuad(int ac0, int ac1, int al0, int al1,
                 std::vector<CourtLine>& lines, const std::set<int>& across_ids,
                 const std::set<int>& along_ids, int w, int h, double y_near,
                 double y_far, bool has_net_y, double net_y, QuadFit& qf,
                 std::mt19937& rng) {
  double c[4][2];
  const int pairs[4][2] = {{ac0, al0}, {ac0, al1}, {ac1, al1}, {ac1, al0}};
  for (int i = 0; i < 4; ++i)
    if (!Intersect(lines[pairs[i][0]], lines[pairs[i][1]], c[i][0], c[i][1]))
      return false;
  double y0 = (c[0][1] + c[1][1]) / 2, y1 = (c[2][1] + c[3][1]) / 2;
  int far_ln = y0 < y1 ? ac0 : ac1;
  if (y_far == kHalfLen && has_net_y) {
    if (lines[far_ln].py > net_y + 12) return false;
  }
  // Reorder corners: near-left, near-right, far-right, far-left.
  double co[4][2];
  std::copy(&c[0][0], &c[0][0] + 8, &co[0][0]);
  if (y0 < y1) {  // c[0..1] are far -> rotate
    double t[4][2] = {{co[3][0], co[3][1]},
                      {co[2][0], co[2][1]},
                      {co[1][0], co[1][1]},
                      {co[0][0], co[0][1]}};
    std::copy(&t[0][0], &t[0][0] + 8, &co[0][0]);
  }
  if (co[0][0] > co[1][0]) {
    double t[4][2] = {{co[1][0], co[1][1]},
                      {co[0][0], co[0][1]},
                      {co[3][0], co[3][1]},
                      {co[2][0], co[2][1]}};
    std::copy(&t[0][0], &t[0][0] + 8, &co[0][0]);
  }
  const double wx[4] = {-kHalfDbl, kHalfDbl, kHalfDbl, -kHalfDbl};
  const double wy[4] = {-y_near, -y_near, y_far, y_far};
  std::vector<std::array<double, 4>> corr;
  for (int i = 0; i < 4; ++i) corr.push_back({co[i][0], co[i][1], wx[i], wy[i]});
  double H0[9];
  if (!DltHomography(corr, H0)) return false;

  std::map<int, std::string> roles;
  for (size_t li = 0; li < lines.size(); ++li) {
    bool is_ac = across_ids.count((int)li), is_al = along_ids.count((int)li);
    if (!is_ac && !is_al) continue;
    const CourtLine& ln = lines[li];
    double mnx = 1e18, mxx = -1e18, mny = 1e18, mxx2 = -1e18;
    std::vector<double> wxs, wys;
    for (int k = 0; k < 11; ++k) {
      double t = ln.t0 + (ln.t1 - ln.t0) * k / 10;
      double wxp, wyp;
      WorldOfPoint(H0, ln.px + ln.dx * t, ln.py + ln.dy * t, wxp, wyp);
      wxs.push_back(wxp);
      wys.push_back(wyp);
      mnx = std::min(mnx, wxp);
      mxx = std::max(mxx, wxp);
      mny = std::min(mny, wyp);
      mxx2 = std::max(mxx2, wyp);
    }
    (void)mny;
    (void)mxx2;
    bool use_across;
    if (is_ac && !is_al)
      use_across = true;
    else if (is_al && !is_ac)
      use_across = false;
    else
      // Dual-pooled: resolve by world shape under this seed H0. A true
      // sideline maps to near-constant x with wide y span (and vice versa
      // for a baseline), which distinguishes lines image angle cannot.
      use_across = (mxx - mnx) > (mxx2 - mny);
    if (use_across) {
      double v = num::Median(wys);
      if (mxx - mnx < 3.5) continue;
      // Short across fragments (weak far paint, stroke-edge latches) take
      // roles under foreshortening and lever the fit: their world span looks
      // wide while their pixel support is thin. Require seed-caliber pixel
      // length, like the across PairCandidates bar.
      if (ln.length < 250.0 * w / 1280) continue;
      int bi = 0;
      for (int i = 1; i < 5; ++i)
        if (std::fabs(kAcrossY[i] - v) < std::fabs(kAcrossY[bi] - v)) bi = i;
      if (std::fabs(kAcrossY[bi] - v) >= 1.4) continue;
      if (std::string(kAcrossName[bi]) == "baseline-N" && has_net_y &&
          ln.py > net_y + 12)
        continue;
      roles[(int)li] = kAcrossName[bi];
    } else {
      double v = num::Median(wxs);
      double span = mxx2 - mny;
      int bi = 0;
      for (int i = 1; i < 5; ++i)
        if (std::fabs(kAlongX[i] - v) < std::fabs(kAlongX[bi] - v)) bi = i;
      if (std::fabs(kAlongX[bi] - v) >= 1.2) continue;
      double need = std::string(kAlongName[bi]) == "center" ? 6.0 : 12.0;
      if (span < need) continue;
      roles[(int)li] = kAlongName[bi];
    }
  }
  // One line per role: keep the longest.
  std::vector<int> bylen(lines.size());
  std::iota(bylen.begin(), bylen.end(), 0);
  std::stable_sort(bylen.begin(), bylen.end(),
                   [&](int i, int j) { return lines[i].length > lines[j].length; });
  std::map<std::string, int> by_role;
  for (int i : bylen) {
    auto it = roles.find(i);
    if (it != roles.end() && !by_role.count(it->second)) by_role[it->second] = i;
  }
  for (size_t i = 0; i < lines.size(); ++i) {
    auto it = roles.find((int)i);
    std::string r = it == roles.end() ? "" : it->second;
    lines[i].role = (!r.empty() && by_role.count(r) && by_role[r] == (int)i) ? r : "";
  }
  auto role_axis = [](const std::string& r) -> char {
    if (r == "baseline-S" || r == "service-S" || r == "net" ||
        r == "service-N" || r == "baseline-N")
      return 'y';
    return 'x';
  };
  auto role_val = [](const std::string& r) -> double {
    for (int i = 0; i < 5; ++i)
      if (r == kAcrossName[i]) return kAcrossY[i];
    for (int i = 0; i < 5; ++i)
      if (r == kAlongName[i]) return kAlongX[i];
    return 0;
  };
  std::vector<CourtKeypoint> kps;
  for (auto& [ra, la] : by_role) {
    if (role_axis(ra) != 'y') continue;
    for (auto& [rb, lb] : by_role) {
      if (role_axis(rb) != 'x') continue;
      double x, y;
      if (!Intersect(lines[la], lines[lb], x, y)) continue;
      if (!(-0.05 * w <= x && x <= 1.05 * w && -0.05 * h <= y && y <= 1.05 * h))
        continue;
      kps.push_back({x, y, role_val(rb), role_val(ra)});
    }
  }
  if (kps.size() < 4) return false;
  std::vector<std::array<double, 4>> kc;
  for (auto& k : kps) kc.push_back({k.x, k.y, k.wx, k.wy});
  double H[9];
  std::vector<char> inl;
  if (!RansacHomography(kc, 0.25, H, inl, rng)) return false;
  double Hc[9];
  if (!num::Invert3(H, Hc)) return false;
  double se = 0;
  int nerr = 0;
  for (size_t i = 0; i < kps.size(); ++i) {
    if (!inl[i]) continue;
    double ix, iy;
    WorldOfPoint(Hc, kps[i].wx, kps[i].wy, ix, iy);
    se += (ix - kps[i].x) * (ix - kps[i].x) + (iy - kps[i].y) * (iy - kps[i].y);
    nerr++;
  }
  if (!nerr) return false;
  std::copy(H, H + 9, qf.H);
  qf.rms = std::sqrt(se / nerr);
  qf.kps = std::move(kps);
  qf.n_inl = nerr;
  return true;
}

double NetTapeY(const Bgr& hsv, bool& found) {
  int W = hsv.w, H = hsv.h;
  found = false;
  double best_y = 0;
  int best_run = 0;
  for (int y = (int)(H * 0.40); y < (int)(H * 0.55); ++y) {
    std::vector<int> idx;
    for (int x = 0; x < W; ++x) {
      int s = hsv.px[(y * W + x) * 3 + 1];
      int v = hsv.px[(y * W + x) * 3 + 2];
      if (s <= 70 && v >= 165) idx.push_back(x);
    }
    if ((int)idx.size() < 250) continue;
    int run = 1, best = 1;
    for (size_t i = 1; i < idx.size(); ++i) {
      if (idx[i] - idx[i - 1] > 6)
        run = 1;
      else
        run++;
      best = std::max(best, run);
    }
    if (best > best_run) {
      best_run = best;
      best_y = y;
      found = true;
    }
  }
  return best_y;
}

double LineBoundaryGap(const CourtLine& ln, const std::vector<float>& dt, int w,
                       int h) {
  double s = 0;
  int n = 0;
  for (int k = 0; k < 41; ++k) {
    double t = ln.t0 + (ln.t1 - ln.t0) * k / 40;
    int x = (int)(ln.px + ln.dx * t), y = (int)(ln.py + ln.dy * t);
    if (0 <= x && x < w && 0 <= y && y < h) {
      s += dt[y * w + x];
      n++;
    }
  }
  return n ? s / n : 1e9;
}

bool StepInside(double ptx, double pty, double qcx, double qcy,
                const Gray& interior, int w, int h, double step = 20.0) {
  double dx = qcx - ptx, dy = qcy - pty;
  double n = std::hypot(dx, dy);
  if (n < 1e-6) return false;
  int x = (int)(ptx + dx / n * step), y = (int)(pty + dy / n * step);
  return 0 <= x && x < w && 0 <= y && y < h && interior.px[y * w + x];
}

bool InteriorOk(int ac0, int ac1, int al0, int al1,
                const std::vector<CourtLine>& lines, double qcx, double qcy,
                const Gray& interior, int w, int h) {
  for (int li : {al0, al1}) {
    const CourtLine& ln = lines[li];
    double e0x = ln.px + ln.dx * ln.t0, e0y = ln.py + ln.dy * ln.t0;
    double e1x = ln.px + ln.dx * ln.t1, e1y = ln.py + ln.dy * ln.t1;
    double nx = e0y > e1y ? e0x : e1x, ny = e0y > e1y ? e0y : e1y;
    if (!StepInside(nx, ny, qcx, qcy, interior, w, h)) return false;
  }
  for (int li : {ac0, ac1}) {
    if (!StepInside(lines[li].px, lines[li].py, qcx, qcy, interior, w, h))
      return false;
  }
  return true;
}

std::vector<std::pair<int, int>> PairCandidates(const std::vector<int>& group,
                                                const std::vector<CourtLine>& lines,
                                                int w, double min_len = 150.0) {
  std::vector<int> cands = group;
  std::stable_sort(cands.begin(), cands.end(), [&](int i, int j) {
    return lines[i].length > lines[j].length;
  });
  if (cands.size() > 8) cands.resize(8);
  std::vector<std::pair<int, int>> pairs;
  for (size_t i = 0; i < cands.size(); ++i)
    for (size_t j = i + 1; j < cands.size(); ++j) {
      double m = std::min(lines[cands[i]].length, lines[cands[j]].length);
      if (m < min_len * w / 1280) continue;
      pairs.emplace_back(cands[i], cands[j]);
    }
  return pairs;
}

struct ModelLine {
  double x1, y1, x2, y2, wt;
};

const ModelLine kModelLines[7] = {
    {-5.485, -11.885, 5.485, -11.885, 2.0},
    {-5.485, 11.885, 5.485, 11.885, 2.0},
    {-5.485, -11.885, -5.485, 11.885, 2.0},
    {5.485, -11.885, 5.485, 11.885, 2.0},
    {-5.485, -6.40, 5.485, -6.40, 1.0},
    {-5.485, 6.40, 5.485, 6.40, 1.0},
    {0.0, -6.40, 0.0, 6.40, 0.7},
};

double ModelSupport(const double Hc[9], const Gray& white_dil,
                    const Gray& visible, bool strict_inner) {
  int W = white_dil.w, H = white_dil.h;
  double num = 0, den = 0;
  for (int idx = 0; idx < 7; ++idx) {
    const ModelLine& L = kModelLines[idx];
    double length = std::hypot(L.x2 - L.x1, L.y2 - L.y1);
    int n = std::max(8, (int)(length / 0.15));
    int tot = 0, hit = 0;
    for (int k = 0; k < n; ++k) {
      double t = n == 1 ? 0 : (double)k / (n - 1);
      double wx = L.x1 + (L.x2 - L.x1) * t, wy = L.y1 + (L.y2 - L.y1) * t;
      double q2 = Hc[6] * wx + Hc[7] * wy + Hc[8];
      if (std::fabs(q2) < 1e-9) continue;
      int ix = (int)((Hc[0] * wx + Hc[1] * wy + Hc[2]) / q2);
      int iy = (int)((Hc[3] * wx + Hc[4] * wy + Hc[5]) / q2);
      if (0 <= ix && ix < W && 0 <= iy && iy < H && visible.px[iy * W + ix]) {
        tot++;
        if (white_dil.px[iy * W + ix]) hit++;
      }
    }
    if (tot < 10) continue;
    double frac = (double)hit / tot;
    if (idx < 4 && frac < 0.15) return 0.0;
    if (strict_inner && idx >= 4 && frac < 0.08) return 0.0;
    num += L.wt * frac;
    den += L.wt;
  }
  return den ? num / den : 0.0;
}

// Minimum plausible image scale of the model court at its image-near end, in
// pixels per meter along each model axis. Seed quads built from adjacent
// parallel lines (e.g. doubles+singles sidelines as the across pair) can fit
// exactly and still pass support while stretching meters of court onto a few
// pixels; reject those on physical scale before scoring. True back-of-court
// fits measure 80+ px/m here, so the floor only kills absurd stretches.
constexpr double kMinNearPxPerM = 3.0;

bool NearCourtScaleOk(const double Hc[9]) {
  auto proj = [&](double x, double y, double& px, double& py) {
    double w = Hc[6] * x + Hc[7] * y + Hc[8];
    if (std::fabs(w) < 1e-9) return false;
    px = (Hc[0] * x + Hc[1] * y + Hc[2]) / w;
    py = (Hc[3] * x + Hc[4] * y + Hc[5]) / w;
    return std::isfinite(px) && std::isfinite(py);
  };
  double sx, sy, nx, ny;
  if (!proj(0, -kHalfLen, sx, sy) || !proj(0, kHalfLen, nx, ny)) return false;
  double yn = (sy > ny) ? -kHalfLen : kHalfLen;  // image-near end
  double inward = (yn < 0) ? 1.0 : -1.0;
  double x0x, x0y, x1x, x1y, y0x, y0y, y1x, y1y;
  if (!proj(-kHalfDbl, yn, x0x, x0y) || !proj(-kHalfDbl + 1.0, yn, x1x, x1y))
    return false;
  if (!proj(0, yn, y0x, y0y) || !proj(0, yn + inward, y1x, y1y)) return false;
  double sxm = std::hypot(x1x - x0x, x1y - x0y);
  double sym = std::hypot(y1x - y0x, y1y - y0y);
  return sxm >= kMinNearPxPerM && sym >= kMinNearPxPerM;
}

// The model court is a planar rectangle seen from outside/above it, so a
// valid homography must project its corners to a strictly convex quad with
// every corner in front of the camera (same-sign homogeneous w). Twisted
// seed quads (e.g. near/far across lines paired out of order) fit exactly
// and can still pass support while mapping the court to a bowtie; reject
// those on shape. Complements the scale floor, which misses twists.
bool CourtQuadConvex(const double Hc[9]) {
  double px[4], py[4];
  bool pos = false, neg = false;
  for (int i = 0; i < 4; ++i) {
    double x = (i == 0 || i == 3) ? -kHalfDbl : kHalfDbl;
    double y = (i < 2) ? -kHalfLen : kHalfLen;
    double w = Hc[6] * x + Hc[7] * y + Hc[8];
    if (std::fabs(w) < 1e-9) return false;
    if (w > 0)
      pos = true;
    else
      neg = true;
    px[i] = (Hc[0] * x + Hc[1] * y + Hc[2]) / w;
    py[i] = (Hc[3] * x + Hc[4] * y + Hc[5]) / w;
    if (!std::isfinite(px[i]) || !std::isfinite(py[i])) return false;
  }
  if (pos && neg) return false;
  double prev = 0;
  for (int i = 0; i < 4; ++i) {
    int j = (i + 1) % 4, k = (i + 2) % 4;
    double z = (px[j] - px[i]) * (py[k] - py[j]) -
               (py[j] - py[i]) * (px[k] - px[j]);
    if (z == 0) return false;
    if (i > 0 && (z > 0) != (prev > 0)) return false;
    prev = z;
  }
  return true;
}

struct SearchBest {
  bool found = false;
  double score = 0;
  QuadFit fit;
  double support = 0;
  std::map<int, std::string> roles;
};

bool SearchQuad(std::vector<CourtLine>& lines, const std::vector<int>& across,
                const std::vector<int>& along, int w, int h,
                const Gray& white_dil, const Gray& roi, const Gray& interior,
                const Gray& visible, bool has_net_y, double net_y,
                bool strict_inner, SearchBest& best, std::mt19937& rng) {
  std::set<int> across_ids(across.begin(), across.end());
  std::set<int> along_ids(along.begin(), along.end());
  auto ac_pairs = PairCandidates(across, lines, w, 250.0);
  auto al_pairs = PairCandidates(along, lines, w);
  if (ac_pairs.empty() || al_pairs.empty()) return false;
  // Boundary distance map from the strict ROI.
  Gray edge{w, h, std::vector<uint8_t>(w * h)};
  Gray dil = img::Dilate(roi, 3), ero = img::Erode(roi, 3);
  Gray bg{w, h, std::vector<uint8_t>(w * h)};
  for (int i = 0; i < w * h; ++i) {
    edge.px[i] = dil.px[i] - ero.px[i];
    bg.px[i] = 255 - edge.px[i];
  }
  std::vector<float> dt = img::DistanceTransform(bg);
  const double ycomb[5][2] = {{11.885, 11.885},
                              {11.885, -6.40},
                              {11.885, 6.40},
                              {6.40, 6.40},
                              {6.40, 11.885}};
  for (auto [ac0, ac1] : ac_pairs) {
    int near_ac = lines[ac0].py > lines[ac1].py ? ac0 : ac1;
    if (LineBoundaryGap(lines[near_ac], dt, w, h) > 12.0) continue;
    for (auto [al0, al1] : al_pairs) {
      double g = std::max({LineBoundaryGap(lines[near_ac], dt, w, h),
                           LineBoundaryGap(lines[al0], dt, w, h),
                           LineBoundaryGap(lines[al1], dt, w, h)});
      if (g > 12.0) continue;
      double c[4][2];
      const int pr[4][2] = {{ac0, al0}, {ac0, al1}, {ac1, al1}, {ac1, al0}};
      bool ok = true;
      for (int i = 0; i < 4; ++i)
        if (!Intersect(lines[pr[i][0]], lines[pr[i][1]], c[i][0], c[i][1]))
          ok = false;
      if (!ok) continue;
      double qcx = (c[0][0] + c[1][0] + c[2][0] + c[3][0]) / 4;
      double qcy = (c[0][1] + c[1][1] + c[2][1] + c[3][1]) / 4;
      if (!InteriorOk(ac0, ac1, al0, al1, lines, qcx, qcy, interior, w, h))
        continue;
      for (auto& yc : ycomb) {
        for (auto& ln : lines) ln.role = "";
        QuadFit qf;
        if (!FitFromQuad(ac0, ac1, al0, al1, lines, across_ids, along_ids, w,
                         h, yc[0], yc[1], has_net_y, net_y, qf, rng))
          continue;
        // Four points determine a homography but never verify it: swapped
        // seed quads fit exactly and can still pass support. Require a
        // redundant (5th) keypoint so the geometry confirms the labels.
        if (qf.n_inl < 5) continue;
        double Hc[9];
        if (!num::Invert3(qf.H, Hc)) continue;
        if (!NearCourtScaleOk(Hc)) continue;
        if (!CourtQuadConvex(Hc)) continue;
        double support = ModelSupport(Hc, white_dil, visible, strict_inner);
        std::set<std::string> roles;
        for (auto& ln : lines)
          if (!ln.role.empty()) roles.insert(ln.role);
        int missing = 0;
        for (auto r : {"baseline-S", "baseline-N", "doubles-W", "doubles-E"})
          if (!roles.count(r)) missing++;
        double score =
            4.0 * support + qf.n_inl / 4.0 - qf.rms / 8.0 - 1.5 * missing;
        if (!best.found || score > best.score) {
          best.found = true;
          best.score = score;
          best.fit = qf;
          best.support = support;
          best.roles.clear();
          for (size_t i = 0; i < lines.size(); ++i)
            best.roles[(int)i] = lines[i].role;
        }
      }
    }
  }
  if (!best.found) return false;
  for (size_t i = 0; i < lines.size(); ++i) lines[i].role = best.roles[(int)i];
  return true;
}

CourtCalib FitLines(std::vector<std::array<double, 4>> segs,
                    const Gray& white_dil, const Gray& roi,
                    const Gray& interior, const Gray& visible, bool has_net_y,
                    double net_y, int w, int h, bool strict_inner,
                    std::mt19937& rng) {
  if (segs.size() < 6)
    throw CourtError("only " + std::to_string(segs.size()) +
                     " line segments found");
  std::vector<CourtLine> lines = DedupLines(MergeSegments(segs), w, h);
  std::vector<int> long_idx;
  for (size_t i = 0; i < lines.size(); ++i)
    if (lines[i].length > 120 * w / 1280) long_idx.push_back((int)i);
  // NOTE: across/along store indices into `lines` (same line OBJECTS as
  // Python, where long_lines aliases the same CourtLine instances).
  std::vector<int> pool_in_lines;
  if ((int)long_idx.size() < 4) {
    std::vector<int> idx(lines.size());
    std::iota(idx.begin(), idx.end(), 0);
    std::stable_sort(idx.begin(), idx.end(), [&](int i, int j) {
      return lines[i].length > lines[j].length;
    });
    size_t take = std::max<size_t>(4, lines.size());
    if (take > idx.size()) take = idx.size();
    for (size_t i = 0; i < take; ++i) pool_in_lines.push_back(idx[i]);
  } else {
    pool_in_lines = long_idx;
  }
  std::vector<int> across, along;
  for (int i : pool_in_lines) {
    double a = std::fmod(lines[i].angle, kPi);
    if (a < 0) a += kPi;
    double na = std::fmod(-lines[i].angle, kPi);
    if (na < 0) na += kPi;
    if (std::min(a, na) < 25.0 * kPi / 180) across.push_back(i);
    // Along takes every pool line: from a rotated back-of-court view true
    // sidelines run near-horizontal (image angle alone cannot assign axes).
    // Dual-pooled lines are resolved by their world shape under each seed H0
    // in role assignment below, so widening here adds candidates, not roles.
    along.push_back(i);
  }
  if (across.empty() || along.empty())
    throw CourtError("orientation split failed");
  SearchBest best;
  if (!SearchQuad(lines, across, along, w, h, white_dil, roi, interior,
                  visible, has_net_y, net_y, strict_inner, best, rng))
    throw CourtError("no court quad verified against the line model");
  if (best.fit.n_inl < 4 || !std::isfinite(best.fit.rms) ||
      best.fit.rms > 8.0 || best.support < 0.30)
    throw CourtError("court fit too weak");
  CourtCalib out;
  std::copy(best.fit.H, best.fit.H + 9, out.h_img2court);
  if (!num::Invert3(out.h_img2court, out.h_court2img))
    throw CourtError("singular homography");
  out.keypoints = best.fit.kps;
  out.lines = lines;
  out.rms_px = best.fit.rms;
  out.support = best.support;
  return out;
}

}  // namespace

CourtCalib DetectCourt(const uint8_t* bgr, int w, int h) {
  Bgr frame{w, h, std::vector<uint8_t>(bgr, bgr + w * h * 3)};
  Bgr hsv = img::BgrToHsv(frame);
  auto [roi, roi_strict] = PurpleRoi(hsv);
  if (roi.w == 0) throw CourtError("no court surface found");
  WhiteOut wo = WhiteSegments(hsv, roi);
  Gray white_dil = img::Dilate(wo.white, 3);
  Gray pv = PurpleVote(hsv);
  Gray interior = pv;
  Gray visible{w, h, std::vector<uint8_t>(w * h)};
  for (int i = 0; i < w * h; ++i)
    visible.px[i] = hsv.px[3 * i + 2] >= 100 ? 255 : 0;
  bool has_net = false;
  double net_y = NetTapeY(hsv, has_net);
  std::mt19937 rng(7);
  return FitLines(wo.segs, white_dil, roi_strict, interior, visible, has_net,
                  net_y, w, h, true, rng);
}

CourtCalib CalibrateFrames(const std::vector<const uint8_t*>& bgrs, int w,
                           int h) {
  if (bgrs.empty()) throw CourtError("no frames to calibrate from");
  std::vector<Bgr> frames;
  for (auto* p : bgrs)
    frames.push_back({w, h, std::vector<uint8_t>(p, p + w * h * 3)});
  Bgr med = img::MedianBackground(frames);
  // Best verified fit wins. The median erases players but can dilute thin
  // lines below the white threshold (no seed pair left); single frames keep
  // full-bright paint but may be occluded. Each covers the other's failure.
  std::vector<const uint8_t*> cands;
  cands.push_back(med.px.data());
  for (auto& f : frames) cands.push_back(f.px.data());
  bool have = false;
  CourtCalib best;
  std::string first_err = "no court quad verified against the line model";
  bool err_set = false;
  for (auto* img : cands) {
    try {
      CourtCalib c = DetectCourt(img, w, h);
      if (!have || c.support > best.support ||
          (c.support == best.support &&
           (c.keypoints.size() > best.keypoints.size() ||
            (c.keypoints.size() == best.keypoints.size() &&
             c.rms_px < best.rms_px)))) {
        best = c;
        have = true;
      }
    } catch (const CourtError& e) {
      if (!err_set) {
        first_err = e.what();
        err_set = true;
      }
    }
  }
  if (!have) throw CourtError(first_err);
  return best;
}

}  // namespace tennis
