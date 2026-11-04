// Ball heatmap inference inside the core.
//
// On Apple platforms this runs the .mlpackage on the Neural Engine via
// Core ML (same model file, same ANE path as before — now shared by the
// desktop and iOS containers). Elsewhere CreateDetector returns nullptr
// and callers fall back to their own backend.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace tennis {

struct HeatMaps {
  int w = 0, h = 0;  // map geometry (may crop vs model input)
  // One row-major uint8 class map per input frame; the first two are
  // all-zero (no full triplet yet). Mirrors tracknet.heatmaps_for.
  std::vector<std::vector<uint8_t>> maps;
};

class BallDetector {
 public:
  virtual ~BallDetector() = default;
  // bgrs: n frames of w*h*3 bytes. cancelled is polled between frames.
  virtual HeatMaps HeatmapsFor(const std::vector<const uint8_t*>& bgrs, int w,
                               int h,
                               const std::function<bool()>& cancelled) = 0;
  HeatMaps HeatmapsFor(const std::vector<const uint8_t*>& bgrs, int w, int h) {
    return HeatmapsFor(bgrs, w, h, {});
  }
  virtual std::string device() const = 0;
  virtual int in_w() const = 0;
  virtual int in_h() const = 0;
};

// compile_cache: directory for the compiled model (created if needed).
// compute_units: "CPU_AND_NE" (proven) or "ALL".
// Returns nullptr when unavailable (non-Apple build); err receives why.
std::unique_ptr<BallDetector> CreateDetector(const std::string& model_path,
                                             const std::string& compile_cache,
                                             const std::string& compute_units,
                                             std::string& err);

}  // namespace tennis
