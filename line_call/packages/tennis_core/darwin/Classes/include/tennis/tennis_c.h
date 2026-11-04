// Stable C ABI over the tennis core: sessions, calibration, detection.
// JSON (UTF-8, malloc'd, release with tennis_free) carries results so no
// C++ types cross the boundary. Floats print at %.17g (exact round-trip).
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TennisSession TennisSession;
typedef struct TennisDetector TennisDetector;

const char* tennis_last_error(void);
void tennis_free(void* p);

// --- streaming session -----------------------------------------------
// h_img2court/h_court2img: row-major 3x3, or NULL for no calibration.
TennisSession* tennis_session_create(double fps, int width,
                                     const double* h_img2court,
                                     const double* h_court2img,
                                     int court_filter);
void tennis_session_destroy(TennisSession* s);
// Ingest frames in increasing order (each once): `frames`/`counts` have
// n_frames entries; xs/ys/confs are concatenated per-frame candidates.
int tennis_session_ingest(TennisSession* s, int n_frames, const int* frames,
                          const double* xs, const double* ys,
                          const double* confs, const int* counts);
int tennis_session_coverage(TennisSession* s);
// Retune gap stitching (sparse/Turbo candidates). Defaults: gap 30,
// resid 5.0; fast path uses 45 / 8.0. Applies from the next ingest.
void tennis_session_set_stitch(TennisSession* s, int gap, double resid);
// Lower the tracklet confirmation floor (default 8; fast path uses
// 6). Applies from the next ingest.
void tennis_session_set_min_length(TennisSession* s, int n);
long tennis_session_n_cands(TennisSession* s);
// [{"id","points":[[f,x,y,observed,conf]...],"hits":[],"bounces":[],
// "stray":bool}...]
char* tennis_session_tracks_json(TennisSession* s);
// [{"index","track_id","start","end","hits":[],"bounces":[{"frame","x","y",
// "call","wx","wy"}...],"serve":null|int}...]
char* tennis_session_rallies_json(TennisSession* s);

// --- calibration ------------------------------------------------------
// {"h_img2court":[[..]x3],"h_court2img":[[..]x3],"rms":..,
// "keypoints":[[x,y,wx,wy]...],"lines":[{"a","b","c","angle","length",
// "role","px","py","dx","dy","t0","t1"}...]} or NULL on failure.
char* tennis_detect_court(const uint8_t* bgr, int w, int h);
char* tennis_calibrate_frames(const uint8_t** bgrs, int n, int w, int h);

// --- candidate extraction ---------------------------------------------
// Candidates for one heat map as flat [x,y,conf]*; *n_cands set. Malloc'd.
double* tennis_extract_candidates(const uint8_t* heat, int heat_w, int heat_h,
                                  int frame_w, int frame_h, int* n_cands);

// --- foveal re-detection --------------------------------------------
// Search gray frames (w x h) for a small moving blob near (px,py).
// Returns 1 + sets *ox/*oy/*oconf on accept, else 0.
int tennis_roi_find(const uint8_t* prev, const uint8_t* curr,
                    const uint8_t* next, int w, int h, double px, double py,
                    double radius, double* ox, double* oy, double* oconf);

// --- inference (Apple builds; NULL elsewhere) --------------------------
TennisDetector* tennis_detector_create(const char* model_path,
                                       const char* compile_cache);
void tennis_detector_destroy(TennisDetector* d);
const char* tennis_detector_device(TennisDetector* d);  // borrowed
int tennis_detector_in_w(TennisDetector* d);
int tennis_detector_in_h(TennisDetector* d);
// One uint8 class map per frame (first two all-zero); out_w/h set to the
// map geometry. *out_maps is malloc'd (n*out_w*out_h bytes). cancel_flag
// (nullable) aborts between frames when nonzero; trailing maps are zero.
int tennis_detector_infer(TennisDetector* d, const uint8_t** bgrs, int n,
                          int w, int h, uint8_t** out_maps, int* out_w,
                          int* out_h, const int* cancel_flag);

#ifdef __cplusplus
}  // extern "C"
#endif
