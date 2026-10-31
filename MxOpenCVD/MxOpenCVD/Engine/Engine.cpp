// The tool dispatcher, plus the two tools that need models: OCR and a user's own ONNX model.
#include "Engine.hpp"
#include "ColorTools.hpp"
#include "Contours.hpp"
#include "OnnxModel.hpp"
#include "PaddleOCR.hpp"
#include "PatternMatch.hpp"

#include <onnxruntime_cxx_api.h>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <numeric>

namespace mxv {

namespace {

std::vector<std::string> readLabels(const std::string& path) {
    std::vector<std::string> labels;
    if (path.empty()) {
        return labels;
    }
    std::ifstream file(path);
    std::string line;
    while (std::getline(file, line)) {
        labels.push_back(line);
    }
    return labels;
}

std::string labelFor(const std::vector<std::string>& labels, size_t index) {
    return index < labels.size() ? labels[index] : "class " + std::to_string(index);
}

// Size from the model when it fixes one, otherwise the tool's setting.
cv::Size modelInputSize(const OnnxModel& model, int fallback) {
    std::vector<int64_t> shape = model.inputShape();
    if (shape.size() == 4 && shape[2] > 0 && shape[3] > 0) {
        return cv::Size(int(shape[3]), int(shape[2]));
    }
    return cv::Size(fallback, fallback);
}

cv::Mat prepareInput(const cv::Mat& bgr, const ToolInput& input) {
    cv::Mat image;
    if (input.number("colorOrder", 1) == 1) {
        cv::cvtColor(bgr, image, cv::COLOR_BGR2RGB);
    } else {
        image = bgr;
    }
    cv::Mat floats;
    image.convertTo(floats, CV_32FC3, 1.0 / 255.0);
    if (input.number("normalization", 0) == 1) {
        bool rgb = input.number("colorOrder", 1) == 1;
        cv::Scalar mean = rgb ? cv::Scalar(0.485, 0.456, 0.406) : cv::Scalar(0.406, 0.456, 0.485);
        cv::Scalar std = rgb ? cv::Scalar(0.229, 0.224, 0.225) : cv::Scalar(0.225, 0.224, 0.229);
        cv::subtract(floats, mean, floats);
        cv::divide(floats, std, floats);
    }
    return floats.isContinuous() ? floats : floats.clone();
}

void runClassifier(OnnxModel& model, const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    cv::Mat resized;
    cv::resize(bgr(roi), resized, modelInputSize(model, 224));
    Tensor output = model.run(tensorFromImage(prepareInput(resized, input)));
    if (output.data.empty()) {
        out.error = "The model returned nothing.";
        return;
    }

    // Models that end in logits don't sum to one; put them through softmax so the score reads as a confidence.
    std::vector<double> scores(output.data.begin(), output.data.end());
    double sum = std::accumulate(scores.begin(), scores.end(), 0.0);
    bool isProbability = std::abs(sum - 1) < 0.01 && *std::min_element(scores.begin(), scores.end()) >= 0;
    if (!isProbability) {
        double highest = *std::max_element(scores.begin(), scores.end());
        double total = 0;
        for (double& s : scores) {
            s = std::exp(s - highest);
            total += s;
        }
        for (double& s : scores) {
            s /= total;
        }
    }

    size_t best = size_t(std::max_element(scores.begin(), scores.end()) - scores.begin());
    std::string label = labelFor(readLabels(input.string("labelsPath")), best);
    out.measures.push_back({"class", double(best), ""});
    out.measures.push_back({"score", scores[best], ""});
    out.texts.push_back(label);
    out.overlays.push_back({{cv::Point2f(float(roi.x), float(roi.y)), cv::Point2f(float(roi.x + roi.width), float(roi.y)),
                             cv::Point2f(float(roi.x + roi.width), float(roi.y + roi.height)),
                             cv::Point2f(float(roi.x), float(roi.y + roi.height))},
                            true, label + cv::format(" %.2f", scores[best]), OverlayStyle::Good});
}

struct Detection {
    cv::Rect2f box;
    float score;
    size_t cls;
};

// Decodes the common YOLO export: [1, N, 4 + classes] for v8-style, [1, N, 5 + classes] for v5-style with an
// objectness column, or the same with the last two dimensions swapped. Boxes are cx, cy, w, h in input pixels.
void runYolo(OnnxModel& model, const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    cv::Size size = modelInputSize(model, int(input.number("inputSize", 640)));
    cv::Mat crop = bgr(roi);

    // Letterbox, so the part keeps its proportions.
    double scale = std::min(double(size.width) / crop.cols, double(size.height) / crop.rows);
    cv::Mat resized;
    cv::resize(crop, resized, cv::Size(std::max(1, int(crop.cols * scale)), std::max(1, int(crop.rows * scale))));
    cv::Mat canvas(size, CV_8UC3, cv::Scalar(114, 114, 114));
    int offsetX = (size.width - resized.cols) / 2;
    int offsetY = (size.height - resized.rows) / 2;
    resized.copyTo(canvas(cv::Rect(offsetX, offsetY, resized.cols, resized.rows)));

    Tensor output = model.run(tensorFromImage(prepareInput(canvas, input)));
    if (output.shape.size() != 3) {
        out.error = "This model's output isn't a YOLO detection tensor (expected three dimensions).";
        return;
    }

    bool hasObjectness = input.number("yoloFormat", 0) == 1;
    bool channelsFirst = output.shape[1] < output.shape[2];
    size_t count = size_t(channelsFirst ? output.shape[2] : output.shape[1]);
    size_t attributes = size_t(channelsFirst ? output.shape[1] : output.shape[2]);
    size_t firstClass = hasObjectness ? 5 : 4;
    if (attributes <= firstClass) {
        out.error = "This model's output is too narrow for the chosen YOLO format.";
        return;
    }
    auto at = [&](size_t row, size_t col) {
        return output.data[channelsFirst ? col * count + row : row * attributes + col];
    };

    float minScore = float(input.number("confidence", 0.25));
    std::vector<Detection> found;
    for (size_t row = 0; row < count; row++) {
        size_t best = firstClass;
        for (size_t col = firstClass; col < attributes; col++) {
            if (at(row, col) > at(row, best)) {
                best = col;
            }
        }
        float score = at(row, best) * (hasObjectness ? at(row, 4) : 1.f);
        if (score < minScore) {
            continue;
        }
        float w = at(row, 2), h = at(row, 3);
        found.push_back({cv::Rect2f(at(row, 0) - w / 2, at(row, 1) - h / 2, w, h), score, best - firstClass});
    }

    // Greedy non-maximum suppression, class by class.
    std::sort(found.begin(), found.end(), [](const Detection& a, const Detection& b) { return a.score > b.score; });
    float maxOverlap = float(input.number("iou", 0.45));
    std::vector<Detection> kept;
    for (const Detection& candidate : found) {
        bool clashes = std::any_of(kept.begin(), kept.end(), [&](const Detection& other) {
            if (other.cls != candidate.cls) {
                return false;
            }
            float shared = (other.box & candidate.box).area();
            return shared / (other.box.area() + candidate.box.area() - shared) > maxOverlap;
        });
        if (!clashes) {
            kept.push_back(candidate);
        }
    }

    std::vector<std::string> labels = readLabels(input.string("labelsPath"));
    for (const Detection& detection : kept) {
        float x0 = float((detection.box.x - offsetX) / scale) + float(roi.x);
        float y0 = float((detection.box.y - offsetY) / scale) + float(roi.y);
        float x1 = x0 + float(detection.box.width / scale);
        float y1 = y0 + float(detection.box.height / scale);
        std::string label = labelFor(labels, detection.cls);
        out.texts.push_back(label);
        out.overlays.push_back({{cv::Point2f(x0, y0), cv::Point2f(x1, y0), cv::Point2f(x1, y1), cv::Point2f(x0, y1)},
                                true, label + cv::format(" %.2f", detection.score), OverlayStyle::Good});
    }
    out.measures.push_back({"count", double(kept.size()), ""});
    out.measures.push_back({"top_score", kept.empty() ? 0.0 : double(kept.front().score), ""});
}

}  // namespace

struct Engine::Impl {
    std::string modelsDir;
    std::unique_ptr<PaddleOCR> ocr;
    std::string customPath;
    std::unique_ptr<OnnxModel> customModel;
    PatternMatcher pattern;
    ColorExtractorCache colorTables;

