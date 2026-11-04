// Court parity: same median frame through C++ DetectCourt must yield an
// equivalent calibration — same role set, rms within 0.35px, model
// corners reprojected within 2.5px. (RANSAC streams differ by design,
// so bitwise equality is not the bar — same algorithm, same answer.)
#include <cmath>
#include <fstream>
#include <iostream>
#include <set>
#include <sstream>
#include <string>

#include "mini_json.hpp"
#include "tennis/court.hpp"

namespace {

std::string ReadFile(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  if (!f) throw std::runtime_error("cannot open " + p);
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::cerr << "usage: court_test <fixtures dir>\n";
    return 2;
  }
  std::string dir = argv[1];
  int fail = 0;
  auto CHECK = [&](bool c, const std::string& m) {
    if (!c) {
      std::cout << "FAIL " << m << "\n";
      ++fail;
    }
  };
  try {
    std::string raw = ReadFile(dir + "/calib_med.raw");
    auto exp = mini::ParseJson(ReadFile(dir + "/expected_court.json"));
    int w = exp->at("w").as_int(), h = exp->at("h").as_int();
    CHECK((int)raw.size() == w * h * 3, "raw size");
    tennis::CourtCalib c = tennis::DetectCourt(
        reinterpret_cast<const uint8_t*>(raw.data()), w, h);
    std::set<std::string> roles;
    for (auto& l : c.lines)
      if (!l.role.empty()) roles.insert(l.role);
    std::cout << "c++ rms=" << c.rms_px << " kps=" << c.keypoints.size()
              << " roles=";
    for (auto& r : roles) std::cout << r << " ";
    std::cout << "\n";
    CHECK(std::fabs(c.rms_px - exp->at("rms").as_num()) <= 0.35, "rms close");
    std::set<std::string> eroles;
    for (auto& r : exp->at("roles").as_arr()) eroles.insert(r->as_str());
    CHECK(roles == eroles, "role set equal");
    // Model corners through both homographies must nearly agree.
    const auto& H = exp->at("h_court2img").as_arr();
    double He[9];
    for (int i = 0; i < 3; ++i)
      for (int j = 0; j < 3; ++j) He[i * 3 + j] = H[i]->as_arr()[j]->as_num();
    double worst = 0;
    for (double wx : {-5.485, 5.485})
      for (double wy : {-11.885, 11.885}) {
        auto proj = [&](const double* M, double& x, double& y) {
          double q2 = M[6] * wx + M[7] * wy + M[8];
          x = (M[0] * wx + M[1] * wy + M[2]) / q2;
          y = (M[3] * wx + M[4] * wy + M[5]) / q2;
        };
        double x1, y1, x2, y2;
        proj(c.h_court2img, x1, y1);
        proj(He, x2, y2);
        worst = std::max(worst, std::hypot(x1 - x2, y1 - y2));
      }
    std::cout << "corner reproj diff: " << worst << " px\n";
    CHECK(worst <= 2.5, "corners agree");
  } catch (const std::exception& e) {
    std::cout << "ERROR " << e.what() << "\n";
    return 1;
  }
  if (!fail) std::cout << "COURT OK\n";
  return fail ? 1 : 0;
}
