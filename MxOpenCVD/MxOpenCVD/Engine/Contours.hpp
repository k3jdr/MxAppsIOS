// Contour extraction, to a fraction of a pixel: the outlines themselves as data to measure, fit shapes to, or export.
#pragma once

#include "Engine.hpp"

#include <vector>

namespace mxv {

struct Contour {
    std::vector<cv::Point2f> points;
    bool closed = false;
    bool hole = false;           // the inside edge of a hole; only threshold extraction can tell
    bool touchesBorder = false;  // reaches the edge of the region, so it's cut off there
    double length = 0;           // in pixels
    double area = 0;             // in square pixels; zero if open
};

// Outlines in `gray`, in its own coordinates, after the tool's filters.
std::vector<Contour> extractContours(const cv::Mat& gray, const ToolInput& input);

void runContours(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out);
void runShapeFit(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out);

}  // namespace mxv
