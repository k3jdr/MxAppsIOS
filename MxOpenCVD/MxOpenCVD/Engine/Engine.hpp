// The vision engine: plain C++ on OpenCV and ONNX Runtime, with no Apple frameworks.
// Images are 8-bit BGR. Every coordinate that comes back is in full-image pixels.
#pragma once

#include <opencv2/core.hpp>

#include <array>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace mxv {

struct Measure {
    std::string name;
    double value = 0;
    std::string unit;
};

enum class OverlayStyle { Info, Good, Bad };

struct Overlay {
    std::vector<cv::Point2f> points;
    bool closed = true;
    std::string label;
    OverlayStyle style = OverlayStyle::Info;
};

// Everything training on a region gives, for whichever color tool uses it. The tolerances and the rest are the user's to change.
struct ColorReference {
    std::string name;
    std::array<double, 3> meanRGB{}, meanHSI{}, spreadRGB{}, spreadHSI{};
    std::array<double, 3> lowRGB{}, highRGB{}, lowHSI{}, highHSI{};  // from the mean: low is negative or 0, high positive or 0
    double softness = 0;   // Segmenter: the band beyond the tolerances. Extractor: how far grey fades beyond the volume.
    double dilation = 0;   // Extractor: grows the color volume, in RGB levels
    double matteLow = 0, matteHigh = 0, highlight = 0;  // Extractor: 0 to 1, how far the volume extends darker, brighter, toward white
    std::vector<uint32_t> voxels;  // Extractor: the occupied cells of a 64 × 64 × 64 RGB grid
    std::vector<float> histogram;  // Composite: a normalized 16 × 16 × 16 RGB histogram
};

struct ToolInput {
    cv::Rect roi;                              // empty means the whole image
    std::map<std::string, double> numbers;
    std::map<std::string, std::string> strings;
    cv::Mat templ;                             // the taught pattern (BGR), for "pattern"
    double mmPerPixel = 0;                     // 0 means uncalibrated
    std::vector<ColorReference> colors;        // for the color tools; ColorTools.hpp defines the type

    double number(const std::string& key, double fallback) const {
        auto it = numbers.find(key);
        return it == numbers.end() ? fallback : it->second;
    }
    std::string string(const std::string& key) const {
        auto it = strings.find(key);
        return it == strings.end() ? std::string() : it->second;
    }
};

struct ToolOutput {
    std::vector<Measure> measures;
    std::vector<std::string> texts;
    std::vector<Overlay> overlays;
    std::string error;
    double elapsedMs = 0;
};

struct ChessboardScale {
    bool found = false;
    double mmPerPixel = 0;
    std::vector<cv::Point2f> corners;
};

// cols and rows count the board's inner corners, not its squares.
ChessboardScale measureChessboard(const cv::Mat& bgr, int cols, int rows, double squareMM);

class Engine {
public:
    // modelsDir holds the PaddleOCR models. They load the first time the OCR tool runs.
    explicit Engine(std::string modelsDir);
    ~Engine();

    // Tool kinds: quality, blobs, caliper, pattern, contours, shapefit, colorsegmenter, colorextractor, colormatch,
    // compositecolor, ocr, onnx. Never throws: a failure is in .error.
    // The code-reading tool uses Apple Vision, so it's in Bridge/MXVEngine.mm.
    ToolOutput run(const std::string& kind, const cv::Mat& bgr, const ToolInput& input);

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};

// The classic tools (Tools.cpp). roi is already clipped to the image.
void runQuality(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out);
void runBlobs(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out);
void runCaliper(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out);

}  // namespace mxv
