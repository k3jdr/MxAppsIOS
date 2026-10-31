// Image quality, blob analysis and caliper, on OpenCV. Pattern matching is in PatternMatch.cpp.
#include "Engine.hpp"

#include <opencv2/calib3d.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>

namespace mxv {

namespace {

cv::Mat grayOf(const cv::Mat& bgr, cv::Rect roi) {
    cv::Mat gray;
    cv::cvtColor(bgr(roi), gray, cv::COLOR_BGR2GRAY);
    return gray;
}

std::vector<cv::Point2f> rectPoints(cv::Rect r) {
    return {cv::Point2f(float(r.x), float(r.y)), cv::Point2f(float(r.x + r.width), float(r.y)),
            cv::Point2f(float(r.x + r.width), float(r.y + r.height)), cv::Point2f(float(r.x), float(r.y + r.height))};
}

std::string fixed(double value, int digits) {
    return cv::format("%.*f", digits, value);
}

// A length with its calibrated value, when there is one: "412.0 px" or "12.36 mm".
std::string lengthLabel(double px, double mmPerPixel) {
    return mmPerPixel > 0 ? fixed(px * mmPerPixel, 2) + " mm" : fixed(px, 1) + " px";
}

}  // namespace

void runQuality(const cv::Mat& bgr, cv::Rect roi, const ToolInput&, ToolOutput& out) {
    cv::Mat gray = grayOf(bgr, roi);

    cv::Mat laplacian;
    cv::Laplacian(gray, laplacian, CV_64F);
    cv::Scalar lapMean, lapStd;
    cv::meanStdDev(laplacian, lapMean, lapStd);

    cv::Scalar mean, std;
    cv::meanStdDev(gray, mean, std);

    double total = double(gray.total());
    double bright = cv::countNonZero(gray >= 250) * 100.0 / total;
    double dark = cv::countNonZero(gray <= 5) * 100.0 / total;

    out.measures.push_back({"sharpness", lapStd[0] * lapStd[0], ""});
    out.measures.push_back({"brightness", mean[0], ""});
    out.measures.push_back({"contrast", std[0], ""});
    out.measures.push_back({"clipped_highlights", bright, "%"});
    out.measures.push_back({"clipped_shadows", dark, "%"});
    out.overlays.push_back({rectPoints(roi), true, "sharpness " + fixed(lapStd[0] * lapStd[0], 0), OverlayStyle::Info});
}

void runBlobs(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    cv::Mat gray = grayOf(bgr, roi);

    int blur = int(input.number("blur", 3));
    if (blur >= 3) {
        cv::GaussianBlur(gray, gray, cv::Size(blur | 1, blur | 1), 0);
    }

    bool darkObjects = input.number("polarity", 0) == 0;
    int type = darkObjects ? cv::THRESH_BINARY_INV : cv::THRESH_BINARY;
    int method = int(input.number("method", 0));
    cv::Mat mask;
    if (method == 1) {
        cv::threshold(gray, mask, input.number("threshold", 128), 255, type);
    } else if (method == 2) {
        int block = std::max(3, int(input.number("adaptiveBlock", 51))) | 1;
        cv::adaptiveThreshold(gray, mask, 255, cv::ADAPTIVE_THRESH_GAUSSIAN_C, type, block, input.number("adaptiveC", 8));
    } else {
        double level = cv::threshold(gray, mask, 0, 255, type | cv::THRESH_OTSU);
        out.measures.push_back({"threshold", level, ""});
    }

    int open = int(input.number("open", 0));
    if (open >= 2) {
        cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(open, open));
        cv::morphologyEx(mask, mask, cv::MORPH_OPEN, kernel);
    }

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(mask, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    double minArea = input.number("minArea", 25);
    double maxArea = input.number("maxArea", 0);
    bool dropBorder = input.number("dropBorder", 0) != 0;
    double mm = input.mmPerPixel;

    int count = 0;
    double totalArea = 0, largestArea = 0;
    int largest = -1;
    for (size_t i = 0; i < contours.size(); i++) {
        double area = cv::contourArea(contours[i]);
        if (area < minArea || (maxArea > 0 && area > maxArea)) {
            continue;
        }
        if (dropBorder) {
            cv::Rect box = cv::boundingRect(contours[i]);
            if (box.x <= 0 || box.y <= 0 || box.x + box.width >= roi.width || box.y + box.height >= roi.height) {
                continue;
            }
        }
        count++;
        totalArea += area;
        if (area > largestArea) {
            largestArea = area;
            largest = int(i);
        }
        if (count <= 200) {  // enough to read; more than this only slows the overlay down
            std::vector<cv::Point> simple;
            cv::approxPolyDP(contours[i], simple, 1.5, true);
            Overlay overlay;
            overlay.style = OverlayStyle::Good;
            for (const auto& p : simple) {
                overlay.points.emplace_back(float(p.x + roi.x), float(p.y + roi.y));
            }
            out.overlays.push_back(std::move(overlay));
        }
    }

    out.measures.push_back({"count", double(count), ""});
    out.measures.push_back({"total_area", mm > 0 ? totalArea * mm * mm : totalArea, mm > 0 ? "mm²" : "px²"});
    if (largest >= 0) {
        cv::RotatedRect box = cv::minAreaRect(contours[size_t(largest)]);
        double width = std::max(box.size.width, box.size.height);
        double height = std::min(box.size.width, box.size.height);
        out.measures.push_back({"largest_area", mm > 0 ? largestArea * mm * mm : largestArea, mm > 0 ? "mm²" : "px²"});
        out.measures.push_back({"largest_length", mm > 0 ? width * mm : width, mm > 0 ? "mm" : "px"});
        out.measures.push_back({"largest_width", mm > 0 ? height * mm : height, mm > 0 ? "mm" : "px"});

        cv::Point2f corners[4];
        box.points(corners);
        Overlay overlay;
        overlay.style = OverlayStyle::Info;
        overlay.label = lengthLabel(width, mm) + " × " + lengthLabel(height, mm);
        for (const auto& p : corners) {
            overlay.points.emplace_back(p.x + float(roi.x), p.y + float(roi.y));
        }
        out.overlays.push_back(std::move(overlay));
    }
}

void runCaliper(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    cv::Mat gray = grayOf(bgr, roi);
    bool horizontal = input.number("axis", 0) == 0;

    // Average across the scan direction, so noise averages out and a real edge stays.
    cv::Mat profile;
    cv::reduce(gray, profile, horizontal ? 0 : 1, cv::REDUCE_AVG, CV_32F);
    if (!horizontal) {
        profile = profile.t();
    }

    double sigma = input.number("smooth", 1.5);
    if (sigma > 0) {
        cv::GaussianBlur(profile, profile, cv::Size(0, 0), sigma, 0);
    }

    int n = profile.cols;
    std::vector<float> slope(size_t(n), 0.f);
    const float* p = profile.ptr<float>(0);
    for (int i = 1; i + 1 < n; i++) {
        slope[size_t(i)] = (p[i + 1] - p[i - 1]) / 2.f;
    }

    // An edge is a local peak in the slope's size, placed to a fraction of a pixel by a parabola.
    float minEdge = float(input.number("minEdge", 4));
    std::vector<double> edges;
    for (int i = 2; i + 2 < n; i++) {
        float here = std::abs(slope[size_t(i)]);
        float before = std::abs(slope[size_t(i - 1)]);
        float after = std::abs(slope[size_t(i + 1)]);
        if (here >= minEdge && here >= before && here > after) {
            float curve = before - 2 * here + after;
            double shift = curve != 0 ? 0.5 * (before - after) / curve : 0;
            edges.push_back(i + shift);
        }
    }

    double mm = input.mmPerPixel;
    out.measures.push_back({"edges", double(edges.size()), ""});

    auto line = [&](double at) {
        Overlay overlay;
        overlay.closed = false;
        overlay.style = OverlayStyle::Good;
        if (horizontal) {
            float x = float(roi.x + at);
            overlay.points = {cv::Point2f(x, float(roi.y)), cv::Point2f(x, float(roi.y + roi.height))};
        } else {
            float y = float(roi.y + at);
            overlay.points = {cv::Point2f(float(roi.x), y), cv::Point2f(float(roi.x + roi.width), y)};
        }
        return overlay;
    };
    for (double edge : edges) {
        out.overlays.push_back(line(edge));
    }

    if (edges.size() >= 2) {
        double distance = edges.back() - edges.front();
        out.measures.push_back({"distance", mm > 0 ? distance * mm : distance, mm > 0 ? "mm" : "px"});
        Overlay span;
        span.closed = false;
        span.style = OverlayStyle::Info;
        span.label = lengthLabel(distance, mm);
        if (horizontal) {
            float y = float(roi.y + roi.height / 2);
            span.points = {cv::Point2f(float(roi.x + edges.front()), y), cv::Point2f(float(roi.x + edges.back()), y)};
        } else {
            float x = float(roi.x + roi.width / 2);
            span.points = {cv::Point2f(x, float(roi.y + edges.front())), cv::Point2f(x, float(roi.y + edges.back()))};
        }
        out.overlays.push_back(std::move(span));
    }
}

ChessboardScale measureChessboard(const cv::Mat& bgr, int cols, int rows, double squareMM) {
    ChessboardScale result;
    cv::Mat gray;
    cv::cvtColor(bgr, gray, cv::COLOR_BGR2GRAY);
    if (!cv::findChessboardCornersSB(gray, cv::Size(cols, rows), result.corners)) {
        result.corners.clear();
        return result;
    }

    // The mean distance between neighbouring corners, along both directions of the board.
    double sum = 0;
    int pairs = 0;
    for (int y = 0; y < rows; y++) {
        for (int x = 0; x < cols; x++) {
            const cv::Point2f& p = result.corners[size_t(y * cols + x)];
            if (x + 1 < cols) {
                sum += cv::norm(p - result.corners[size_t(y * cols + x + 1)]);
                pairs++;
            }
            if (y + 1 < rows) {
                sum += cv::norm(p - result.corners[size_t((y + 1) * cols + x)]);
                pairs++;
            }
        }
    }
    result.found = pairs > 0;
    result.mmPerPixel = pairs > 0 ? squareMM / (sum / pairs) : 0;
    return result;
}

}  // namespace mxv
