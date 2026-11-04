// Rally segmentation + court filtering. Port of tennis_ai/rally.py.
#pragma once

#include <string>
#include <vector>

#include "tennis/types.hpp"

namespace tennis {

const Track* PickMainTrack(const std::vector<Track>& tracks,
                           const CourtGeom* court, int width);
std::vector<Rally> SegmentRallies(const Track& track, double fps, int width,
                                  const CourtGeom* court);
bool TrackOnCourt(const Track& track, const CourtGeom* court);
// call ("IN"/"OUT"/"?"), world x/y. court==nullptr -> "?".
void JudgeBounce(double x, double y, const CourtGeom* court, std::string& call,
                 double& wx, double& wy);
std::vector<Track> FilterTracksToCourt(std::vector<Track> tracks,
                                       const CourtGeom* court, int width);
std::vector<Rally> SegmentAllTracks(const std::vector<Track>& tracks,
                                    double fps, int width,
                                    const CourtGeom* court);

}  // namespace tennis
