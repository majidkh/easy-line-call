#include "tennis/img.hpp"

#include <algorithm>
#include <cmath>
#include <deque>

namespace tennis {
namespace img {

Bgr BgrToHsv(const Bgr& bgr) {
  Bgr out{bgr.w, bgr.h, std::vector<uint8_t>(bgr.px.size())};
  const int n = bgr.w * bgr.h;
  for (int i = 0; i < n; ++i) {
    double b = bgr.px[3 * i], g = bgr.px[3 * i + 1], r = bgr.px[3 * i + 2];
    double mx = std::max({r, g, b}), mn = std::min({r, g, b});
    double df = mx - mn;
    double h = 0;
    if (df > 0) {
      if (mx == r)
        h = 60 * std::fmod((g - b) / df, 6.0);
      else if (mx == g)
        h = 60 * ((b - r) / df + 2.0);
      else
        h = 60 * ((r - g) / df + 4.0);
      if (h < 0) h += 360;
    }
    double s = mx > 0 ? df / mx : 0;
    out.px[3 * i] = static_cast<uint8_t>(std::round(h / 2));  // 0..179
    out.px[3 * i + 1] = static_cast<uint8_t>(std::round(s * 255));
    out.px[3 * i + 2] = static_cast<uint8_t>(std::round(mx));
  }
  return out;
}

Gray InRange(const Bgr& hsv, const uint8_t lo[3], const uint8_t hi[3]) {
  Gray out{hsv.w, hsv.h, std::vector<uint8_t>(hsv.w * hsv.h)};
  const int n = hsv.w * hsv.h;
  for (int i = 0; i < n; ++i) {
    bool ok = true;
    for (int c = 0; c < 3; ++c) {
      uint8_t v = hsv.px[3 * i + c];
      if (v < lo[c] || v > hi[c]) {
        ok = false;
        break;
      }
    }
    out.px[i] = ok ? 255 : 0;
  }
  return out;
}

namespace {

// 1-D sliding min/max with replicate border (deque, exact).
void SlideMinMax(const uint8_t* in, uint8_t* out, int n, int k, bool is_max) {
  int r = k / 2;
  std::deque<int> dq;  // indices into the virtually bordered line
  auto at = [&](int i) -> uint8_t {
    i = i < 0 ? 0 : (i >= n ? n - 1 : i);
    return in[i];
  };
  for (int i = -r; i < n + r + 1; ++i) {
    uint8_t v = at(i);
    while (!dq.empty()) {
      uint8_t w = at(dq.back());
      if (is_max ? (w <= v) : (w >= v))
        dq.pop_back();
      else
        break;
    }
    dq.push_back(i);
    if (i - r >= 0 && i - r < n) {
      while (dq.front() < i - 2 * r) dq.pop_front();
      out[i - r] = at(dq.front());
    }
  }
}

Gray MorphOp(const Gray& g, int k, bool is_max) {
  Gray tmp{g.w, g.h, std::vector<uint8_t>(g.px.size())};
  Gray out{g.w, g.h, std::vector<uint8_t>(g.px.size())};
  std::vector<uint8_t> line(std::max(g.w, g.h)), res(std::max(g.w, g.h));
  for (int y = 0; y < g.h; ++y) {
    SlideMinMax(&g.px[y * g.w], &tmp.px[y * g.w], g.w, k, is_max);
  }
  for (int x = 0; x < g.w; ++x) {
    for (int y = 0; y < g.h; ++y) line[y] = tmp.px[y * g.w + x];
    SlideMinMax(line.data(), res.data(), g.h, k, is_max);
    for (int y = 0; y < g.h; ++y) out.px[y * g.w + x] = res[y];
  }
  return out;
}

}  // namespace

Gray Dilate(const Gray& g, int k) { return MorphOp(g, k, true); }
Gray Erode(const Gray& g, int k) { return MorphOp(g, k, false); }

Gray MorphClose(const Gray& g, int k) {
  return MorphOp(MorphOp(g, k, true), k, false);
}

void ConnectedComponents(const Gray& g, std::vector<int>& labels,
                         std::vector<int>& areas) {
  const int n = g.w * g.h;
  labels.assign(n, 0);
  areas = {0};
  std::vector<int> stack;
  for (int y = 0; y < g.h; ++y)
    for (int x = 0; x < g.w; ++x) {
      int i = y * g.w + x;
      if (!g.px[i] || labels[i]) continue;
      int L = (int)areas.size();
      areas.push_back(0);
      labels[i] = L;
      stack.clear();
      stack.push_back(i);
      while (!stack.empty()) {
        int j = stack.back();
        stack.pop_back();
        ++areas[L];
        int jx = j % g.w, jy = j / g.w;
        for (int dy = -1; dy <= 1; ++dy)
          for (int dx = -1; dx <= 1; ++dx) {
            if (!dx && !dy) continue;
            int nx = jx + dx, ny = jy + dy;
            if (nx < 0 || ny < 0 || nx >= g.w || ny >= g.h) continue;
            int k = ny * g.w + nx;
            if (g.px[k] && !labels[k]) {
              labels[k] = L;
              stack.push_back(k);
            }
          }
      }
    }
}

Gray MedianBlur21(const Gray& g) {
  // Huang sliding-histogram median, replicate border.
  const int k = 21, r = k / 2, W = g.w, H = g.h;
  Gray out{W, H, std::vector<uint8_t>(W * H)};
  auto at = [&](int x, int y) -> uint8_t {
    x = x < 0 ? 0 : (x >= W ? W - 1 : x);
    y = y < 0 ? 0 : (y >= H ? H - 1 : y);
    return g.px[y * W + x];
  };
  const int need = (k * k + 1) / 2;
  for (int y = 0; y < H; ++y) {
    int hist[256] = {0};
    for (int dy = -r; dy <= r; ++dy)
      for (int dx = -r; dx <= r; ++dx) ++hist[at(dx, y + dy)];
    for (int x = 0; x < W; ++x) {
      if (x > 0) {
        for (int dy = -r; dy <= r; ++dy) {
          --hist[at(x - r - 1, y + dy)];
          ++hist[at(x + r, y + dy)];
        }
      }
      // Fresh seek per pixel (bounded 256-step scan; calibration is
      // one-shot so clarity beats incremental bookkeeping).
      int cnt = 0, med = 0;
      for (; med < 256; ++med) {
        cnt += hist[med];
        if (cnt >= need) break;
      }
      out.px[y * W + x] = (uint8_t)med;
    }
  }
  return out;
}

std::vector<float> BoxMean13(const std::vector<float>& f, int w, int h) {
  // Integral image over a reflect101-bordered copy.
  const int k = 13, r = k / 2;
  const int W = w + 2 * r, H = h + 2 * r;
  auto at = [&](int x, int y) -> double {
    // reflect101 source mapping
    int sx = x < 0 ? -x : (x >= w ? 2 * w - 2 - x : x);
    int sy = y < 0 ? -y : (y >= h ? 2 * h - 2 - y : y);
    sx = sx < 0 ? 0 : (sx >= w ? w - 1 : sx);
    sy = sy < 0 ? 0 : (sy >= h ? h - 1 : sy);
    return f[sy * w + sx];
  };
  std::vector<double> sat((W + 1) * (H + 1), 0.0);
  for (int y = 0; y < H; ++y) {
    double row = 0;
    for (int x = 0; x < W; ++x) {
      row += at(x - r, y - r);
      sat[(y + 1) * (W + 1) + x + 1] = sat[y * (W + 1) + x + 1] + row;
    }
  }
  std::vector<float> out(w * h);
  const double area = k * k;
  for (int y = 0; y < h; ++y)
    for (int x = 0; x < w; ++x) {
      double s = sat[(y + k) * (W + 1) + x + k] - sat[(y + k) * (W + 1) + x] -
                 sat[y * (W + 1) + x + k] + sat[y * (W + 1) + x];
      out[y * w + x] = (float)(s / area);
    }
  return out;
}

Bgr MedianBackground(const std::vector<Bgr>& frames) {
  int W = frames[0].w, H = frames[0].h;
  Bgr out{W, H, std::vector<uint8_t>(W * H * 3)};
  std::vector<uint8_t> vals;
  vals.reserve(frames.size());
  for (int i = 0; i < W * H * 3; ++i) {
    vals.clear();
    for (const auto& f : frames) vals.push_back(f.px[i]);
    std::sort(vals.begin(), vals.end());
    size_t n = vals.size();
    double m = n % 2 ? vals[n / 2] : (vals[n / 2 - 1] + vals[n / 2]) / 2.0;
    out.px[i] = static_cast<uint8_t>(m);  // truncate, like astype(uint8)
  }
  return out;
}

std::vector<float> DistanceTransform(const Gray& g) {
  // Felzenszwalb & Huttenlocher exact squared-EDT, then sqrt.
  const int W = g.w, H = g.h;
  const float INF = 1e20f;
  std::vector<float> dt(W * H);
  for (int i = 0; i < W * H; ++i) dt[i] = g.px[i] ? INF : 0.0f;
  std::vector<float> f(std::max(W, H)), d(std::max(W, H));
  std::vector<int> v(std::max(W, H));
  std::vector<float> z(std::max(W, H) + 1);
  auto pass1d = [&](int n) {
    int k = 0;
    v[0] = 0;
    z[0] = -1e20f;
    z[1] = 1e20f;
    for (int q = 1; q < n; ++q) {
      float s = ((f[q] + (float)(q * q)) - (f[v[k]] + (float)(v[k] * v[k]))) /
                (2.0f * q - 2.0f * v[k]);
      while (s <= z[k]) {
        --k;
        s = ((f[q] + (float)(q * q)) - (f[v[k]] + (float)(v[k] * v[k]))) /
            (2.0f * q - 2.0f * v[k]);
      }
      ++k;
      v[k] = q;
      z[k] = s;
      z[k + 1] = 1e20f;
    }
    k = 0;
    for (int q = 0; q < n; ++q) {
      while (z[k + 1] < q) ++k;
      float dx = (float)(q - v[k]);
      d[q] = dx * dx + f[v[k]];
    }
  };
  for (int x = 0; x < W; ++x) {
    for (int y = 0; y < H; ++y) f[y] = dt[y * W + x];
    pass1d(H);
    for (int y = 0; y < H; ++y) dt[y * W + x] = d[y];
  }
  for (int y = 0; y < H; ++y) {
    for (int x = 0; x < W; ++x) f[x] = dt[y * W + x];
    pass1d(W);
    for (int x = 0; x < W; ++x) dt[y * W + x] = std::sqrt(d[x]);
  }
  return dt;
}

Bgr ResizeBilinear(const Bgr& bgr, int w, int h) {
  Bgr out{w, h, std::vector<uint8_t>(w * h * 3)};
  double sx = (double)bgr.w / w, sy = (double)bgr.h / h;
  // The source coordinate of a column (row) is row- (column-)
  // independent; hoist it so each is computed once instead of h (w)
  // times. Values are reused verbatim, so the output is bit-identical.
  std::vector<int> x0v(w), y0v(h);
  std::vector<double> txv(w), tyv(h);
  for (int x = 0; x < w; ++x) {
    double fx = (x + 0.5) * sx - 0.5;
    x0v[x] = (int)std::floor(fx);
    txv[x] = fx - x0v[x];
  }
  for (int y = 0; y < h; ++y) {
    double fy = (y + 0.5) * sy - 0.5;
    y0v[y] = (int)std::floor(fy);
    tyv[y] = fy - y0v[y];
  }
  for (int y = 0; y < h; ++y)
    for (int x = 0; x < w; ++x) {
      int x0 = x0v[x], y0 = y0v[y];
      double tx = txv[x], ty = tyv[y];
      for (int c = 0; c < 3; ++c) {
        auto px = [&](int xx, int yy) -> double {
          xx = xx < 0 ? 0 : (xx >= bgr.w ? bgr.w - 1 : xx);
          yy = yy < 0 ? 0 : (yy >= bgr.h ? bgr.h - 1 : yy);
          return bgr.px[(yy * bgr.w + xx) * 3 + c];
        };
        double v = (1 - tx) * (1 - ty) * px(x0, y0) + tx * (1 - ty) * px(x0 + 1, y0) +
                   (1 - tx) * ty * px(x0, y0 + 1) + tx * ty * px(x0 + 1, y0 + 1);
        out.px[(y * w + x) * 3 + c] = (uint8_t)std::round(v);
      }
    }
  return out;
}

}  // namespace img
}  // namespace tennis
