#include "OnnxModel.hpp"

#include <onnxruntime_cxx_api.h>

namespace mxv {

namespace {

Ort::Env& sharedEnvironment() {
    static Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "MxOpenCVD");
    return env;
}

}  // namespace

struct OnnxModel::Impl {
    Ort::Session session{nullptr};
    std::string inputName;
    std::string outputName;
};

OnnxModel::OnnxModel(const std::string& path) : impl(std::make_unique<Impl>()) {
    Ort::SessionOptions options;
    options.SetIntraOpNumThreads(4);  // the performance cores; more only adds contention with capture
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    impl->session = Ort::Session(sharedEnvironment(), path.c_str(), options);

    Ort::AllocatorWithDefaultOptions allocator;
    impl->inputName = impl->session.GetInputNameAllocated(0, allocator).get();
    impl->outputName = impl->session.GetOutputNameAllocated(0, allocator).get();
}

OnnxModel::~OnnxModel() = default;

Tensor OnnxModel::run(const Tensor& input) {
    Ort::MemoryInfo memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    Ort::Value value = Ort::Value::CreateTensor<float>(memory, const_cast<float*>(input.data.data()), input.data.size(),
                                                       input.shape.data(), input.shape.size());
    const char* inputNames[] = {impl->inputName.c_str()};
    const char* outputNames[] = {impl->outputName.c_str()};
    std::vector<Ort::Value> outputs = impl->session.Run(Ort::RunOptions{nullptr}, inputNames, &value, 1, outputNames, 1);

    Ort::TensorTypeAndShapeInfo info = outputs[0].GetTensorTypeAndShapeInfo();
    Tensor result;
    result.shape = info.GetShape();
    const float* data = outputs[0].GetTensorData<float>();
    result.data.assign(data, data + info.GetElementCount());
    return result;
}

std::vector<int64_t> OnnxModel::inputShape() const {
    return impl->session.GetInputTypeInfo(0).GetTensorTypeAndShapeInfo().GetShape();
}

Tensor tensorFromImage(const cv::Mat& image) {
    CV_Assert(image.type() == CV_32FC3 && image.isContinuous());
    Tensor tensor;
    tensor.shape = {1, 3, image.rows, image.cols};
    tensor.data.resize(size_t(3 * image.rows * image.cols));
    float* b = tensor.data.data();
    float* g = b + image.total();
    float* r = g + image.total();
    const float* source = image.ptr<float>(0);
    for (size_t i = 0; i < image.total(); i++) {
        b[i] = source[i * 3];
        g[i] = source[i * 3 + 1];
        r[i] = source[i * 3 + 2];
    }
    return tensor;
}

}  // namespace mxv
