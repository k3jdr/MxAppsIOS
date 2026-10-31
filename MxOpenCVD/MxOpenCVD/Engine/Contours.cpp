#include "Contours.hpp"

#include "EdgeMatch.hpp"

#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>

namespace mxv {

namespace {

const float kWeakestEdge = 16;  // Sobel response below which a point has no edge to refine against
const double kLeastPointsPerPixel = 0.5;  // along a fitted shape, below which it's chance rather than an edge
const int kShortestRun = 15;              // points in a row along a contour that count as really following a shape
const double kLeastConnectedShare = 0.5;  // of the agreeing points, the share that must be in such runs

float sampleBilinear(const cv::Mat& image, double x, double y) {
    int ix = int(std::floor(x)), iy = int(std::floor(y));
    if (ix < 0 || iy < 0 || ix + 1 >= image.cols || iy + 1 >= image.rows) {
        return 0;
    }
    float fx = float(x - ix), fy = float(y - iy);
    const float* top = image.ptr<float>(iy);
    const float* bottom = image.ptr<float>(iy + 1);
    return (top[ix] * (1 - fx) + top[ix + 1] * fx) * (1 - fy) + (bottom[ix] * (1 - fx) + bottom[ix + 1] * fx) * fy;
}

struct Gradients {
    cv::Mat gx, gy, magnitude;
};

// Moves each traced pixel to where the edge really peaks, along the direction it faces. Whole-pixel tracing runs along
// the inside of a shape, which would make every outline half a pixel too small, and that's the larger part of its error.
std::vector<cv::Point2f> refinePoints(const std::vector<cv::Point>& chain, const Gradients& g) {
    const double reach = 1.5, step = 0.25;
    std::vector<cv::Point2f> refined;
    refined.reserve(chain.size());
    for (const cv::Point& p : chain) {
        float gx = g.gx.at<float>(p), gy = g.gy.at<float>(p);
        float size = g.magnitude.at<float>(p);
        if (size < kWeakestEdge) {
            refined.emplace_back(float(p.x), float(p.y));
            continue;
        }
        double nx = gx / size, ny = gy / size;
        // The nearest crest, not the strongest within reach, so a thin feature's far edge can't capture it. It's judged a
        // whole pixel to each side: a sharp edge falling exactly between two pixels gives them equal strength, and with
        // closer samples that flat top reads as a crest at its far end, half a pixel out.
        double bestT = 0;
        bool found = false;
        for (double distance = 0; distance <= reach && !found; distance += step) {
            for (double sign : {1.0, -1.0}) {
                double t = sign * distance;
                float here = sampleBilinear(g.magnitude, p.x + t * nx, p.y + t * ny);
                float before = sampleBilinear(g.magnitude, p.x + (t - 1) * nx, p.y + (t - 1) * ny);
                float after = sampleBilinear(g.magnitude, p.x + (t + 1) * nx, p.y + (t + 1) * ny);
                if (here >= before && here >= after && here >= kWeakestEdge) {
                    float curve = before - 2 * here + after;
                    bestT = t + (curve < 0 ? std::clamp(0.5 * double(before - after) / double(curve), -0.5, 0.5) : 0.0);
                    found = true;
                    break;
                }
            }
        }
        refined.emplace_back(float(p.x + bestT * nx), float(p.y + bestT * ny));
    }
    return refined;
}

// Light smoothing along the contour, to take out the noise that would otherwise inflate its measured length.
std::vector<cv::Point2f> smoothAlong(const std::vector<cv::Point2f>& points, bool closed, double sigma) {
    int n = int(points.size());
    if (sigma <= 0 || n < 5) {
        return points;
    }
    int half = std::min(n / 2, std::max(1, int(std::ceil(sigma * 3))));
    std::vector<float> weights(size_t(half) + 1);
    for (int k = 0; k <= half; k++) {
        weights[size_t(k)] = float(std::exp(-0.5 * k * k / (sigma * sigma)));
    }
    std::vector<cv::Point2f> smoothed(points.size());
    for (int i = 0; i < n; i++) {
        cv::Point2f sum = points[size_t(i)] * weights[0];
        float used = weights[0];
        for (int k = 1; k <= half; k++) {
            int a = i - k, b = i + k;
            if (closed) {
                a = (a + n) % n;
                b = b % n;
            } else if (a < 0 || b >= n) {
                break;  // the ends of an open contour stay where they are, or it would shrink
            }
            sum += (points[size_t(a)] + points[size_t(b)]) * weights[size_t(k)];
            used += 2 * weights[size_t(k)];
        }
        smoothed[size_t(i)] = sum * (1 / used);
    }
    return smoothed;
}

// Follows Canny's one-pixel-wide edges into chains. findContours is the wrong tool here: it walks around the outside of
// a thin line, so an open edge comes back as a closed loop, traced there and back.
std::vector<std::pair<std::vector<cv::Point>, bool>> linkEdges(const cv::Mat& edges) {
    static const cv::Point steps[8] = {{1, 0}, {0, 1}, {-1, 0}, {0, -1}, {1, 1}, {-1, 1}, {-1, -1}, {1, -1}};  // straight ones first
    cv::Mat visited = cv::Mat::zeros(edges.size(), CV_8U);
    auto isEdge = [&](cv::Point p) {
        return p.x >= 0 && p.y >= 0 && p.x < edges.cols && p.y < edges.rows && edges.at<uchar>(p) != 0;
    };
    auto walk = [&](cv::Point start) {
        std::vector<cv::Point> chain{start};
        visited.at<uchar>(start) = 1;
        cv::Point here = start;
        while (true) {
            bool moved = false;
            for (const cv::Point& step : steps) {
                cv::Point next = here + step;
                if (isEdge(next) && !visited.at<uchar>(next)) {
                    visited.at<uchar>(next) = 1;
                    chain.push_back(next);
                    here = next;
                    moved = true;
                    break;
                }
            }
            if (!moved) {
                return chain;
            }
        }
    };

    std::vector<std::pair<std::vector<cv::Point>, bool>> chains;
    // Open edges first, from their ends, so a loop's walk can't start partway along one of them.
    for (int y = 0; y < edges.rows; y++) {
        for (int x = 0; x < edges.cols; x++) {
            cv::Point p(x, y);
            if (!isEdge(p) || visited.at<uchar>(p)) {
                continue;
            }
            int neighbours = 0;
            for (const cv::Point& step : steps) {
                neighbours += isEdge(p + step) ? 1 : 0;
            }
            if (neighbours == 1) {
                chains.emplace_back(walk(p), false);
            }
        }
    }
    for (int y = 0; y < edges.rows; y++) {
        for (int x = 0; x < edges.cols; x++) {
            cv::Point p(x, y);
            if (isEdge(p) && !visited.at<uchar>(p)) {
                std::vector<cv::Point> chain = walk(p);
                cv::Point gap = chain.front() - chain.back();
                bool closes = chain.size() >= 8 && std::abs(gap.x) <= 1 && std::abs(gap.y) <= 1;
                chains.emplace_back(std::move(chain), closes);
            }
        }
    }
    return chains;
}

// The contour's size, shape and position, as the measures report them.
struct Shape {
    double cx = 0, cy = 0, degrees = 0, aspect = 1, circularity = 0, convexity = 0;
    int corners = 0;
};

Shape describe(const Contour& contour, double cornerTolerance) {
    Shape shape;
    cv::Moments moments = cv::moments(contour.points);
    if (contour.closed && std::abs(moments.m00) > 1e-6) {
        shape.cx = moments.m10 / moments.m00;
        shape.cy = moments.m01 / moments.m00;
        // Image y runs down, so this is the angle as seen: positive turns counter-clockwise.
        shape.degrees = -0.5 * std::atan2(2 * moments.mu11, moments.mu20 - moments.mu02) * 180 / CV_PI;
    } else {
        cv::Scalar mean = cv::mean(contour.points);
        shape.cx = mean[0];
        shape.cy = mean[1];
    }
    cv::RotatedRect box = cv::minAreaRect(contour.points);
    double longer = std::max(box.size.width, box.size.height), shorter = std::min(box.size.width, box.size.height);
    shape.aspect = shorter > 0 ? longer / shorter : 0;
    if (contour.closed && contour.length > 0) {
        shape.circularity = std::min(1.0, 4 * CV_PI * contour.area / (contour.length * contour.length));
        std::vector<cv::Point2f> hull;
        cv::convexHull(contour.points, hull);
        double hullArea = cv::contourArea(hull);
        shape.convexity = hullArea > 0 ? contour.area / hullArea : 0;
        std::vector<cv::Point2f> corners;
        cv::approxPolyDP(contour.points, corners, cornerTolerance, true);
        shape.corners = int(corners.size());
    }
    return shape;
}

// Mirrors a measure's unit: millimetres when the camera is calibrated, pixels otherwise.
struct Units {
    double mm;
    double length(double px) const { return mm > 0 ? px * mm : px; }
    double area(double px) const { return mm > 0 ? px * mm * mm : px; }
    const char* lengthUnit() const { return mm > 0 ? "mm" : "px"; }
    const char* areaUnit() const { return mm > 0 ? "mm²" : "px²"; }
};

std::vector<cv::Point2f> shifted(const std::vector<cv::Point2f>& points, cv::Rect roi) {
    std::vector<cv::Point2f> moved(points);
    for (auto& p : moved) {
        p.x += float(roi.x);
        p.y += float(roi.y);
    }
    return moved;
}

// ---- Shape fitting ----

struct Line {
    cv::Point2d point, direction;  // direction is a unit vector
};

struct Circle {
    cv::Point2d center;
    double radius = 0;
};

double distanceTo(const Line& line, cv::Point2d p) {
    cv::Point2d d = p - line.point;
    return std::abs(d.x * line.direction.y - d.y * line.direction.x);
}

double distanceTo(const Circle& circle, cv::Point2d p) {
    return std::abs(cv::norm(p - circle.center) - circle.radius);
}

// A least-squares line through the points, measured square to the line, not up and down.
Line fitLineTo(const std::vector<cv::Point2d>& points) {
    cv::Point2d mean(0, 0);
    for (const auto& p : points) {
        mean += p;
    }
    mean *= 1.0 / double(points.size());
    double xx = 0, xy = 0, yy = 0;
    for (const auto& p : points) {
        cv::Point2d d = p - mean;
        xx += d.x * d.x;
        xy += d.x * d.y;
        yy += d.y * d.y;
    }
    double theta = 0.5 * std::atan2(2 * xy, xx - yy);
    return {mean, cv::Point2d(std::cos(theta), std::sin(theta))};
}

// Starts from an algebraic fit, then descends on the true distance to the circle. The algebraic fit alone runs small on
// a partial arc, which is just when a hole is hardest to measure.
Circle fitCircleTo(const std::vector<cv::Point2d>& points, Circle start) {
    Circle circle = start;
    for (int round = 0; round < 12; round++) {
        double a11 = 0, a12 = 0, a13 = 0, a22 = 0, a23 = 0, a33 = 0, b1 = 0, b2 = 0, b3 = 0;
        for (const auto& p : points) {
            cv::Point2d d = p - circle.center;
            double distance = cv::norm(d);
            if (distance <= 0) {
                continue;
            }
            double ux = -d.x / distance, uy = -d.y / distance, r = distance - circle.radius;
            a11 += ux * ux;
            a12 += ux * uy;
            a13 += -ux;
            a22 += uy * uy;
            a23 += -uy;
            a33 += 1;
            b1 -= ux * r;
            b2 -= uy * r;
            b3 += r;
        }
        cv::Matx33d normal(a11, a12, a13, a12, a22, a23, a13, a23, a33);
        cv::Vec3d right(b1, b2, b3), step;
        if (!cv::solve(normal, right, step, cv::DECOMP_LU)) {
            break;
        }
        circle.center.x += step[0];
        circle.center.y += step[1];
        circle.radius += step[2];
        if (std::abs(step[0]) + std::abs(step[1]) + std::abs(step[2]) < 1e-5) {
            break;
        }
    }
    return circle;
}

bool circleThrough(cv::Point2d a, cv::Point2d b, cv::Point2d c, Circle& circle) {
    double d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y));
    if (std::abs(d) < 1e-6) {
        return false;
    }
    double a2 = a.dot(a), b2 = b.dot(b), c2 = c.dot(c);
    circle.center.x = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d;
    circle.center.y = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d;
    circle.radius = cv::norm(a - circle.center);
    return true;
}

