// Multi-ball tracker: linking, stitching, gap-fill, hits, bounces.
// Faithful port of tennis_ai/tracker.py — same defaults, same order of
// operations, same greedy tie-breaks.
#pragma once

#include <map>
#include <vector>

#include "tennis/types.hpp"

namespace tennis {

// frame -> candidates (any order; ingest sorts)
using FrameCands = std::map<int, std::vector<Candidate>>;

class IncrementalLinker {
 public:
  IncrementalLinker(double fps, int width,
                    const TrackerConfig& cfg = TrackerConfig());
  // Link one more batch (increasing frames, each once). Returns the
  // current tracklets (fresh objects, as if video ended at coverage).
  std::vector<Track> Ingest(const FrameCands& frames_cands);
  std::vector<Track> Tracklets() const;
  int coverage() const { return coverage_; }
  void set_min_length(int n) { cfg_.min_length = n; }

 private:
  struct Live {
    double x, y, vx = 0, vy = 0;
    int hits = 1, misses = 0, first = 0;
    double conf = 0;
    struct Pt {
      int f;
      double x, y, c;
    };
    std::vector<Pt> pts;
    int born_frame = 0, uid = 0;
    int last_f = 0;
  };
  void Kill(const Live& tr);
  bool Snapshot(const Live& tr, Track& out) const;

  TrackerConfig cfg_;
  double gate_base_;
  double s_ = 1.0;  // width / 1280
  std::vector<Live> live_;
  // Finished tracklets: (uid, pts) — Track objects rebuilt fresh per
  // Tracklets() call so downstream mutation can't corrupt snapshots.
  std::vector<std::pair<int, std::vector<Live::Pt>>> done_;
  int next_id_ = 1;
  int coverage_ = -1;
};

std::vector<Track> LinkCandidates(const FrameCands& fc, double fps, int width,
                                  const TrackerConfig& cfg = TrackerConfig());

std::vector<Track> DedupTracks(std::vector<Track> tracks, int width);
void DespikeTrack(Track& track, int width);
std::vector<Track> MergeOverlapHandovers(std::vector<Track> tracks, int width);
std::vector<Track> FillGaps(std::vector<Track> tracks,
                            const TrackerConfig& cfg = TrackerConfig());
std::vector<Track> StitchTracklets(std::vector<Track> tracks,
                                   const TrackerConfig& cfg = TrackerConfig());
std::vector<int> DetectShots(const Track& track, int width);
std::vector<int> DetectBounces(const Track& track, int width,
                               const CourtGeom* court = nullptr,
                               const std::vector<int>& shots = {});
void SmoothTrack(Track& track);
std::vector<Track> FinalizeTracks(std::vector<Track> tracks, int width,
                                  const TrackerConfig& cfg = TrackerConfig(),
                                  const CourtGeom* court = nullptr);
std::vector<Track> ResolveIntruders(std::vector<Track> tracks, int width,
                                    const CourtGeom* court = nullptr);

}  // namespace tennis
