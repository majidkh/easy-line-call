// ROI test: real blind-gap crops must yield the ball near the
// prediction; empty-court crops must yield nothing. Plus synthetic
// gate checks (no fixture needed).
#include <cmath>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "mini_json.hpp"
#include "tennis/roi.hpp"

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
    std::cerr << "usage: roi_test <fixtures dir>\n";
    return 2;
  }
  std::string dir = std::string(argv[1]) + "/roi";
  int fail = 0;
  auto CHECK = [&](bool c, const std::string& m) {
    if (!c) {
      std::cout << "FAIL " << m << "\n";
      ++fail;
    }
  };
  try {
    auto exp = mini::ParseJson(ReadFile(dir + "/expected_roi.json"));
    for (const auto& t : exp->as_arr()) {
      int i = t->at("case").as_int();
      std::string tag = t->at("tag").as_str();
      double px = t->at("pred").as_arr()[0]->as_num();
      double py = t->at("pred").as_arr()[1]->as_num();
      double radius = t->at("radius").as_num();
      bool want = !t->at("found").is_null() && t->at("found").as_bool();
      std::string p = ReadFile(dir + "/case" + std::to_string(i) + "_p.raw");
      std::string c = ReadFile(dir + "/case" + std::to_string(i) + "_c.raw");
      std::string n = ReadFile(dir + "/case" + std::to_string(i) + "_n.raw");
      int side = (int)std::sqrt((double)p.size());
      CHECK((int)c.size() == side * side && (int)n.size() == side * side,
            tag + " raw size");
      tennis::RoiFound r = tennis::RoiFindBall(
          reinterpret_cast<const uint8_t*>(p.data()),
          reinterpret_cast<const uint8_t*>(c.data()),
          reinterpret_cast<const uint8_t*>(n.data()), side, side, px, py,
          radius);
      if (want) {
        CHECK(r.found, tag + " should find the ball");
        if (r.found) {
          double d = std::hypot(r.x - px, r.y - py);
          std::cout << tag << ": found d=" << d << " conf=" << r.conf
                    << "\n";
          CHECK(d <= 25, tag + " near prediction");
        }
      } else {
        CHECK(!r.found, tag + " should find nothing");
      }
    }
    // Synthetic gates.
    {
      // Static noise: no motion -> nothing.
      std::vector<uint8_t> a(64 * 64, 100), b = a, c = a;
      auto r = tennis::RoiFindBall(a.data(), b.data(), c.data(), 64, 64, 32,
                                   32, 30);
      CHECK(!r.found, "static frame finds nothing");
    }
    {
      // Bright dot jumping 10px/frame -> found at the dot.
      std::vector<uint8_t> p(64 * 64, 60), c(64 * 64, 60), n(64 * 64, 60);
      auto dot = [](std::vector<uint8_t>& f, int x, int y) {
        for (int dy = -1; dy <= 1; ++dy)
          for (int dx = -1; dx <= 1; ++dx) f[(y + dy) * 64 + x + dx] = 230;
      };
      dot(p, 20, 32);
      dot(c, 30, 32);
      dot(n, 40, 32);
      auto r = tennis::RoiFindBall(p.data(), c.data(), n.data(), 64, 64, 32,
                                   32, 30);
      CHECK(r.found, "moving dot found");
      if (r.found)
        CHECK(std::hypot(r.x - 30, r.y - 32) <= 2, "dot position");
    }
    {
      // Huge bright mover (a player torso) -> rejected.
      std::vector<uint8_t> p(64 * 64, 60), c(64 * 64, 60), n(64 * 64, 60);
      for (int y = 20; y < 45; ++y)
        for (int x = 0; x < 64; ++x) {
          if (x >= 18 && x < 43) p[y * 64 + x] = 220;
          if (x >= 20 && x < 45) c[y * 64 + x] = 220;
          if (x >= 22 && x < 47) n[y * 64 + x] = 220;
        }
      auto r = tennis::RoiFindBall(p.data(), c.data(), n.data(), 64, 64, 32,
                                   32, 30);
      CHECK(!r.found, "huge blob rejected");
    }
  } catch (const std::exception& e) {
    std::cout << "ERROR " << e.what() << "\n";
    return 1;
  }
  if (!fail) std::cout << "ROI OK\n";
  return fail ? 1 : 0;
}