// Consensus from random samples, then least squares on those that agree, twice over, so edges that aren't the shape
// (a burr, a shadow, something else in the region) have no say in it.
template <typename Model, typename Sampler, typename Refiner>
bool fitByConsensus(const std::vector<cv::Point2d>& points, double tolerance, Sampler sample, Refiner refine, Model& best, std::vector<cv::Point2d>& agreeing) {
    int bestCount = -1;
    cv::RNG random(12345);  // the same image gives the same answer
    for (int i = 0; i < 800; i++) {
        Model model;
        if (!sample(random, model)) {
            continue;
        }
        int count = 0;
        for (const auto& p : points) {
            count += distanceTo(model, p) <= tolerance ? 1 : 0;
        }
        if (count > bestCount) {
            bestCount = count;
            best = model;
        }
    }
    if (bestCount < 0) {
        return false;
    }
    for (int round = 0; round < 3; round++) {
        agreeing.clear();
        for (const auto& p : points) {
            if (distanceTo(best, p) <= tolerance) {
                agreeing.push_back(p);
            }
        }
        if (agreeing.size() < 3) {
            return false;
        }
        best = refine(agreeing, best);
    }
    agreeing.clear();
    for (const auto& p : points) {
        if (distanceTo(best, p) <= tolerance) {
            agreeing.push_back(p);
        }
    }
    return agreeing.size() >= 3;
}