    void runOcr(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
        if (!ocr) {
            ocr = std::make_unique<PaddleOCR>(modelsDir);
        }
        OcrOptions options;
        options.boxThreshold = input.number("boxThreshold", options.boxThreshold);
        options.unclipRatio = input.number("unclipRatio", options.unclipRatio);
        options.minTextScore = input.number("minTextScore", options.minTextScore);
        options.maxSide = int(input.number("maxSide", options.maxSide));
        options.checkOrientation = input.number("checkOrientation", 1) != 0;

        std::vector<OcrLine> lines = ocr->read(bgr(roi), options);
        double total = 0;
        for (const OcrLine& line : lines) {
            total += line.score;
            out.texts.push_back(line.text);
            Overlay overlay;
            overlay.style = OverlayStyle::Good;
            overlay.label = line.text;
            for (const auto& p : line.box) {
                overlay.points.emplace_back(p.x + float(roi.x), p.y + float(roi.y));
            }
            out.overlays.push_back(std::move(overlay));
        }
        out.measures.push_back({"lines", double(lines.size()), ""});
        out.measures.push_back({"mean_score", lines.empty() ? 0.0 : total / double(lines.size()), ""});
    }

    void runCustom(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
        std::string path = input.string("modelPath");
        if (path.empty()) {
            out.error = "Choose an ONNX model file first.";
            return;
        }
        if (path != customPath) {
            customModel.reset();
            customModel = std::make_unique<OnnxModel>(path);
            customPath = path;
        }
        if (input.number("modelMode", 0) == 1) {
            runYolo(*customModel, bgr, roi, input, out);
        } else {
            runClassifier(*customModel, bgr, roi, input, out);
        }
    }
};

Engine::Engine(std::string modelsDir) : impl(std::make_unique<Impl>()) {
    impl->modelsDir = std::move(modelsDir);
}

Engine::~Engine() = default;

ToolOutput Engine::run(const std::string& kind, const cv::Mat& bgr, const ToolInput& input) {
    ToolOutput out;
    auto started = std::chrono::steady_clock::now();
    try {
        CV_Assert(bgr.type() == CV_8UC3 && !bgr.empty());
        cv::Rect full(0, 0, bgr.cols, bgr.rows);
        cv::Rect roi = input.roi.empty() ? full : (input.roi & full);
        if (roi.width < 2 || roi.height < 2) {
            out.error = "The region of interest is outside the image.";
        } else if (kind == "quality") {
            runQuality(bgr, roi, input, out);
        } else if (kind == "blobs") {
            runBlobs(bgr, roi, input, out);
        } else if (kind == "caliper") {
            runCaliper(bgr, roi, input, out);
        } else if (kind == "pattern") {
            impl->pattern.run(bgr, roi, input, out);
        } else if (kind == "contours") {
            runContours(bgr, roi, input, out);
        } else if (kind == "shapefit") {
            runShapeFit(bgr, roi, input, out);
        } else if (kind == "colorsegmenter") {
            runColorSegmenter(bgr, roi, input, out);
        } else if (kind == "colorextractor") {
            runColorExtractor(bgr, roi, input, impl->colorTables, out);
        } else if (kind == "colormatch") {
            runColorMatch(bgr, roi, input, out);
        } else if (kind == "compositecolor") {
            runCompositeColorMatch(bgr, roi, input, out);
        } else if (kind == "ocr") {
            impl->runOcr(bgr, roi, input, out);
        } else if (kind == "onnx") {
            impl->runCustom(bgr, roi, input, out);
        } else {
            out.error = "Unknown tool: " + kind;
        }
    } catch (const Ort::Exception& e) {
        out.error = std::string("ONNX Runtime: ") + e.what();
    } catch (const cv::Exception& e) {
        out.error = std::string("OpenCV: ") + e.err;
    } catch (const std::exception& e) {
        out.error = e.what();
    }
    out.elapsedMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    return out;
}

}  // namespace mxv
