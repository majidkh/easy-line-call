#include "tennis/tennis_c.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "tennis/court.hpp"
#include "tennis/detect.hpp"
#include "tennis/infer.hpp"
#include "tennis/roi.hpp"
#include "tennis/session.hpp"

namespace {

thread_local std::string g_err;

void SetErr(const std::string& m) { g_err = m; }

char* Dup(const std::string& s) {
  char* p = (char*)std::malloc(s.size() + 1);
  if (p) std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

std::string F(double v) {
  char b[32];
  std::snprintf(b, sizeof b, "%.17g", v);
  return b;
}

std::string TracksJson(const std::vector<tennis::Track>& tracks) {
  std::string s = "[";
  for (size_t i = 0; i < tracks.size(); ++i) {
    const auto& t = tracks[i];
    if (i) s += ",";
    s += "{\"id\":" + std::to_string(t.id) + ",\"points\":[";
    for (size_t k = 0; k < t.points.size(); ++k) {
      const auto& p = t.points[k];
      if (k) s += ",";
      s += "[" + std::to_string(p.frame) + "," + F(p.x) + "," + F(p.y) +
           "," + (p.observed ? "true" : "false") + "," + F(p.conf) + "]";
    }
    s += "],\"hits\":[";
    for (size_t k = 0; k < t.hits.size(); ++k) {
      if (k) s += ",";
      s += std::to_string(t.hits[k]);
    }
    s += "],\"bounces\":[";
    for (size_t k = 0; k < t.bounces.size(); ++k) {
      if (k) s += ",";
      s += std::to_string(t.bounces[k]);
    }
    s += "],\"stray\":";
    s += t.stray ? "true" : "false";
    s += "}";
  }
  return s + "]";
}

std::string RalliesJson(const std::vector<tennis::Rally>& rallies) {
  std::string s = "[";
  for (size_t i = 0; i < rallies.size(); ++i) {
    const auto& r = rallies[i];
    if (i) s += ",";
    s += "{\"index\":" + std::to_string(r.index) + ",\"track_id\":" +
         std::to_string(r.track_id) + ",\"start\":" + std::to_string(r.start) +
         ",\"end\":" + std::to_string(r.end) + ",\"hits\":[";
    for (size_t k = 0; k < r.hits.size(); ++k) {
      if (k) s += ",";
      s += std::to_string(r.hits[k]);
    }
    s += "],\"bounces\":[";
    for (size_t k = 0; k < r.bounces.size(); ++k) {
      const auto& b = r.bounces[k];
      if (k) s += ",";
      s += "{\"frame\":" + std::to_string(b.frame) + ",\"x\":" + F(b.x) +
           ",\"y\":" + F(b.y) + ",\"call\":\"" + b.call + "\",\"wx\":" +
           F(b.wx) + ",\"wy\":" + F(b.wy) + "}";
    }
    s += "],\"serve\":";
    s += r.serve_frame < 0 ? "null" : std::to_string(r.serve_frame);
    s += "}";
  }
  return s + "]";
}

std::string MatJson(const double m[9]) {
  std::string s = "[";
  for (int i = 0; i < 3; ++i) {
    if (i) s += ",";
    s += "[" + F(m[3 * i]) + "," + F(m[3 * i + 1]) + "," + F(m[3 * i + 2]) +
         "]";
  }
  return s + "]";
}

std::string CalibJson(const tennis::CourtCalib& c) {
  std::string s = "{\"h_img2court\":" + MatJson(c.h_img2court) +
                  ",\"h_court2img\":" + MatJson(c.h_court2img) +
                  ",\"rms\":" + F(c.rms_px) + ",\"keypoints\":[";
  for (size_t i = 0; i < c.keypoints.size(); ++i) {
    const auto& k = c.keypoints[i];
    if (i) s += ",";
    s += "[" + F(k.x) + "," + F(k.y) + "," + F(k.wx) + "," + F(k.wy) + "]";
  }
  s += "],\"lines\":[";
  for (size_t i = 0; i < c.lines.size(); ++i) {
    const auto& l = c.lines[i];
    if (i) s += ",";
    s += "{\"a\":" + F(l.a) + ",\"b\":" + F(l.b) + ",\"c\":" + F(l.c) +
         ",\"angle\":" + F(l.angle) + ",\"length\":" + F(l.length) +
         ",\"role\":\"" + l.role + "\",\"px\":" + F(l.px) +
         ",\"py\":" + F(l.py) + ",\"dx\":" + F(l.dx) + ",\"dy\":" + F(l.dy) +
         ",\"t0\":" + F(l.t0) + ",\"t1\":" + F(l.t1) + "}";
  }
  return s + "]}";
}

}  // namespace

struct TennisSession {
  // NOTE: `court` FIRST — `impl` borrows it at construction.
  tennis::CourtGeom court;
  tennis::Session impl;
  TennisSession(double fps, int width, const tennis::CourtGeom& c, bool cf)
      : court(c), impl(fps, width, court.valid ? &court : nullptr,
                       tennis::TrackerConfig(), cf) {}
};

struct TennisDetector {
  std::unique_ptr<tennis::BallDetector> impl;
  std::string device;
};

extern "C" {

const char* tennis_last_error(void) { return g_err.c_str(); }
void tennis_free(void* p) { std::free(p); }

TennisSession* tennis_session_create(double fps, int width,
                                     const double* h_img2court,
                                     const double* h_court2img,
                                     int court_filter) {
  try {
    tennis::CourtGeom c;
    if (h_img2court && h_court2img) {
      c.valid = true;
      std::memcpy(c.h_img2court, h_img2court, 9 * sizeof(double));
      std::memcpy(c.h_court2img, h_court2img, 9 * sizeof(double));
    }
    return new TennisSession(fps, width, c, court_filter != 0);
  } catch (const std::exception& e) {
    SetErr(e.what());
    return nullptr;
  }
}

void tennis_session_destroy(TennisSession* s) { delete s; }

int tennis_session_ingest(TennisSession* s, int n_frames, const int* frames,
                          const double* xs, const double* ys,
                          const double* confs, const int* counts) {
  if (!s) return -1;
  try {
    tennis::FrameCands fc;
    size_t k = 0;
    for (int i = 0; i < n_frames; ++i) {
      for (int j = 0; j < counts[i]; ++j, ++k)
        fc[frames[i]].push_back({xs[k], ys[k], confs[k], 0, 0});
    }
    s->impl.Ingest(fc);
    return 0;
  } catch (const std::exception& e) {
    SetErr(e.what());
    return -1;
  }
}

int tennis_session_coverage(TennisSession* s) {
  return s ? s->impl.coverage() : -1;
}
void tennis_session_set_stitch(TennisSession* s, int gap, double resid) {
  if (s) s->impl.set_stitch(gap, resid);
}
void tennis_session_set_min_length(TennisSession* s, int n) {
  if (s) s->impl.set_min_length(n);
}
long tennis_session_n_cands(TennisSession* s) {
  return s ? s->impl.n_cands() : 0;
}
char* tennis_session_tracks_json(TennisSession* s) {
  if (!s) return nullptr;
  return Dup(TracksJson(s->impl.tracks));
}
char* tennis_session_rallies_json(TennisSession* s) {
  if (!s) return nullptr;
  return Dup(RalliesJson(s->impl.rallies));
}

char* tennis_detect_court(const uint8_t* bgr, int w, int h) {
  try {
    return Dup(CalibJson(tennis::DetectCourt(bgr, w, h)));
  } catch (const std::exception& e) {
    SetErr(e.what());
    return nullptr;
  }
}

char* tennis_calibrate_frames(const uint8_t** bgrs, int n, int w, int h) {
  try {
    std::vector<const uint8_t*> v(bgrs, bgrs + n);
    return Dup(CalibJson(tennis::CalibrateFrames(v, w, h)));
  } catch (const std::exception& e) {
    SetErr(e.what());
    return nullptr;
  }
}

double* tennis_extract_candidates(const uint8_t* heat, int heat_w, int heat_h,
                                  int frame_w, int frame_h, int* n_cands) {
  if (n_cands) *n_cands = 0;
  if (!heat || !n_cands) return nullptr;
  try {
    std::vector<tennis::Candidate> cs =
        tennis::ExtractCandidates(heat, heat_w, heat_h, frame_w, frame_h);
    double* out = (double*)std::malloc(cs.size() * 3 * sizeof(double));
    if (!out && !cs.empty()) return nullptr;
    for (size_t i = 0; i < cs.size(); ++i) {
      out[3 * i] = cs[i].x;
      out[3 * i + 1] = cs[i].y;
      out[3 * i + 2] = cs[i].conf;
    }
    *n_cands = (int)cs.size();
    return out;
  } catch (const std::exception& e) {
    SetErr(e.what());
    return nullptr;
  }
}

int tennis_roi_find(const uint8_t* prev, const uint8_t* curr,
                    const uint8_t* next, int w, int h, double px, double py,
                    double radius, double* ox, double* oy, double* oconf) {
  if (!prev || !curr || !next || !ox || !oy || !oconf) return 0;
  try {
    tennis::RoiFound r =
        tennis::RoiFindBall(prev, curr, next, w, h, px, py, radius);
    if (!r.found) return 0;
    *ox = r.x;
    *oy = r.y;
    *oconf = r.conf;
    return 1;
  } catch (const std::exception& e) {
    SetErr(e.what());
    return 0;
  }
}

TennisDetector* tennis_detector_create(const char* model_path,
                                       const char* compile_cache) {
  std::string err;
  auto det = tennis::CreateDetector(model_path ? model_path : "",
                                    compile_cache ? compile_cache : "",
                                    "CPU_AND_NE", err);
  if (!det) {
    SetErr(err);
    return nullptr;
  }
  auto* d = new TennisDetector();
  d->device = det->device();
  d->impl = std::move(det);
  return d;
}

void tennis_detector_destroy(TennisDetector* d) { delete d; }

const char* tennis_detector_device(TennisDetector* d) {
  return d ? d->device.c_str() : "";
}
int tennis_detector_in_w(TennisDetector* d) {
  return d ? d->impl->in_w() : 0;
}
int tennis_detector_in_h(TennisDetector* d) {
  return d ? d->impl->in_h() : 0;
}

int tennis_detector_infer(TennisDetector* d, const uint8_t** bgrs, int n,
                          int w, int h, uint8_t** out_maps, int* out_w,
                          int* out_h, const int* cancel_flag) {
  if (!d || !out_maps || !out_w || !out_h) return -1;
  try {
    std::vector<const uint8_t*> v(bgrs, bgrs + n);
    tennis::HeatMaps hm = d->impl->HeatmapsFor(
        v, w, h, [&] { return cancel_flag && *cancel_flag; });
    *out_w = hm.w;
    *out_h = hm.h;
    uint8_t* buf =
        (uint8_t*)std::malloc((size_t)n * hm.w * hm.h);
    if (!buf) return -1;
    for (int i = 0; i < n; ++i)
      std::memcpy(buf + (size_t)i * hm.w * hm.h, hm.maps[i].data(),
                  (size_t)hm.w * hm.h);
    *out_maps = buf;
    return 0;
  } catch (const std::exception& e) {
    SetErr(e.what());
    return -1;
  }
}

}  // extern "C"