Overlay polyline(std::vector<cv::Point2f> points, bool closed, const std::string& label, OverlayStyle style) {
    Overlay overlay;
    overlay.points = std::move(points);
    overlay.closed = closed;
    overlay.label = label;
    overlay.style = style;
    return overlay;
}

}  // namespace

std::vector<Contour> extractContours(const cv::Mat& gray, const ToolInput& input) {
    cv::Mat smooth = gray;
    int blur = int(input.number("blur", 3));
    if (blur >= 3) {
        cv::GaussianBlur(gray, smooth, cv::Size(blur | 1, blur | 1), 0);
    }

    Gradients g;
    cv::Sobel(smooth, g.gx, CV_32F, 1, 0, 3);
    cv::Sobel(smooth, g.gy, CV_32F, 0, 1, 3);
    cv::magnitude(g.gx, g.gy, g.magnitude);

    double smoothing = input.number("smoothContour", 1);
    bool includeHoles = input.number("includeHoles", 1) != 0;
    int method = int(input.number("method", 0));

    std::vector<Contour> found;
    auto add = [&](const std::vector<cv::Point>& chain, bool closed, bool hole) {
        Contour contour;
        contour.closed = closed;
        contour.hole = hole;
        for (const cv::Point& p : chain) {
            if (p.x <= 0 || p.y <= 0 || p.x >= gray.cols - 1 || p.y >= gray.rows - 1) {
                contour.touchesBorder = true;
                break;
            }
        }
        contour.points = smoothAlong(refinePoints(chain, g), closed, smoothing);
        contour.length = cv::arcLength(contour.points, closed);
        contour.area = closed ? cv::contourArea(contour.points) : 0;
        found.push_back(std::move(contour));
    };

    if (method == 3) {
        // Edges: open as well as closed, with no notion of inside or outside.
        double high = input.number("minEdge", 0) * 8;
        if (high <= 0) {
            high = automaticEdgeStrength(g.magnitude);
        }
        cv::Mat gx16, gy16, edges;
        cv::Sobel(smooth, gx16, CV_16S, 1, 0, 3);
        cv::Sobel(smooth, gy16, CV_16S, 0, 1, 3);
        cv::Canny(gx16, gy16, edges, high * 0.5, high, true);
        for (const auto& link : linkEdges(edges)) {
            if (link.first.size() >= 4) {
                add(link.first, link.second, false);
            }
        }
    } else {
        int type = input.number("polarity", 0) == 0 ? cv::THRESH_BINARY_INV : cv::THRESH_BINARY;
        cv::Mat mask;
        if (method == 1) {
            cv::threshold(smooth, mask, input.number("threshold", 128), 255, type);
        } else if (method == 2) {
            int block = std::max(3, int(input.number("adaptiveBlock", 51))) | 1;
            cv::adaptiveThreshold(smooth, mask, 255, cv::ADAPTIVE_THRESH_GAUSSIAN_C, type, block, input.number("adaptiveC", 8));
        } else {
            cv::threshold(smooth, mask, 0, 255, type | cv::THRESH_OTSU);
        }
        std::vector<std::vector<cv::Point>> traced;
        std::vector<cv::Vec4i> hierarchy;
        cv::findContours(mask, traced, hierarchy, cv::RETR_CCOMP, cv::CHAIN_APPROX_NONE);
        for (size_t i = 0; i < traced.size(); i++) {
            bool hole = hierarchy[i][3] >= 0;
            if (traced[i].size() >= 4 && (includeHoles || !hole)) {
                add(traced[i], true, hole);
            }
        }
    }

    double minLength = input.number("minLength", 20), maxLength = input.number("maxLength", 0);
    double minArea = input.number("minArea", 0), maxArea = input.number("maxArea", 0);
    int keep = int(input.number("keep", 0));  // 0 all, 1 closed, 2 open
    bool dropBorder = input.number("dropBorder", 1) != 0;
    found.erase(std::remove_if(found.begin(), found.end(), [&](const Contour& c) {
        return c.length < minLength || (maxLength > 0 && c.length > maxLength) ||
               (c.closed && c.area < minArea) || (c.closed && maxArea > 0 && c.area > maxArea) ||
               (keep == 1 && !c.closed) || (keep == 2 && c.closed) || (dropBorder && c.touchesBorder);
    }), found.end());
    return found;
}

