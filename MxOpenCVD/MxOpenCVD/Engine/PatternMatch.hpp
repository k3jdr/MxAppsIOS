// Finds a taught part in an image: at any angle and tilt from features on its surface, from its edges, or with the
// exact search.
#pragma once

#include "EdgeMatch.hpp"
#include "Engine.hpp"

#include <opencv2/features2d.hpp>

#include <vector>

namespace mxv {

class PatternMatcher {
public:
    void run(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out);

private:
    struct Features {
        std::vector<cv::KeyPoint> points;
        cv::Mat descriptors;
    };
    enum Kind { ORB = 0, SIFT = 1 };

    const Features& patternFeatures(const cv::Mat& pattern, Kind kind);
    void findByFeatures(const cv::Mat& gray, const cv::Mat& pattern, cv::Rect roi, const ToolInput& input, ToolOutput& out);

    // Finding the pattern's features is the slow part of a small search, and they only change when it's taught again.
    cv::Mat cachedPattern;
    Features cached[2];
    bool haveCached[2] = {false, false};
    EdgeMatcher edges;
};

}  // namespace mxv
