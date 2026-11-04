// Parity test: the C++ core must reproduce the Python engine's
// tracks + rallies + candidates EXACTLY (ints/strings) and to 1e-2 px
// (floats) on real fixtures. Usage: parity_test <fixtures dir>.
// Intentional divergence (2026-11): the C++ DespikeTrack spares
// predominantly-downward 1-take valleys (impact bottoms such as
// rally-3.mov frame 371); the Python twin still kills them. The
// clip27a8 goldens were updated to the fixed behavior (frame 678 kept
// observed plus interpolation/smoothing ripples over 673-708; no
// bounce/hit/rally change). Re-running dump_fixtures.py needs the same
// spare ported to Python first, or the goldens revert and this fails.
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include "mini_json.hpp"
#include "tennis/detect.hpp"
#include "tennis/session.hpp"

namespace {

std::string ReadFile(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  if (!f) throw std::runtime_error("cannot open " + p);
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

int g_fail = 0;
double g_maxdiff = 0;

#define CHECK(cond, msg)                                              \
  do {                                                                \
    if (!(cond)) {                                                    \
      std::cout << "FAIL " << (msg) << "\n";                          \
      ++g_fail;                                                       \
    }                                                                 \
  } while (0)

void CheckClose(double a, double e, const std::string& msg) {
  double d = std::fabs(a - e);
  if (d > g_maxdiff) g_maxdiff = d;
  if (!(d <= 1e-2)) {
    std::cout << "FAIL " << msg << " got " << a << " want " << e << "\n";
    ++g_fail;
  }
}

tennis::FrameCands LoadCands(const std::string& path) {
  tennis::FrameCands fc;
  std::ifstream f(path);
  std::string line;
  while (std::getline(f, line)) {
    if (line.empty()) continue;
    int fr;
    double x, y, c;
    if (std::sscanf(line.c_str(), "%d,%lf,%lf,%lf", &fr, &x, &y, &c) != 4)
      throw std::runtime_error("bad cands row");
    fc[fr].push_back({x, y, c, 0, 0});
  }
  return fc;
}

tennis::CourtGeom LoadCourt(const std::string& path) {
  auto v = mini::ParseJson(ReadFile(path));
  tennis::CourtGeom court;
  court.valid = true;
  const auto& a = v->at("h_img2court").as_arr();
  const auto& b = v->at("h_court2img").as_arr();
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) {
      court.h_img2court[i * 3 + j] = a[i]->as_arr()[j]->as_num();
      court.h_court2img[i * 3 + j] = b[i]->as_arr()[j]->as_num();
    }
  return court;
}

void CheckCase(const std::string& dir, const std::string& name) {
  tennis::FrameCands fc = LoadCands(dir + "/cands_" + name + ".csv");
  tennis::CourtGeom court = LoadCourt(dir + "/court_" + name + ".json");
  auto exp = mini::ParseJson(ReadFile(dir + "/expected_" + name + ".json"));
  double fps = exp->at("fps").as_num();
  int width = exp->at("width").as_int();
  const auto& stages = exp->at("stages").as_arr();

  // Same 3-way split the dumper used.
  std::vector<int> frames;
  for (const auto& [f, cs] : fc) frames.push_back(f);
  size_t n = frames.size();
  std::vector<std::vector<int>> parts = {
      {frames.begin(), frames.begin() + n / 3},
      {frames.begin() + n / 3, frames.begin() + 2 * n / 3},
      {frames.begin() + 2 * n / 3, frames.end()}};

  tennis::Session sess(fps, width, &court);
  for (size_t s = 0; s < 3; ++s) {
    tennis::FrameCands part;
    for (int f : parts[s]) part[f] = fc[f];
    sess.Ingest(part);
    const auto& st = *stages[s];
    std::string tag = name + ".stage" + std::to_string(s);
    CHECK(sess.coverage() == st.at("upto").as_int(), tag + " coverage");
    CHECK(sess.n_cands() == st.at("n_cands").as_int(), tag + " n_cands");
    const auto& et = st.at("tracks").as_arr();
    CHECK(sess.tracks.size() == et.size(), tag + " ntracks");
    for (size_t i = 0; i < std::min(sess.tracks.size(), et.size()); ++i) {
      const auto& t = sess.tracks[i];
      const auto& e = *et[i];
      std::string tg = tag + ".t" + std::to_string(i);
      CHECK(t.id == e.at("id").as_int(), tg + " id");
      const auto& ep = e.at("points").as_arr();
      CHECK(t.points.size() == ep.size(), tg + " npts");
      for (size_t k = 0; k < std::min(t.points.size(), ep.size()); ++k) {
        const auto& p = t.points[k];
        const auto& q = *ep[k];
        const auto& qa = q.as_arr();
        if (p.frame != qa[0]->as_int() || p.observed != qa[3]->as_bool()) {
          CHECK(false, tg + " pt" + std::to_string(k) + " frame/obs");
          break;
        }
        CheckClose(p.x, qa[1]->as_num(), tg + " ptx");
        CheckClose(p.y, qa[2]->as_num(), tg + " pty");
        CheckClose(p.conf, qa[4]->as_num(), tg + " pconf");
        if (g_fail > 20) return;
      }
      const auto& eh = e.at("hits").as_arr();
      CHECK(t.hits.size() == eh.size(), tg + " nhits");
      for (size_t k = 0; k < std::min(t.hits.size(), eh.size()); ++k)
        CHECK(t.hits[k] == eh[k]->as_int(), tg + " hit");
      const auto& eb = e.at("bounces").as_arr();
      CHECK(t.bounces.size() == eb.size(), tg + " nbounces");
      for (size_t k = 0; k < std::min(t.bounces.size(), eb.size()); ++k)
        CHECK(t.bounces[k] == eb[k]->as_int(), tg + " bounce");
    }
    const auto& er = st.at("rallies").as_arr();
    CHECK(sess.rallies.size() == er.size(), tag + " nrallies");
    for (size_t i = 0; i < std::min(sess.rallies.size(), er.size()); ++i) {
      const auto& r = sess.rallies[i];
      const auto& e = *er[i];
      std::string tg = tag + ".r" + std::to_string(i);
      CHECK(r.index == e.at("index").as_int(), tg + " index");
      CHECK(r.track_id == e.at("track_id").as_int(), tg + " track");
      CHECK(r.start == e.at("start").as_int(), tg + " start");
      CHECK(r.end == e.at("end").as_int(), tg + " end");
      const auto& eh = e.at("hits").as_arr();
      CHECK(r.hits.size() == eh.size(), tg + " nhits");
      for (size_t k = 0; k < std::min(r.hits.size(), eh.size()); ++k)
        CHECK(r.hits[k] == eh[k]->as_int(), tg + " hit");
      const auto& eb = e.at("bounces").as_arr();
      CHECK(r.bounces.size() == eb.size(), tg + " nbounces");
      for (size_t k = 0; k < std::min(r.bounces.size(), eb.size()); ++k) {
        const auto& b = r.bounces[k];
        const auto& q = *eb[k];
        CHECK(b.frame == q.at("frame").as_int(), tg + " bf");
        CHECK(std::string(b.call) == q.at("call").as_str(), tg + " bcall");
        CheckClose(b.x, q.at("x").as_num(), tg + " bx");
        CheckClose(b.y, q.at("y").as_num(), tg + " by");
        CheckClose(b.wx, q.at("wx").as_num(), tg + " bwx");
        CheckClose(b.wy, q.at("wy").as_num(), tg + " bwy");
      }
      int eserve = e.at("serve").is_null() ? -1 : e.at("serve").as_int();
      CHECK(r.serve_frame == eserve, tg + " serve");
    }
  }
  std::cout << "case " << name << " done\n";
}

void CheckDetect(const std::string& dir) {
  auto exp = mini::ParseJson(ReadFile(dir + "/expected_detect.json"));
  for (const auto& t : exp->at("tests").as_arr()) {
    std::string raw = ReadFile(dir + "/" + t->at("heat").as_str());
    int w = t->at("w").as_int(), h = t->at("h").as_int();
    CHECK((int)raw.size() == w * h, t->at("heat").as_str() + " size");
    auto cs = tennis::ExtractCandidates(
        reinterpret_cast<const uint8_t*>(raw.data()), w, h, 1280, 720);
    const auto& ec = t->at("cands").as_arr();
    CHECK(cs.size() == ec.size(), t->at("heat").as_str() + " ncands");
    for (size_t i = 0; i < std::min(cs.size(), ec.size()); ++i) {
      const auto& q = *ec[i];
      const auto& qa = q.as_arr();
      std::string tg = t->at("heat").as_str() + ".c" + std::to_string(i);
      CheckClose(cs[i].x, qa[0]->as_num(), tg + " x");
      CheckClose(cs[i].y, qa[1]->as_num(), tg + " y");
      CheckClose(cs[i].conf, qa[2]->as_num(), tg + " conf");
      CHECK(cs[i].area == qa[3]->as_int(), tg + " area");
      CHECK(cs[i].peak == qa[4]->as_int(), tg + " peak");
    }
  }
  std::cout << "detect done\n";
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::cerr << "usage: parity_test <fixtures dir>\n";
    return 2;
  }
  std::string dir = argv[1];
  try {
    CheckCase(dir, "img8630");
    CheckCase(dir, "clip27a8");
    CheckCase(dir, "rich19s");
    CheckDetect(dir);
  } catch (const std::exception& e) {
    std::cout << "ERROR " << e.what() << "\n";
    return 1;
  }
  std::cout << "max float diff: " << g_maxdiff << "\n";
  if (g_fail == 0) std::cout << "PARITY OK\n";
  return g_fail ? 1 : 0;
}
