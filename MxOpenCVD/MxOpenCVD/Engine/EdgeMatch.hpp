// Finds a taught part from the geometry of its edges rather than its surface: the mode for plain, machined or printed
// parts. Lighting barely matters, since it compares edge directions, not brightness, and the final position comes
// from a fit to the edges themselves, to a fraction of a pixel.
#pragma once

#include "Engine.hpp"

#include <vector>

namespace mxv {

// The strength that separates real edges from the rest, from a Sobel magnitude image, as a threshold splits brightness.
double automaticEdgeStrength(const cv::Mat& magnitude);

class EdgeMatcher {
public:
    void run(const cv::Mat& gray, const cv::Mat& pattern, cv::Rect roi, const ToolInput& input, ToolOutput& out);

    struct EdgePoint {
        float x, y;    // from the pattern's center, in pixels of this pyramid level
        float dx, dy;  // the brightness gradient's direction, as a unit vector
    };
    struct Level {
        std::vector<EdgePoint> points;   // in random order, which is what makes the search quick
        std::vector<EdgePoint> outline;  // the same points in order along each contour, on the finest level
        std::vector<size_t> contourEnds; // where each contour stops in outline
        float radius = 0;
    };

private:
    void build(const cv::Mat& pattern, double minEdge);

    // Building the model is slow compared with using it, and it only changes when the part is taught again.
    cv::Mat cachedPattern;
    double cachedEdge = -1;
    std::vector<Level> levels;
};

}  // namespace mxv
