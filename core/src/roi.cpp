#include "tennis/roi.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "tennis/img.hpp"

namespace tennis {

RoiFound RoiFindBall(const uint8_t* prev, const uint8_t* curr,
                     const uint8_t* next, int w, int h, double px, double py,
                     double radius) {
  RoiFound none;
  if (!prev || !curr || !next || w < 8 || h < 8 || radius < 8) return none;
  const bool dbg = std::getenv("TENNIS_ROI_DEBUG") != nullptr;
  int R = (int)radius;
  int x0 = std::max(0, (int)std::floor(px - R));
  int y0 = std::max(0, (int)std::floor(py - R));
  int x1 = std::min(w, (int)std::ceil(px + R));
  int y1 = std::min(h, (int)std::ceil(py + R));
  int cw = x1 - x0, ch = y1 - y0;
  if (cw < 8 || ch < 8) return none;
  // Per-pixel one-sided differences (kept for the fast/slow cue).
  std::vector<uint8_t> d1((size_t)cw * ch), d2((size_t)cw * ch);
  for (int y = 0; y < ch; ++y) {
    const uint8_t* pr = prev + (size_t)(y0 + y) * w + x0;
    const uint8_t* cr = curr + (size_t)(y0 + y) * w + x0;
    const uint8_t* nx = next + (size_t)(y0 + y) * w + x0;
    for (int x = 0; x < cw; ++x) {
      d1[(size_t)y * cw + x] =
          (uint8_t)std::min(255, std::abs((int)cr[x] - pr[x]));
      d2[(size_t)y * cw + x] =
          (uint8_t)std::min(255, std::abs((int)nx[x] - cr[x]));
    }
  }
  // Motion + brightness mask over the crop.
  std::vector<uint8_t> mask((size_t)cw * ch, 0);
  for (size_t i = 0; i < mask.size(); ++i)
    if ((int)d1[i] + d2[i] >= 40 && curr[(size_t)(y0 + i / cw) * w + x0 + i % cw] >= 150)
      mask[i] = 255;
  // Player mask: lenient motion, large components dilated — the ball is
  // never trusted next to a person (a lost volley-contact frame bridges
  // trivially; a shirt-lock poisons the track).
  std::vector<uint8_t> player((size_t)cw * ch, 0);
  {
    std::vector<int> lab((size_t)cw * ch, 0);
    std::vector<int> areas = {0};
    std::vector<int> st;
    for (int y = 0; y < ch; ++y)
      for (int x = 0; x < cw; ++x) {
        size_t i = (size_t)y * cw + x;
        if ((int)d1[i] + d2[i] < 25 || lab[i]) continue;
        int L = (int)areas.size();
        areas.push_back(0);
        lab[i] = L;
        st.clear();
        st.push_back((int)i);
        while (!st.empty()) {
          int j = st.back();
          st.pop_back();
          ++areas[L];
          int jx = j % cw, jy = j / cw;
          for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) {
              if (!dx && !dy) continue;
              int ax = jx + dx, ay = jy + dy;
              if (ax < 0 || ay < 0 || ax >= cw || ay >= ch) continue;
              size_t k = (size_t)ay * cw + ax;
              if ((int)d1[k] + d2[k] >= 25 && !lab[k]) {
                lab[k] = L;
                st.push_back((int)k);
              }
            }
        }
      }
    img::Gray big{cw, ch, std::vector<uint8_t>((size_t)cw * ch, 0)};
    for (size_t i = 0; i < lab.size(); ++i)
      if (lab[i] && areas[lab[i]] > 150) big.px[i] = 255;
    player = img::Dilate(big, 51).px;  // ~25px exclusion halo
  }
  // Bright-region map for the held-ball test: connected components
  // of curr >= 140 with area + bbox + mean.
  std::vector<int> blab((size_t)cw * ch, 0);
  std::vector<int> barea = {0};
  std::vector<double> bsum = {0};
  std::vector<int> bx0 = {0}, by0 = {0}, bx1 = {0}, by1 = {0};
  {
    std::vector<int> st;
    for (int y = 0; y < ch; ++y)
      for (int x = 0; x < cw; ++x) {
        size_t i = (size_t)y * cw + x;
        double v0 = curr[(size_t)(y0 + y) * w + x0 + x];
        if (v0 < 140 || blab[i]) continue;
        int L = (int)barea.size();
        barea.push_back(0);
        bsum.push_back(0);
        bx0.push_back(x);
        by0.push_back(y);
        bx1.push_back(x);
        by1.push_back(y);
        blab[i] = L;
        st.clear();
        st.push_back((int)i);
        while (!st.empty()) {
          int j = st.back();
          st.pop_back();
          ++barea[L];
          int jx = j % cw, jy = j / cw;
          bsum[L] += curr[(size_t)(y0 + jy) * w + x0 + jx];
          bx0[L] = std::min(bx0[L], jx);
          by0[L] = std::min(by0[L], jy);
          bx1[L] = std::max(bx1[L], jx);
          by1[L] = std::max(by1[L], jy);
          for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) {
              if (!dx && !dy) continue;
              int ax = jx + dx, ay = jy + dy;
              if (ax < 0 || ay < 0 || ax >= cw || ay >= ch) continue;
              size_t k = (size_t)ay * cw + ax;
              if (curr[(size_t)(y0 + ay) * w + x0 + ax] >= 140 && !blab[k]) {
                blab[k] = L;
                st.push_back((int)k);
              }
            }
        }
      }
  }
  // 8-connected components, row-major.
  std::vector<int> lab((size_t)cw * ch, 0);
  std::vector<int> stack;
  RoiFound best;
  double best_conf = 0.35;  // acceptance floor
  double accept = radius * 0.75;
  int nlab = 0;
  for (int y = 0; y < ch; ++y)
    for (int x = 0; x < cw; ++x) {
      size_t i = (size_t)y * cw + x;
      if (!mask[i] || lab[i]) continue;
      lab[i] = ++nlab;
      stack.clear();
      stack.push_back((int)i);
      int area = 0, xmin = cw, xmax = -1, ymin = ch, ymax = -1;
      double wsum = 0, bx = 0, by = 0;
      std::vector<int> pix;
      pix.reserve(64);
      while (!stack.empty()) {
        int j = stack.back();
        stack.pop_back();
        int jx = j % cw, jy = j / cw;
        ++area;
        pix.push_back(j);
        xmin = std::min(xmin, jx);
        xmax = std::max(xmax, jx);
        ymin = std::min(ymin, jy);
        ymax = std::max(ymax, jy);
        double b = curr[(size_t)(y0 + jy) * w + x0 + jx];
        wsum += b;
        bx += (x0 + jx) * b;
        by += (y0 + jy) * b;
        for (int dy = -1; dy <= 1; ++dy)
          for (int dx = -1; dx <= 1; ++dx) {
            if (!dx && !dy) continue;
            int nx = jx + dx, ny = jy + dy;
            if (nx < 0 || ny < 0 || nx >= cw || ny >= ch) continue;
            size_t k = (size_t)ny * cw + nx;
            if (mask[k] && !lab[k]) {
              lab[k] = nlab;
              stack.push_back((int)k);
            }
          }
      }
      // Area cap: near-court balls under strided detection reach ~70px
      // of motion blur (measured 67px at a real bounce bottom); player
      // torsos are 600px+. The cap sits between, with margin both ways.
      if (area < 2 || area > 120 || wsum <= 0) continue;
      int bw = xmax - xmin + 1, bh = ymax - ymin + 1;
      double fill = (double)area / (bw * bh);
      double elong = (double)std::max(bw, bh) / std::max(1, std::min(bw, bh));
      if (fill < 0.30 || elong > 3.5) continue;
      double cx = bx / wsum, cy = by / wsum;
      double d = std::hypot(cx - px, cy - py);
      // sep ~= per-frame displacement, from the two one-sided
      // difference centroids (computed before the vetoes: the player
      // bypass needs it).
      double sep = 0.0;
      {
        int wx0 = std::max(0, xmin - 20), wx1 = std::min(cw - 1, xmax + 20);
        int wy0 = std::max(0, ymin - 20), wy1 = std::min(ch - 1, ymax + 20);
        double s1 = 0, x1 = 0, y1 = 0, s2 = 0, x2 = 0, y2 = 0;
        for (int yy = wy0; yy <= wy1; ++yy)
          for (int xx = wx0; xx <= wx1; ++xx) {
            size_t k = (size_t)yy * cw + xx;
            if (d1[k] >= 25) {
              s1 += d1[k];
              x1 += xx * d1[k];
              y1 += yy * d1[k];
            }
            if (d2[k] >= 25) {
              s2 += d2[k];
              x2 += xx * d2[k];
              y2 += yy * d2[k];
            }
          }
        if (s1 > 0 && s2 > 0)
          sep = std::hypot(x1 / s1 - x2 / s2, y1 / s1 - y2 / s2);
      }
      // Never trust a blob next to a person — unless it is a fast
      // coherent ball the track predicts: small, moving, and close
      // to the prediction. Shimmer (slow) stays vetoed, so tracks
      // on shirts keep coasting through instead of locking.
      int ccx = std::min(cw - 1, std::max(0, (int)std::round(cx - x0)));
      int ccy = std::min(ch - 1, std::max(0, (int)std::round(cy - y0)));
      bool in_player = player[(size_t)ccy * cw + ccx] != 0;
      double rs = w / 1280.0;
      bool bypass = in_player && d <= 25.0 * rs && area <= 60 * rs * rs &&
                    sep >= 3.0 * rs;
      if (dbg)
        std::fprintf(stderr,
                     "  blob area=%d cx=%.1f cy=%.1f d=%.1f fill=%.2f "
                     "elong=%.2f player=%d sep=%.2f%s",
                     area, cx, cy, d, fill, elong, (int)in_player, sep,
                     (in_player && bypass) ? " veto-bypass" : "");
      if (in_player && !bypass) {
        if (dbg) std::fprintf(stderr, " REJECT player\n");
        continue;
      }
      if (elong > 3.0 && sep < 3.0) {
        if (dbg) std::fprintf(stderr, " REJECT smear\n");
        continue;
      }
      // Held-ball test: nearly stopped (sep < 1.25px/frame) while
      // touching a big bright region that stands out = shirt shimmer
      // or a held ball — never a live ball (apex/rolling/line/skylight
      // cases are all exempt by context or speed).
      {
        int bl = 0;
        for (int j : pix)
          if (blab[j]) {
            bl = blab[j];
            break;
          }
        bool held = false;
        if (bl && sep < 1.25) {
          int ba = barea[bl];
          int thin =
              std::min(bx1[bl] - bx0[bl] + 1, by1[bl] - by0[bl] + 1);
          if (ba > 250 && thin > 12) {
            int rx0 = std::max(0, bx0[bl] - 8),
                rx1 = std::min(cw - 1, bx1[bl] + 8);
            int ry0 = std::max(0, by0[bl] - 8),
                ry1 = std::min(ch - 1, by1[bl] + 8);
            double rs = 0;
            int rn = 0;
            for (int yy = ry0; yy <= ry1; ++yy)
              for (int xx = rx0; xx <= rx1; ++xx) {
                size_t k = (size_t)yy * cw + xx;
                if (blab[k] == bl) continue;
                rs += curr[(size_t)(y0 + yy) * w + x0 + xx];
                ++rn;
              }
            if (rn > 0 && bsum[bl] / ba - rs / rn > 40) held = true;
          }
        }
        if (held) {
          if (dbg) std::fprintf(stderr, " REJECT held\n");
          continue;
        }
      }
      if (dbg) std::fprintf(stderr, " keep\n");
      d = std::hypot(cx - px, cy - py);
      if (d > accept) continue;
      double prox = 1.0 - d / accept;
      double size =
          area <= 40 ? 1.0 : 1.0 - 0.4 * std::min(1.0, (area - 40) / 80.0);
      double bright = std::min(1.0, (wsum / area - 150) / 60.0);
      bright = std::max(0.0, bright);
      double conf = 0.5 * prox + 0.3 * size + 0.2 * (0.35 + 0.65 * bright);
      if (conf > best_conf) {
        best_conf = conf;
        best.found = true;
        best.x = cx;
        best.y = cy;
        best.conf = std::min(1.0, conf);
      }
    }
  return best;
}

}  // namespace tennis
