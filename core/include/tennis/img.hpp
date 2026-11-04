// Minimal image ops for court calibration (OpenCV-compatible
// conventions: BGR bytes, HSV ranges H[0,179] S/V[0,255]).
#pragma once

#include <cstdint>
#include <vector>

namespace tennis {
namespace img {

struct Gray {
  int w = 0, h = 0;
  std::vector<uint8_t> px;  // row-major
};

struct Bgr {
  int w = 0, h = 0;
  std::vector<uint8_t> px;  // row-major interleaved
};

// BGR -> HSV with OpenCV 8-bit ranges (H 0..179).
Bgr BgrToHsv(const Bgr& bgr);
// Per-channel inclusive range -> 0/255 mask.
Gray InRange(const Bgr& hsv, const uint8_t lo[3], const uint8_t hi[3]);
// Rect-kernel morphology (replicate border, like cv2 defaults here).
Gray Dilate(const Gray& g, int k);
Gray Erode(const Gray& g, int k);
Gray MorphClose(const Gray& g, int k);
// 8-connected components: labels (row-major, 0=bg) + area per label.
void ConnectedComponents(const Gray& g, std::vector<int>& labels,
                         std::vector<int>& areas);
// k=21 median (replicate border, like cv2.medianBlur).
Gray MedianBlur21(const Gray& g);
// 13x13 normalized box mean of a 0/1 float image (reflect101 border).
std::vector<float> BoxMean13(const std::vector<float>& f, int w, int h);
// Per-pixel median over N frames (numpy semantics: even-N averages the
// middle two, then truncates to uint8).
Bgr MedianBackground(const std::vector<Bgr>& frames);
// Exact Euclidean distance to the nearest zero pixel.
std::vector<float> DistanceTransform(const Gray& g);
// Bilinear resize (dead path in practice; replicate border).
Bgr ResizeBilinear(const Bgr& bgr, int w, int h);

}  // namespace img
}  // namespace tennis
