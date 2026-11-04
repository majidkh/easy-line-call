"""Dump ROI fixtures: real blind-gap crops + empty-court negatives.

Positives: middle frames of long track gaps (the ball is there — the
global model just can't see it). Negatives: shifted predictions with no
candidate or track point nearby. Run once; roi_test consumes them.
"""

import os
import sys

import cv2
import numpy as np

sys.path.insert(0, ".")
from app.cache import load_cached_court  # noqa: E402
from tennis_ai.streaming import StreamSession, load_cands_file  # noqa: E402
from tennis_ai.tracker import TrackerConfig  # noqa: E402

FIX = "core/fixtures/roi"
os.makedirs(FIX, exist_ok=True)
W, H, R = 1280, 720, 80

v = "input/IMG_8630.MOV"
fps = 59.80670479689392
court, W, H = load_cached_court(v, 0, fps, tol_sec=1e9)
fc, _ = load_cands_file(
    os.path.expanduser("~/.tennis_ai/cache/53323cf0d217f568/cands_0p0_0p0pcsv"),
    W, H)
sess = StreamSession(fps, W, court, TrackerConfig(), engine="python")
sess.ingest({i: fc[i] for i in sorted(fc)})

cases = []  # (frame, px, py, expect_found, tag)
for t in sess.tracks:
    run = []
    for p in t.points:
        if not p.observed:
            run.append(p)
        elif run:
            if len(run) >= 8:
                m = run[len(run) // 2]
                cases.append((m.frame, m.x, m.y, True,
                              f"t{t.start}_gap{m.frame}"))
            run = []
cases = cases[:8]
print("positives:", [(c[0], c[4]) for c in cases])

# Negatives: shift until no candidate/track-point within 80px.
allpts = [(p.x, p.y) for t in sess.tracks for p in t.points]
for f, px, py, _, tag in list(cases)[:4]:
    for dx, dy in ((150, 100), (-150, 80), (120, -90), (-120, -60)):
        qx, qy = min(W - R - 1, max(R, px + dx)), min(
            H - R - 1, max(R, py + dy))
        ok = True
        for cf, cs in fc.items():
            if abs(cf - f) > 2:
                continue
            for c in cs:
                if np.hypot(c.x - qx, c.y - qy) < 80:
                    ok = False
        for ax, ay in allpts:
            if np.hypot(ax - qx, ay - qy) < 80:
                ok = False
        if ok:
            cases.append((f, qx, qy, False, tag + "_neg"))
            break
print("total cases:", len(cases))

import json
cap = cv2.VideoCapture(v)
exp = []
for i, (f, px, py, found, tag) in enumerate(cases):
    frs = []
    for k in (f - 1, f, f + 1):
        cap.set(cv2.CAP_PROP_POS_FRAMES, k)
        _, img = cap.read()
        frs.append(cv2.cvtColor(cv2.resize(img, (W, H)),
                                cv2.COLOR_BGR2GRAY))
    x0, y0 = int(px) - R, int(py) - R
    for name, g in zip("pcn", frs):
        crop = g[y0:y0 + 2 * R, x0:x0 + 2 * R]
        assert crop.shape == (2 * R, 2 * R), (tag, name, crop.shape)
        open(f"{FIX}/case{i}_{name}.raw", "wb").write(
            np.ascontiguousarray(crop).tobytes())
    full = cv2.cvtColor(frs[1], cv2.COLOR_GRAY2BGR)
    cv2.drawMarker(full, (int(px), int(py)), (0, 0, 255),
                   cv2.MARKER_CROSS, 30, 2)
    cv2.imwrite(f"{FIX}/case{i}_{tag}.png", full)
    exp.append({"case": i, "tag": tag, "frame": f, "pred": [R, R],
                "radius": R, "found": found})
cap.release()
json.dump(exp, open(f"{FIX}/expected_roi.json", "w"), indent=1)
print("wrote", FIX)