void runContours(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    cv::Mat gray;
    cv::cvtColor(bgr(roi), gray, cv::COLOR_BGR2GRAY);
    std::vector<Contour> contours = extractContours(gray, input);
    Units units{input.mmPerPixel};

    int closed = 0, open = 0, holes = 0;
    double totalLength = 0;
    const Contour* subject = nullptr;
    for (const Contour& c : contours) {
        closed += c.closed ? 1 : 0;
        open += c.closed ? 0 : 1;
        holes += c.hole ? 1 : 0;
        totalLength += c.length;
        // The measures describe the largest closed shape, or else the longest open edge.
        if (!c.hole && (!subject || (c.closed && !subject->closed) || (c.closed == subject->closed && (c.closed ? c.area > subject->area : c.length > subject->length)))) {
            subject = &c;
        }
    }
    if (!subject && !contours.empty()) {
        subject = &contours.front();
    }

    int drawn = 0;
    for (const Contour& c : contours) {
        if (drawn++ >= 300) {  // enough to read; more than this only slows the overlay down
            break;
        }
        std::vector<cv::Point2f> simple;
        cv::approxPolyDP(shifted(c.points, roi), simple, 0.5, c.closed);
        std::string label;
        if (&c == subject) {
            label = cv::format("%.2f %s", units.length(c.length), units.lengthUnit());
        }
        out.overlays.push_back(polyline(std::move(simple), c.closed, label, c.hole ? OverlayStyle::Info : OverlayStyle::Good));
    }

    out.measures.push_back({"count", double(contours.size()), ""});
    out.measures.push_back({"closed", double(closed), ""});
    out.measures.push_back({"open", double(open), ""});
    if (input.number("method", 0) != 3) {
        out.measures.push_back({"holes", double(holes), ""});
    }
    out.measures.push_back({"total_length", units.length(totalLength), units.lengthUnit()});
    if (subject) {
        Shape shape = describe(*subject, input.number("cornerTolerance", 3));
        out.measures.push_back({"longest", units.length(subject->length), units.lengthUnit()});
        out.measures.push_back({"x", shape.cx + roi.x, "px"});
        out.measures.push_back({"y", shape.cy + roi.y, "px"});
        out.measures.push_back({"aspect_ratio", shape.aspect, ""});
        if (subject->closed) {
            out.measures.push_back({"largest_area", units.area(subject->area), units.areaUnit()});
            out.measures.push_back({"perimeter", units.length(subject->length), units.lengthUnit()});
            out.measures.push_back({"circularity", shape.circularity, ""});
            out.measures.push_back({"convexity", shape.convexity, ""});
            out.measures.push_back({"corners", double(shape.corners), ""});
            out.measures.push_back({"angle", shape.degrees, "°"});
        }
    }
}

