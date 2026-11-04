#include "setmatch_shim.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

#include "tennis/img.hpp"

extern "C" {

void sm_rgba_to_bgr(const uint8_t* rgba, int w, int h, uint8_t* bgr) {
  const long n = (long)w * h;
  for (long i = 0; i < n; ++i) {
    bgr[3 * i] = rgba[4 * i + 2];
    bgr[3 * i + 1] = rgba[4 * i + 1];
    bgr[3 * i + 2] = rgba[4 * i];
  }
}

void sm_bgr_to_gray(const uint8_t* bgr, int w, int h, uint8_t* gray) {
  // OpenCV 4.x/5.x 8U path: (b*3735 + g*19235 + r*9798 + 2^14) >> 15
  // (bit-exact vs cv2.cvtColor on real frames).
  const long n = (long)w * h;
  for (long i = 0; i < n; ++i) {
    const int b = bgr[3 * i], g = bgr[3 * i + 1], r = bgr[3 * i + 2];
    gray[i] = (uint8_t)((b * 3735 + g * 19235 + r * 9798 + (1 << 14)) >> 15);
  }
}

int sm_resize_bgr(const uint8_t* src, int w, int h, uint8_t* dst, int dw,
                  int dh) {
  if (!src || !dst || w <= 0 || h <= 0 || dw <= 0 || dh <= 0) return -1;
  tennis::img::Bgr in{w, h, std::vector<uint8_t>(src, src + (size_t)w * h * 3)};
  tennis::img::Bgr out = tennis::img::ResizeBilinear(in, dw, dh);
  std::memcpy(dst, out.px.data(), (size_t)dw * dh * 3);
  return 0;
}

namespace {

inline uint8_t Clamp8(int v) { return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v); }

// cv2 INTER_LINEAR source taps + 11-bit fixed-point weights for one axis.
void LinearTaps(int src, int dst, std::vector<int>& i0, std::vector<int>& i1,
                std::vector<int>& w0, std::vector<int>& w1) {
  const double scale = (double)src / dst;
  i0.resize(dst);
  i1.resize(dst);
  w0.resize(dst);
  w1.resize(dst);
  for (int d = 0; d < dst; ++d) {
    float f = (float)((d + 0.5) * scale - 0.5);
    int s = (int)std::floor(f);
    f -= s;
    if (s < 0) {
      f = 0;
      s = 0;
    }
    if (s >= src - 1) {
      f = 0;
      s = src - 1;
    }
    i0[d] = s;
    i1[d] = std::min(s + 1, src - 1);
    w0[d] = (int)std::lround((1.f - f) * 2048);
    w1[d] = (int)std::lround(f * 2048);
  }
}

}  // namespace

int sm_nv12_to_rgba_cv(const uint8_t* y, int y_stride, const uint8_t* uv,
                       int uv_stride, int sw, int sh, int rot_cw,
                       uint8_t* rgba, int dw, int dh) {
  if (!y || !uv || !rgba || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0)
    return -1;
  const bool swap = rot_cw == 90 || rot_cw == 270;
  const int rw = swap ? sh : sw, rh = swap ? sw : sh;  // displayed size
  std::vector<int> x0, x1, ax0, ax1, y0, y1, ay0, ay1;
  LinearTaps(rw, dw, x0, x1, ax0, ax1);
  LinearTaps(rh, dh, y0, y1, ay0, ay1);
  // displayed (x, y) -> BGR of the source pixel (FFmpeg BT.601 limited)
  auto px = [&](int x, int yy, int* bgr) {
    int sx, sy;
    switch (rot_cw) {
      case 90: sx = yy; sy = sh - 1 - x; break;
      case 180: sx = sw - 1 - x; sy = sh - 1 - yy; break;
      case 270: sx = sw - 1 - yy; sy = x; break;
      default: sx = x; sy = yy; break;
    }
    const int c = y[(size_t)sy * y_stride + sx] - 16;
    const uint8_t* cc = uv + (size_t)(sy >> 1) * uv_stride + (sx & ~1);
    const int d = cc[0] - 128, e = cc[1] - 128;
    bgr[0] = Clamp8((298 * c + 516 * d + 128) >> 8);
    bgr[1] = Clamp8((298 * c - 100 * d - 208 * e + 128) >> 8);
    bgr[2] = Clamp8((298 * c + 409 * e + 128) >> 8);
  };
  int p00[3], p01[3], p10[3], p11[3];
  for (int dy = 0; dy < dh; ++dy) {
    uint8_t* out = rgba + (size_t)dy * dw * 4;
    for (int dx = 0; dx < dw; ++dx, out += 4) {
      px(x0[dx], y0[dy], p00);
      px(x1[dx], y0[dy], p01);
      px(x0[dx], y1[dy], p10);
      px(x1[dx], y1[dy], p11);
      for (int k = 0; k < 3; ++k) {
        const int h0 = p00[k] * ax0[dx] + p01[k] * ax1[dx];
        const int h1 = p10[k] * ax0[dx] + p11[k] * ax1[dx];
        out[2 - k] = Clamp8((h0 * ay0[dy] + h1 * ay1[dy] + (1 << 21)) >> 22);
      }
      out[3] = 255;
    }
  }
  return 0;
}

}  // extern "C"
