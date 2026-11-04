"""Dump parity fixtures: real engine inputs + outputs as JSON.

Reads cached candidates + court calibration, runs the CURRENT Python
engine (the truth), and writes core/fixtures/ for the C++ parity test:
  - cands_<name>.csv     input candidates (full precision)
  - court_<name>.json    h_img2court + h_court2img (full precision)
  - expected_<name>.json tracks + rallies after each ingest stage
  - heat<N>.raw + meta   heatmaps + expected candidates (detect port)

Usage: PYTHONPATH=. .venv/bin/python core/tools/dump_fixtures.py
"""

import csv
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from tennis_ai.streaming import StreamSession, load_cands_file  # noqa: E402
from tennis_ai.tracker import TrackerConfig  # noqa: E402

FIX = os.path.join(ROOT, "core", "fixtures")
os.makedirs(FIX, exist_ok=True)

CASES = [
    # (name, cands csv, court json, fps, width)
    ("img8630",
     os.path.expanduser("~/.tennis_ai/cache/53323cf0d217f568/"
                        "cands_0p0_0p0pcsv"),
     os.path.expanduser("~/.tennis_ai/cache/53323cf0d217f568/court.json"),
     59.80670479689392, 1280),
    ("clip27a8",
     os.path.expanduser("~/.tennis_ai/cache/27a809eec692953a/"
                        "cands_5p0_10p0pcsv"),
     os.path.expanduser("~/.tennis_ai/cache/27a809eec692953a/court.json"),
     60.0, 1280),
    # Rich 19s segment (global + ROI-recovered candidates): covers
    # handover merge + junction hits, V-bounces, stray exclusion.
    ("rich19s",
     os.path.join(FIX, "src_rich19s.csv"),
     os.path.join(FIX, "src_rich19s_court.json"),
     59.80670479689392, 1280),
]


def load_court(path):
    import numpy as np
    from tennis_ai.court import CourtResult
    d = json.load(open(path))
    H = np.array(d["h_img2court"], float)
    court = CourtResult(h_img2court=H, h_court2img=np.linalg.inv(H),
                        keypoints=d.get("keypoints", []),
                        rms_px=d.get("rms_px", 0.0), lines=[])
    return court, d["width"], d["height"]


def dump_case(name, cands_csv, court_json, fps, width):
    court, W, H = load_court(court_json)
    assert W == width
    fc, _ = load_cands_file(cands_csv, W, H)
    # Full-precision candidate input for both engines.
    with open(os.path.join(FIX, f"cands_{name}.csv"), "w") as f:
        w = csv.writer(f)
        for i in sorted(fc):
            for c in fc[i]:
                w.writerow([i, repr(c.x), repr(c.y), repr(c.conf)])
    json.dump({"h_img2court": court.h_img2court.tolist(),
               "h_court2img": court.h_court2img.tolist()},
              open(os.path.join(FIX, f"court_{name}.json"), "w"))

    def snap(sess):
        tracks = [{"id": t.id,
                   "points": [[p.frame, p.x, p.y, p.observed, p.conf]
                              for p in t.points],
                   "hits": list(t.hits), "bounces": list(t.bounces)}
                  for t in sess.tracks]
        rallies = [{"index": r.index, "track_id": r.track_id,
                    "start": r.start, "end": r.end, "hits": list(r.hits),
                    "bounces": [{"frame": b.frame, "x": b.x, "y": b.y,
                                 "call": b.call, "wx": b.wx, "wy": b.wy}
                                for b in r.bounces],
                    "serve": r.serve_frame}
                   for r in sess.rallies]
        return {"tracks": tracks, "rallies": rallies}

    # Ingest in 3 stages to prove streaming equivalence too.
    frames = sorted(fc)
    n = len(frames)
    cuts = [frames[:n // 3], frames[n // 3:2 * n // 3], frames[2 * n // 3:]]
    # engine="python": fixtures are the PYTHON truth. "auto" would
    # silently use the C++ core when built, making parity circular.
    sess = StreamSession(fps, width, court, TrackerConfig(), engine="python")
    stages = []
    for part in cuts:
        sess.ingest({i: fc[i] for i in part})
        stages.append({"upto": part[-1], "n_cands": sess.n_cands,
                       **snap(sess)})
    json.dump({"fps": fps, "width": width, "stages": stages},
              open(os.path.join(FIX, f"expected_{name}.json"), "w"))
    fin = stages[-1]
    print(f"{name}: {len(fc)} cand-frames -> "
          f"{len(fin['tracks'])} tracks, {len(fin['rallies'])} rallies")


def dump_heats():
    import cv2
    import numpy as np
    from tennis_ai.backend import load_backend
    from tennis_ai.tracknet import extract_candidates
    src = os.path.join(ROOT, "input", "IMG_8630.MOV")
    cap = cv2.VideoCapture(src)
    cap.set(cv2.CAP_PROP_POS_FRAMES, 180)
    frames = []
    for _ in range(6):
        ret, img = cap.read()
        assert ret
        frames.append(cv2.resize(img, (1280, 720)))
    cap.release()
    be = load_backend("auto")
    print("heatmap backend:", be.device)
    maps = be.heatmaps_for(frames, batch_size=1)
    tests = []
    for k, h in enumerate(maps[2:5]):
        raw = os.path.join(FIX, f"heat{k}.raw")
        open(raw, "wb").write(np.ascontiguousarray(h).tobytes())
        cs = extract_candidates(h, 1280, 720)
        tests.append({"heat": f"heat{k}.raw", "w": h.shape[1],
                      "h": h.shape[0], "cands":
                      [[c.x, c.y, c.conf, c.area, c.peak] for c in cs]})
    # Turbo geometry branch (176x320): resized copy, same truth procedure.
    th = cv2.resize(maps[3], (320, 176), interpolation=cv2.INTER_NEAREST)
    open(os.path.join(FIX, "heat_turbo.raw"), "wb").write(
        np.ascontiguousarray(th).tobytes())
    cs = extract_candidates(th, 1280, 720)
    tests.append({"heat": "heat_turbo.raw", "w": 320, "h": 176, "cands":
                  [[c.x, c.y, c.conf, c.area, c.peak] for c in cs]})
    json.dump({"tests": tests}, open(os.path.join(FIX, "expected_detect.json"),
                                     "w"), indent=1)
    print("heats:", [(t["heat"], len(t["cands"])) for t in tests])


if __name__ == "__main__":
    for args in CASES:
        if os.path.exists(args[1]):
            dump_case(*args)
        else:
            print(f"SKIP {args[0]} (missing {args[1]})")
    if glob.glob(os.path.join(FIX, "heat*.raw")):
        print("heats already dumped, skipping")
    else:
        dump_heats()
    print("fixtures in", FIX)
