// Ball candidates from one heat class map (extract_candidates port).
#pragma once

#include <cstdint>
#include <vector>

#include "tennis/types.hpp"

namespace tennis {

constexpr int kHotThreshold = 127;
constexpr int kModelWidth = 640;
constexpr int kModelHeight = 360;

// heat: row-major uint8 class map (heat_h x heat_w). Positions come out
// in processing-frame pixels (frame_w x frame_h).
std::vector<Candidate> ExtractCandidates(const uint8_t* heat, int heat_w,
                                         int heat_h, int frame_w, int frame_h,
                                         int thresh = kHotThreshold,
                                         int min_area = 3, int max_area = 400);

}  // namespace tennis
