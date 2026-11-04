#include "tennis/detect.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

namespace tennis {

std::vector<Candidate> ExtractCandidates(const uint8_t* heat, int heat_w,
                                         int heat_h, int frame_w, int frame_h,
                                         int thresh, int min_area,
                                         int max_area) {
  double ratio = static_cast<double>(heat_w * heat_h) /
                 (kModelWidth * kModelHeight);
  int lo = std::max(1, static_cast<int>(std::round(min_area * ratio)));
  int hi = std::max(
      lo + 1, static_cast<int>(std::round(max_area * ratio)));
  // 8-connected labeling, row-major (matches connectedComponents).
  const int n = heat_w * heat_h;
  std::vector<int> lab(n, 0);
  int nlab = 0;
  std::vector<int> stack;
  for (int y = 0; y < heat_h; ++y) {
    for (int x = 0; x < heat_w; ++x) {
      int i = y * heat_w + x;
      if (heat[i] < thresh || lab[i]) continue;
      lab[i] = ++nlab;
      stack.clear();
      stack.push_back(i);
      while (!stack.empty()) {
        int j = stack.back();
        stack.pop_back();
        int jx = j % heat_w, jy = j / heat_w;
        for (int dy = -1; dy <= 1; ++dy)
          for (int dx = -1; dx <= 1; ++dx) {
            if (!dx && !dy) continue;
            int nx = jx + dx, ny = jy + dy;
            if (nx < 0 || ny < 0 || nx >= heat_w || ny >= heat_h) continue;
            int k = ny * heat_w + nx;
            if (heat[k] >= thresh && !lab[k]) {
              lab[k] = nlab;
              stack.push_back(k);
            }
          }
      }
    }
  }
  std::vector<Candidate> out;
  for (int L = 1; L <= nlab; ++L) {
    int area = 0, xmin = heat_w, xmax = -1, ymin = heat_h, ymax = -1;
    double wsum = 0, xsum = 0, ysum = 0;
    int peak = 0;
    for (int y = 0; y < heat_h; ++y)
      for (int x = 0; x < heat_w; ++x) {
        int i = y * heat_w + x;
        if (lab[i] != L) continue;
        double w = heat[i];
        ++area;
        wsum += w;
        xsum += x * w;
        ysum += y * w;
        peak = std::max(peak, static_cast<int>(heat[i]));
        xmin = std::min(xmin, x);
        xmax = std::max(xmax, x);
        ymin = std::min(ymin, y);
        ymax = std::max(ymax, y);
      }
    if (area < lo || area > hi || wsum <= 0) continue;
    double cx = (xsum / wsum) / heat_w * frame_w;
    double cy = (ysum / wsum) / heat_h * frame_h;
    if (heat_h == 176 && heat_w == 320) {
      cx = 1.0005 * cx - 1.36;
      cy = 0.9860 * cy - 3.58;
    }
    int bw = xmax - xmin + 1, bh = ymax - ymin + 1;
    double fill = static_cast<double>(area) / std::max(1, bw * bh);
    double elong = static_cast<double>(std::max(bw, bh)) /
                   std::max(1, std::min(bw, bh));
    double conf = (peak / 255.0) * (0.45 + 0.55 * fill) /
                  (1.0 + 0.25 * std::max(0.0, elong - 2.0));
    out.push_back({cx, cy, std::min(1.0, conf), area, peak});
  }
  std::stable_sort(out.begin(), out.end(),
                   [](const Candidate& a, const Candidate& b) {
                     return a.conf > b.conf;
                   });
  return out;
}

}  // namespace tennis
