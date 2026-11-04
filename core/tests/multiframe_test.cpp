// Multi-frame calibration: best verified fit wins.
//
// Regression: on a centered back-of-court view (input/2.MOV) the median
// background dilutes the thin service line below the white threshold, so
// median-only calibration finds no seed pair — while single frames keep
// full-bright paint and fit fine. CalibrateFrames must succeed on such
// inputs by selecting the best member fit.
#include <cstdio>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "tennis/court.hpp"
#include "tennis/img.hpp"

namespace {

std::string Load(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

int failures = 0;
void Check(bool ok, const char* name) {
  if (!ok) {
    ++failures;
    printf("FAIL %s\n", name);
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    printf("usage: multiframe_test <fixtures>\n");
    return 2;
  }
  std::string dir = argv[1];
  const int w = 640, h = 360;
  std::vector<std::string> raws;
  std::vector<tennis::img::Bgr> frames;
  for (int i = 0; i < 3; ++i) {
    raws.push_back(Load(dir + "/calib2m_" + std::to_string(i) + ".raw"));
    if ((int)raws.back().size() != w * h * 3) {
      printf("FAIL fixture %d size\n", i);
      return 1;
    }
    frames.push_back(
        {w, h,
         std::vector<uint8_t>(raws.back().begin(), raws.back().end())});
  }

  // The median alone cannot fit (service line diluted): prove the fixture
  // still reproduces the original failure mode.
  tennis::img::Bgr med = tennis::img::MedianBackground(frames);
  bool median_failed = false;
  try {
    tennis::DetectCourt(med.px.data(), w, h);
  } catch (const tennis::CourtError&) {
    median_failed = true;
  }
  Check(median_failed, "median alone fails");

  // Multi-frame calibration must recover via the best member fit.
  std::vector<const uint8_t*> ptrs;
  for (auto& f : frames) ptrs.push_back(f.px.data());
  tennis::CourtCalib c;
  try {
    c = tennis::CalibrateFrames(ptrs, w, h);
  } catch (const tennis::CourtError& e) {
    printf("FAIL calibrate threw: %s\n", e.what());
    return 1;
  }
  std::set<std::string> roles;
  for (auto& l : c.lines)
    if (!l.role.empty()) roles.insert(l.role);
  printf("c++ rms=%.3f kps=%d support=%.2f roles=", c.rms_px,
         (int)c.keypoints.size(), c.support);
  for (auto& r : roles) printf("%s ", r.c_str());
  printf("\n");
  Check(roles.count("baseline-S") > 0, "has near baseline");
  int across = 0;
  for (auto r : {"baseline-S", "service-S", "net", "service-N",
                 "baseline-N"})
    if (roles.count(r)) across++;
  Check(across >= 2, "spans the court lengthwise");
  Check(c.rms_px < 8.0, "rms sane");
  Check(c.support >= 0.30, "support sane");

  // Rotated back-of-court view (input/4.MOV, camera toward the left side):
  // sidelines run near-horizontal, so axis assignment by image angle alone
  // fails. Dual pooling + world-shape roles must fit the clear frame; the
  // occluded frame (service line hidden by players) admits only a stretched
  // exact fit, which the near-court scale gate must reject.
  const int w4 = 1280, h4 = 720;
  std::string raw4a = Load(dir + "/calib4m_0.raw");
  std::string raw4b = Load(dir + "/calib4m_1.raw");
  if ((int)raw4a.size() != w4 * h4 * 3) {
    printf("FAIL calib4m_0 size\n");
    return 1;
  }
  if ((int)raw4b.size() != w4 * h4 * 3) {
    printf("FAIL calib4m_1 size\n");
    return 1;
  }
  bool occluded_failed = false;
  try {
    tennis::DetectCourt(reinterpret_cast<const uint8_t*>(raw4b.data()), w4,
                        h4);
  } catch (const tennis::CourtError&) {
    occluded_failed = true;
  }
  Check(occluded_failed, "occluded rotated frame rejected");

  std::vector<const uint8_t*> ptrs4 = {
      reinterpret_cast<const uint8_t*>(raw4b.data()),
      reinterpret_cast<const uint8_t*>(raw4a.data())};
  tennis::CourtCalib c4;
  try {
    c4 = tennis::CalibrateFrames(ptrs4, w4, h4);
  } catch (const tennis::CourtError& e) {
    printf("FAIL rotated calibrate threw: %s\n", e.what());
    return 1;
  }
  std::set<std::string> roles4;
  for (auto& l : c4.lines)
    if (!l.role.empty()) roles4.insert(l.role);
  printf("rotated rms=%.3f kps=%d support=%.2f roles=", c4.rms_px,
         (int)c4.keypoints.size(), c4.support);
  for (auto& r : roles4) printf("%s ", r.c_str());
  printf("\n");
  Check(roles4.count("baseline-S") > 0, "rotated has near baseline");
  int across4 = 0;
  for (auto r : {"baseline-S", "service-S", "net", "service-N",
                 "baseline-N"})
    if (roles4.count(r)) across4++;
  Check(across4 >= 2, "rotated spans the court lengthwise");
  int along4 = 0;
  for (auto r : {"doubles-W", "singles-W", "center", "singles-E",
                 "doubles-E"})
    if (roles4.count(r)) along4++;
  Check(along4 >= 2, "rotated has both sidelines");
  Check(c4.rms_px < 8.0, "rotated rms sane");
  Check(c4.support >= 0.30, "rotated support sane");
  return failures ? 1 : 0;
}
