// Color tools modeled on the capabilities Cognex documents for its Color Segmenter, Color Extractor, Color Match and
// Composite Color Match tools. Cognex doesn't publish its score formulas, so those here are this project's own.
#pragma once

#include "Engine.hpp"

#include <memory>
#include <vector>

namespace mxv {

// 0 to 255 on every plane. Hue is the angle on the color wheel, from red, scaled so that 360° is 256. Saturation 0 is grey,
// and a grey has no hue, so it reports 0. Intensity is the mean of R, G and B.
cv::Vec3f rgbToHsi(float r, float g, float b);

// The region's shape, from the tool's settings: 0 the rectangle, 1 the ellipse inside it. An empty result means all of it.
cv::Mat regionMask(cv::Size size, const ToolInput& input);

ColorReference trainColor(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input);

// Extractor volumes are slow to build compared with using them, and rarely change.
class ColorExtractorCache {
public:
    ColorExtractorCache();
    ~ColorExtractorCache();
    std::shared_ptr<const std::vector<uint8_t>> tableFor(const ColorReference& color);

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};

void runColorSegmenter(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out);
void runColorExtractor(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ColorExtractorCache& cache, ToolOutput& out);
void runColorMatch(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out);
void runCompositeColorMatch(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out);

}  // namespace mxv
