// SetMatch-side pixel helpers for the muse2 core (not part of muse2).
// The core consumes OpenCV-convention BGR / gray buffers; these convert
// the RGBA frames Flutter decodes, with OpenCV's exact arithmetic.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Tightly packed RGBA (w*h*4) -> BGR (w*h*3).
void sm_rgba_to_bgr(const uint8_t* rgba, int w, int h, uint8_t* bgr);

// BGR -> gray, bit-exact with cv2.cvtColor(COLOR_BGR2GRAY).
void sm_bgr_to_gray(const uint8_t* bgr, int w, int h, uint8_t* gray);

// BGR bilinear resize via the core's img::ResizeBilinear. Returns 0 on success.
int sm_resize_bgr(const uint8_t* src, int w, int h, uint8_t* dst, int dw,
                  int dh);

// One decoded video frame as OpenCV would deliver it to muse2:
// cv2.VideoCapture (FFmpeg/swscale: BT.601 limited-range YUV->BGR, nearest
// chroma, HDR tags ignored) followed by cv2.resize(INTER_LINEAR) to
// dw x dh. Source is NV12 video range (Y plane + interleaved CbCr) at
// sw x sh, rotated by rot_cw (0/90/180/270, the track's display rotation)
// before resizing. Writes tightly packed RGBA. Returns 0 on success.
int sm_nv12_to_rgba_cv(const uint8_t* y, int y_stride, const uint8_t* uv,
                       int uv_stride, int sw, int sh, int rot_cw,
                       uint8_t* rgba, int dw, int dh);

#ifdef __cplusplus
}  // extern "C"
#endif