void runShapeFit(const cv::Mat& bgr, cv::Rect roi, const ToolInput& given, ToolOutput& out) {
    cv::Mat gray;
    cv::cvtColor(bgr(roi), gray, cv::COLOR_BGR2GRAY);
    // A line usually runs on past the region, so here an edge reaching the border is normal. By default it works from
    // edges, which need no threshold to be chosen, and the measures are more exact for it.
    ToolInput input = given;
    input.numbers.emplace("dropBorder", 0);
    input.numbers.emplace("method", 3);
    std::vector<Contour> contours = extractContours(gray, input);
    Units units{input.mmPerPixel};
    int kind = int(input.number("shape", 0));  // 0 line, 1 circle, 2 ellipse, 3 rectangle
    double tolerance = input.number("tolerance", 1.5);
    auto report = [&](const char* name, double value, const char* unit) { out.measures.push_back({name, value, unit}); };
    auto reportNothing = [&] { report("found", 0, ""); };

    std::vector<cv::Point2d> pool;
    std::vector<std::pair<size_t, size_t>> spans;  // which part of the pool each contour is, and for each point, its contour
    std::vector<int> owner;
    for (size_t i = 0; i < contours.size(); i++) {
        size_t first = pool.size();
        for (const auto& p : contours[i].points) {
            pool.emplace_back(p.x, p.y);
            owner.push_back(int(i));
        }
        spans.emplace_back(first, pool.size());
    }
    if (pool.size() < 8) {
        reportNothing();
        return;
    }

    if (kind == 0 || kind == 1) {
        // Samples come from along one contour, so a long real edge gets tried no matter how much else is in the region.
        // Drawing from the whole pool instead can miss it altogether: over wood grain, only one point in fifteen was on
        // the card's edge, which makes a pair of them rare. Going by contour also finds a line that's broken in two.
        // Density alone can't tell a real outline from many short edges crossing an imaginary shape, as happens in a busy
        // scene. A real outline follows the shape in long unbroken stretches, and chance crossings don't.
        auto followsContours = [&](const auto& model) {
            size_t connected = 0, total = 0;
            for (const auto& span : spans) {
                size_t run = 0;
                for (size_t i = span.first; i <= span.second; i++) {
                    if (i < span.second && distanceTo(model, pool[i]) <= tolerance) {
                        run++;
                        total++;
                    } else {
                        connected += run >= size_t(kShortestRun) ? run : 0;
                        run = 0;
                    }
                }
            }
            return total > 0 && double(connected) >= double(total) * kLeastConnectedShare;
        };
        size_t anchor = 0;
        auto pick = [&](cv::RNG& random) {
            anchor = size_t(random.uniform(0, int(pool.size())));
            return pool[anchor];
        };
        auto pickNear = [&](cv::RNG& random) {
            const auto& span = spans[size_t(owner[anchor])];
            return pool[span.first + size_t(random.uniform(0, int(span.second - span.first)))];
        };
        std::vector<cv::Point2d> agreeing;
        double rms = 0, worst = 0;
        auto summarize = [&](const auto& model) {
            double squares = 0;
            for (const auto& p : agreeing) {
                double d = distanceTo(model, p);
                squares += d * d;
                worst = std::max(worst, d);
            }
            rms = std::sqrt(squares / double(agreeing.size()));
        };
        if (kind == 0) {
            Line line;
            bool ok = fitByConsensus(pool, tolerance, [&](cv::RNG& random, Line& model) {
                cv::Point2d a = pick(random), b = pickNear(random);
                double size = cv::norm(a - b);
                if (size < 4) {
                    return false;
                }
                model.point = a;
                model.direction = (b - a) * (1 / size);
                return true;
            }, [](const std::vector<cv::Point2d>& points, const Line&) { return fitLineTo(points); }, line, agreeing);
            if (!ok) {
                reportNothing();
                return;
            }
            summarize(line);
            double low = 1e12, high = -1e12;
            for (const auto& p : agreeing) {
                double t = (p - line.point).dot(line.direction);
                low = std::min(low, t);
                high = std::max(high, t);
            }
            // Real edges give about a point per pixel along the shape. Scattered points that merely agree give far fewer,
            // and noise would otherwise always yield some line.
            if (double(agreeing.size()) < (high - low) * kLeastPointsPerPixel || !followsContours(line)) {
                reportNothing();
                return;
            }
            cv::Point2d a = line.point + line.direction * low, b = line.point + line.direction * high;
            double degrees = -std::atan2(line.direction.y, line.direction.x) * 180 / CV_PI;
            degrees = degrees > 90 ? degrees - 180 : (degrees <= -90 ? degrees + 180 : degrees);
            report("found", 1, "");
            report("length", units.length(high - low), units.lengthUnit());
            report("angle", degrees, "°");
            report("x", (a.x + b.x) / 2 + roi.x, "px");
            report("y", (a.y + b.y) / 2 + roi.y, "px");
            report("rms_error", units.length(rms), units.lengthUnit());
            report("max_deviation", units.length(worst), units.lengthUnit());
            report("share_used", double(agreeing.size()) / double(pool.size()), "");
            out.overlays.push_back(polyline({cv::Point2f(float(a.x + roi.x), float(a.y + roi.y)), cv::Point2f(float(b.x + roi.x), float(b.y + roi.y))}, false,
                                            cv::format("%.2f %s, %.2f°", units.length(high - low), units.lengthUnit(), degrees), OverlayStyle::Good));
        } else {
            Circle circle;
            double largestRadius = std::hypot(gray.cols, gray.rows);
            bool ok = fitByConsensus(pool, tolerance, [&](cv::RNG& random, Circle& model) {
                cv::Point2d a = pick(random), b = pickNear(random), c = pickNear(random);
                return circleThrough(a, b, c, model) && model.radius >= 3 && model.radius <= largestRadius;
            }, [](const std::vector<cv::Point2d>& points, const Circle& start) { return fitCircleTo(points, start); }, circle, agreeing);
            if (!ok) {
                reportNothing();
                return;
            }
            // The fit can run away toward a straight edge, which is a circle of enormous radius.
            if (circle.radius > largestRadius) {
                reportNothing();
                return;
            }
            summarize(circle);
            double smallest = 1e12, largest = 0;
            const int sectors = 72;
            std::vector<char> seen(sectors, 0);
            for (const auto& p : agreeing) {
                cv::Point2d d = p - circle.center;
                double r = cv::norm(d);
                smallest = std::min(smallest, r);
                largest = std::max(largest, r);
                seen[size_t(std::clamp(int((std::atan2(d.y, d.x) + CV_PI) / (2 * CV_PI) * sectors), 0, sectors - 1))] = 1;
            }
            double arc = double(std::count(seen.begin(), seen.end(), 1)) / sectors;
            if (double(agreeing.size()) < arc * 2 * CV_PI * circle.radius * kLeastPointsPerPixel || !followsContours(circle)) {
                reportNothing();
                return;
            }
            report("found", 1, "");
            report("diameter", units.length(circle.radius * 2), units.lengthUnit());
            report("x", circle.center.x + roi.x, "px");
            report("y", circle.center.y + roi.y, "px");
            report("roundness", units.length(largest - smallest), units.lengthUnit());
            report("rms_error", units.length(rms), units.lengthUnit());
            report("arc_coverage", arc, "");
            report("share_used", double(agreeing.size()) / double(pool.size()), "");
            std::vector<cv::Point2f> ring;
            for (int i = 0; i < 90; i++) {
                double t = i * 2 * CV_PI / 90;
                ring.emplace_back(float(circle.center.x + circle.radius * std::cos(t) + roi.x), float(circle.center.y + circle.radius * std::sin(t) + roi.y));
            }
            out.overlays.push_back(polyline(std::move(ring), true, cv::format("⌀ %.2f %s", units.length(circle.radius * 2), units.lengthUnit()), OverlayStyle::Good));
        }
        return;
    }

    // An ellipse or rectangle comes from one closed outline, the largest in the region that isn't a hole.
    const Contour* subject = nullptr;
    for (const Contour& c : contours) {
        if (c.closed && (!subject || c.area > subject->area)) {
            subject = &c;
        }
    }
    if (!subject || subject->points.size() < 8) {
        reportNothing();
        return;
    }
    std::vector<cv::Point2f> corners;
    double squares = 0, worst = 0;
    size_t counted = 0;
    if (kind == 2) {
        cv::RotatedRect ellipse = cv::fitEllipseDirect(subject->points);
        double major = std::max(ellipse.size.width, ellipse.size.height), minor = std::min(ellipse.size.width, ellipse.size.height);
        double radians = ellipse.angle * CV_PI / 180;
        if (ellipse.size.width < ellipse.size.height) {
            radians += CV_PI / 2;  // the angle of the long axis
        }
        double c = std::cos(radians), s = std::sin(radians);
        for (const auto& p : subject->points) {
            double dx = p.x - ellipse.center.x, dy = p.y - ellipse.center.y;
            double u = (c * dx + s * dy) / (major / 2), v = (-s * dx + c * dy) / (minor / 2);
            double rho = std::hypot(u, v);
            if (rho > 0) {
                // Close enough to the distance for a small error: how far off in unit space, in pixels at this point.
                double gap = std::abs(rho - 1) * std::hypot(dx, dy) / rho;
                squares += gap * gap;
                worst = std::max(worst, gap);
                counted++;
            }
        }
        // Any closed outline gets an ellipse from the fit, so it counts only if it follows the outline.
        if (counted == 0 || std::sqrt(squares / double(counted)) > tolerance) {
            reportNothing();
            return;
        }
        double degrees = -radians * 180 / CV_PI;
        degrees = std::fmod(degrees, 180);
        degrees = degrees > 90 ? degrees - 180 : (degrees <= -90 ? degrees + 180 : degrees);
        report("found", 1, "");
        report("major_axis", units.length(major), units.lengthUnit());
        report("minor_axis", units.length(minor), units.lengthUnit());
        report("angle", degrees, "°");
        report("x", ellipse.center.x + roi.x, "px");
        report("y", ellipse.center.y + roi.y, "px");
        for (int i = 0; i < 90; i++) {
            double t = i * 2 * CV_PI / 90, a = major / 2 * std::cos(t), b = minor / 2 * std::sin(t);
            corners.emplace_back(float(ellipse.center.x + c * a - s * b + roi.x), float(ellipse.center.y + s * a + c * b + roi.y));
        }
        out.overlays.push_back(polyline(corners, true, cv::format("%.2f × %.2f %s", units.length(major), units.length(minor), units.lengthUnit()), OverlayStyle::Good));
    } else {
        // A bounding box only starts this off: any stray point would push it outward. So each side gets a line of its own,
        // from the points along its middle, away from the corners, where edges round off.
        cv::RotatedRect box = cv::minAreaRect(subject->points);
        double length = std::max(box.size.width, box.size.height), width = std::min(box.size.width, box.size.height);
        double radians = box.angle * CV_PI / 180;
        if (box.size.width < box.size.height) {
            radians += CV_PI / 2;
        }
        cv::Point2d along(std::cos(radians), std::sin(radians)), across(-along.y, along.x), center(box.center.x, box.center.y);
        std::vector<cv::Point2d> sides[4];  // start and end along the long axis, then the two across it
        for (const auto& p : subject->points) {
            cv::Point2d d = cv::Point2d(p.x, p.y) - center;
            double u = d.dot(along), v = d.dot(across);
            double gapLong = std::abs(std::abs(v) - width / 2), gapShort = std::abs(std::abs(u) - length / 2);
            if (gapLong <= tolerance * 2 && std::abs(u) < length * 0.4) {
                sides[v < 0 ? 0 : 1].emplace_back(p.x, p.y);
            } else if (gapShort <= tolerance * 2 && std::abs(v) < width * 0.4) {
                sides[u < 0 ? 2 : 3].emplace_back(p.x, p.y);
            }
        }
        if (std::any_of(std::begin(sides), std::end(sides), [](const auto& side) { return side.size() < 4; })) {
            reportNothing();
            return;
        }
        Line lines[4];
        for (int i = 0; i < 4; i++) {
            lines[i] = fitLineTo(sides[i]);
            std::vector<cv::Point2d> kept;
            for (const auto& p : sides[i]) {
                if (distanceTo(lines[i], p) <= tolerance) {
                    kept.push_back(p);
                }
            }
            if (kept.size() >= 4) {
                lines[i] = fitLineTo(kept);
            }
            for (const auto& p : kept) {
                double gap = distanceTo(lines[i], p);
                squares += gap * gap;
                worst = std::max(worst, gap);
                counted++;
            }
        }
        // Most of the outline must lie along the sides, or this isn't a rectangle at all. Corners can round off, so the
        // parts near them aren't counted against it: only 80% of each side is looked at, so that's the most it can reach.
        if (double(counted) < double(subject->points.size()) * 0.6) {
            reportNothing();
            return;
        }
        // Where the sides cross. A rectangle viewed at a slight angle isn't quite parallel, so the sizes are averaged.
        auto cross = [](const Line& a, const Line& b) {
            double denominator = a.direction.x * b.direction.y - a.direction.y * b.direction.x;
            cv::Point2d d = b.point - a.point;
            double t = denominator != 0 ? (d.x * b.direction.y - d.y * b.direction.x) / denominator : 0;
            return a.point + a.direction * t;
        };
        cv::Point2d q[4] = {cross(lines[0], lines[2]), cross(lines[0], lines[3]), cross(lines[1], lines[3]), cross(lines[1], lines[2])};
        length = (cv::norm(q[0] - q[1]) + cv::norm(q[3] - q[2])) / 2;
        width = (cv::norm(q[0] - q[3]) + cv::norm(q[1] - q[2])) / 2;
        cv::Point2d middle = (q[0] + q[1] + q[2] + q[3]) * 0.25;
        cv::Point2d axis = (q[1] - q[0]) + (q[2] - q[3]);
        double degrees = -std::atan2(axis.y, axis.x) * 180 / CV_PI;
        degrees = std::fmod(degrees, 180);
        degrees = degrees > 90 ? degrees - 180 : (degrees <= -90 ? degrees + 180 : degrees);
        report("found", 1, "");
        report("length", units.length(length), units.lengthUnit());
        report("width", units.length(width), units.lengthUnit());
        report("angle", degrees, "°");
        report("x", middle.x + roi.x, "px");
        report("y", middle.y + roi.y, "px");
        for (const auto& corner : q) {
            corners.emplace_back(float(corner.x + roi.x), float(corner.y + roi.y));
        }
        out.overlays.push_back(polyline(corners, true, cv::format("%.2f × %.2f %s", units.length(length), units.length(width), units.lengthUnit()), OverlayStyle::Good));
    }
    report("rms_error", units.length(counted > 0 ? std::sqrt(squares / double(counted)) : 0), units.lengthUnit());
    report("max_deviation", units.length(worst), units.lengthUnit());
}

}  // namespace mxv
