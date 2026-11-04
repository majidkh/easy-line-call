# Easy Line Call

Phone-first tennis line calling (Flutter, landscape everywhere): pick a
video or the live camera → calibrate on the court → track balls and bounces
→ challenge any call with a zoomed ±0.5 s review.

Author: Majid Khosravi

Copyright © 2026 Majid Khosravi. All rights reserved.

## Demo

[![Easy Line Call demo](https://img.youtube.com/vi/TYcUK3Q8nB0/maxresdefault.jpg)](https://www.youtube.com/watch?v=TYcUK3Q8nB0)

## Layout

- `line_call/` — the app. Build it with `./build_linecall.sh [mac|ios|android|web]`
  (see `line_call/README.md`).
- `core/` — the C++ engine source (court fit, ball detector glue, tracking
  sessions). Shipped into the app via `line_call/packages/tennis_core`.
- `models/` — model files (`BallHeatTurbo.mlpackage`, TrackNet weights).
- `input/` — test videos.
- `old/` — previous attempts (Qt desktop, Kivy umpire, web single-file,
  earlier Flutter shell). Safe to delete once you are happy with the app.
