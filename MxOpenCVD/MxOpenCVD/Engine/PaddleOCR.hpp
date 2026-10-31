// PaddleOCR's PP-OCRv5 pipeline on ONNX Runtime: find text lines, turn upside-down ones over, read them.
#pragma once

#include "OnnxModel.hpp"

#include <opencv2/core.hpp>

#include <array>
#include <memory>
#include <string>
#include <vector>

namespace mxv {

struct OcrLine {
    std::string text;
    double score = 0;
    std::array<cv::Point2f, 4> box;  // clockwise from the top left, in the image passed to read()
};

struct OcrOptions {
    double binaryThreshold = 0.3;
    double boxThreshold = 0.6;
    double unclipRatio = 1.5;
    double minTextScore = 0.5;
    int maxSide = 960;
    bool checkOrientation = true;
};

class PaddleOCR {
public:
    // Throws if a model or the dictionary can't be loaded from modelsDir.
    explicit PaddleOCR(const std::string& modelsDir);

    std::vector<OcrLine> read(const cv::Mat& bgr, const OcrOptions& options);

private:
    std::vector<std::array<cv::Point2f, 4>> detect(const cv::Mat& bgr, const OcrOptions& options);
    cv::Mat crop(const cv::Mat& bgr, const std::array<cv::Point2f, 4>& box) const;
    bool isUpsideDown(const cv::Mat& line);
    OcrLine recognize(const cv::Mat& line);

    std::unique_ptr<OnnxModel> detector;
    std::unique_ptr<OnnxModel> orientation;
    std::unique_ptr<OnnxModel> recognizer;
    std::vector<std::string> dictionary;  // index 0 is the CTC blank, the last is a space
};

}  // namespace mxv
