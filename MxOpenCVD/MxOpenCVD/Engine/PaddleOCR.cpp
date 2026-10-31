#include "PaddleOCR.hpp"

#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>
#include <fstream>
#include <stdexcept>

namespace mxv {

namespace {

// Values from each model's inference.yml. The ImageNet mean and std are applied to the BGR channels
// in that order, which is how PaddleOCR itself feeds these models.
const cv::Scalar kImageNetMean(0.485, 0.456, 0.406);
const cv::Scalar kImageNetStd(0.229, 0.224, 0.225);
const int kRecHeight = 48;
const int kRecMinWidth = 320;
const int kRecMaxWidth = 3200;

cv::Mat normalized(const cv::Mat& bgr, const cv::Scalar& mean, const cv::Scalar& std) {
    cv::Mat image;
    bgr.convertTo(image, CV_32FC3, 1.0 / 255.0);
    cv::subtract(image, mean, image);
    cv::divide(image, std, image);
    return image.isContinuous() ? image : image.clone();
}

std::array<cv::Point2f, 4> orderedClockwise(const cv::Point2f (&points)[4]) {
    // Top left has the smallest x + y, bottom right the largest; the other two split on y - x.
    std::array<cv::Point2f, 4> out;
    float minSum = 1e9f, maxSum = -1e9f, minDiff = 1e9f, maxDiff = -1e9f;
    for (int i = 0; i < 4; i++) {
        float sum = points[i].x + points[i].y;
        float diff = points[i].y - points[i].x;
        if (sum < minSum) { minSum = sum; out[0] = points[i]; }
        if (sum > maxSum) { maxSum = sum; out[2] = points[i]; }
        if (diff < minDiff) { minDiff = diff; out[1] = points[i]; }
        if (diff > maxDiff) { maxDiff = diff; out[3] = points[i]; }
    }
    return out;
}

}  // namespace

PaddleOCR::PaddleOCR(const std::string& modelsDir) {
    detector = std::make_unique<OnnxModel>(modelsDir + "/ppocrv5_mobile_det.onnx");
    orientation = std::make_unique<OnnxModel>(modelsDir + "/pplcnet_x025_textline_ori.onnx");
    recognizer = std::make_unique<OnnxModel>(modelsDir + "/en_ppocrv5_mobile_rec.onnx");

    std::ifstream file(modelsDir + "/en_ppocrv5_mobile_rec_dict.txt");
    if (!file) {
        throw std::runtime_error("The OCR dictionary is missing from " + modelsDir);
    }
    dictionary.push_back("");  // the CTC blank
    std::string line;
    while (std::getline(file, line)) {
        dictionary.push_back(line);
    }
    dictionary.push_back(" ");
}

std::vector<OcrLine> PaddleOCR::read(const cv::Mat& bgr, const OcrOptions& options) {
    std::vector<OcrLine> lines;
    for (const auto& box : detect(bgr, options)) {
        cv::Mat line = crop(bgr, box);
        if (line.empty()) {
            continue;
        }
        if (options.checkOrientation && isUpsideDown(line)) {
            cv::rotate(line, line, cv::ROTATE_180);
        }
        OcrLine result = recognize(line);
        result.box = box;
        if (!result.text.empty() && result.score >= options.minTextScore) {
            lines.push_back(std::move(result));
        }
    }

    // Reading order: top to bottom, and left to right within a line.
    std::stable_sort(lines.begin(), lines.end(), [](const OcrLine& a, const OcrLine& b) {
        float height = std::max(cv::norm(a.box[3] - a.box[0]), cv::norm(b.box[3] - b.box[0]));
        if (std::abs(a.box[0].y - b.box[0].y) < height / 2) {
            return a.box[0].x < b.box[0].x;
        }
        return a.box[0].y < b.box[0].y;
    });
    return lines;
}

std::vector<std::array<cv::Point2f, 4>> PaddleOCR::detect(const cv::Mat& bgr, const OcrOptions& options) {
    // The detector needs sides that are multiples of 32. Small regions are enlarged, because a tight
    // region of interest around a label is the normal case on a close-up camera.
    int longest = std::max(bgr.cols, bgr.rows);
    double scale = 1.0;
    if (longest > options.maxSide) {
        scale = double(options.maxSide) / longest;
    } else if (longest < 640) {
        scale = 640.0 / longest;
    }
    int width = std::max(32, int(std::lround(bgr.cols * scale / 32)) * 32);
    int height = std::max(32, int(std::lround(bgr.rows * scale / 32)) * 32);

    cv::Mat resized;
    cv::resize(bgr, resized, cv::Size(width, height), 0, 0, scale < 1 ? cv::INTER_AREA : cv::INTER_LINEAR);

    Tensor output = detector->run(tensorFromImage(normalized(resized, kImageNetMean, kImageNetStd)));
    CV_Assert(output.shape.size() == 4);
    cv::Mat probability(int(output.shape[2]), int(output.shape[3]), CV_32F, output.data.data());

    cv::Mat mask = probability > options.binaryThreshold;
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(mask, contours, cv::RETR_LIST, cv::CHAIN_APPROX_SIMPLE);

    double scaleX = double(bgr.cols) / probability.cols;
    double scaleY = double(bgr.rows) / probability.rows;

    std::vector<std::array<cv::Point2f, 4>> boxes;
    for (const auto& contour : contours) {
        if (contour.size() < 4) {
            continue;
        }
        cv::Rect bounds = cv::boundingRect(contour);
        cv::Mat inside = cv::Mat::zeros(bounds.size(), CV_8U);
        std::vector<std::vector<cv::Point>> shifted{contour};
        for (auto& p : shifted[0]) {
            p -= bounds.tl();
        }
        cv::fillPoly(inside, shifted, cv::Scalar(255));
        if (cv::mean(probability(bounds), inside)[0] < options.boxThreshold) {
            continue;
        }

        // The model finds a shrunken core of each line. DB's unclip grows it back by area / perimeter.
        double area = cv::contourArea(contour);
        double perimeter = cv::arcLength(contour, true);
        if (perimeter <= 0) {
            continue;
        }
        float grow = float(area * options.unclipRatio / perimeter);
        cv::RotatedRect rect = cv::minAreaRect(contour);
        rect.size.width += 2 * grow;
        rect.size.height += 2 * grow;
        if (std::min(rect.size.width, rect.size.height) < 5) {
            continue;
        }

        cv::Point2f corners[4];
        rect.points(corners);
        for (auto& p : corners) {
            p.x = std::clamp(float(p.x * scaleX), 0.f, float(bgr.cols - 1));
            p.y = std::clamp(float(p.y * scaleY), 0.f, float(bgr.rows - 1));
        }
        boxes.push_back(orderedClockwise(corners));
    }
    return boxes;
}

cv::Mat PaddleOCR::crop(const cv::Mat& bgr, const std::array<cv::Point2f, 4>& box) const {
    int width = int(std::max(cv::norm(box[0] - box[1]), cv::norm(box[2] - box[3])));
    int height = int(std::max(cv::norm(box[0] - box[3]), cv::norm(box[1] - box[2])));
    if (width < 2 || height < 2) {
        return {};
    }
    cv::Point2f target[4] = {cv::Point2f(0, 0), cv::Point2f(float(width), 0), cv::Point2f(float(width), float(height)),
                             cv::Point2f(0, float(height))};
    cv::Mat transform = cv::getPerspectiveTransform(box.data(), target);
    cv::Mat line;
    cv::warpPerspective(bgr, line, transform, cv::Size(width, height), cv::INTER_CUBIC, cv::BORDER_REPLICATE);
    if (double(line.rows) / line.cols >= 1.5) {  // a vertical line: lay it on its side
        cv::rotate(line, line, cv::ROTATE_90_COUNTERCLOCKWISE);
    }
    return line;
}

bool PaddleOCR::isUpsideDown(const cv::Mat& line) {
    cv::Mat resized;
    cv::resize(line, resized, cv::Size(160, 80));
    Tensor output = orientation->run(tensorFromImage(normalized(resized, kImageNetMean, kImageNetStd)));
    CV_Assert(output.data.size() == 2);
    return output.data[1] > output.data[0] && output.data[1] > 0.9f;
}

OcrLine PaddleOCR::recognize(const cv::Mat& line) {
    int resizedWidth = std::clamp(int(std::ceil(double(line.cols) * kRecHeight / line.rows)), 1, kRecMaxWidth);
    int width = std::max(resizedWidth, kRecMinWidth);

    cv::Mat resized;
    cv::resize(line, resized, cv::Size(resizedWidth, kRecHeight));
    cv::Mat image = normalized(resized, cv::Scalar(0.5, 0.5, 0.5), cv::Scalar(0.5, 0.5, 0.5));

    // Pad on the right with zeros, the same as PaddleOCR.
    cv::Mat padded = cv::Mat::zeros(kRecHeight, width, CV_32FC3);
    image.copyTo(padded(cv::Rect(0, 0, resizedWidth, kRecHeight)));

    Tensor output = recognizer->run(tensorFromImage(padded));
    CV_Assert(output.shape.size() == 3);
    size_t steps = size_t(output.shape[1]);
    size_t classes = size_t(output.shape[2]);
    CV_Assert(classes == dictionary.size());

    // CTC: the best class at each step, dropping repeats and blanks.
    OcrLine result;
    double total = 0;
    int kept = 0;
    size_t previous = 0;
    for (size_t t = 0; t < steps; t++) {
        const float* row = output.data.data() + t * classes;
        size_t best = size_t(std::max_element(row, row + classes) - row);
        if (best != 0 && best != previous) {
            result.text += dictionary[best];
            total += row[best];
            kept++;
        }
        previous = best;
    }
    result.score = kept > 0 ? total / kept : 0;
    return result;
}

}  // namespace mxv
