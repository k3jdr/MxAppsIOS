// One ONNX Runtime session, with the little bit of tensor handling the tools share.
#pragma once

#include <opencv2/core.hpp>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace mxv {

struct Tensor {
    std::vector<float> data;
    std::vector<int64_t> shape;
};

class OnnxModel {
public:
    // Throws Ort::Exception if the model can't be loaded.
    explicit OnnxModel(const std::string& path);
    ~OnnxModel();

    // Runs on one float input and returns the first output, which must also be float.
    Tensor run(const Tensor& input);

    // The first input's shape; a dimension the model leaves open is -1.
    std::vector<int64_t> inputShape() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};

// A 3-channel CV_32F image as a 1 × 3 × H × W tensor.
Tensor tensorFromImage(const cv::Mat& floatImage);

}  // namespace mxv
