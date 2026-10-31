#include "EdgeMatch.hpp"

#include <opencv2/core/utility.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <random>

namespace mxv {

namespace {

using Level = EdgeMatcher::Level;
using EdgePoint = EdgeMatcher::EdgePoint;

const int kMinModelPoints = 12;       // a coarser level with fewer than this has lost the part's shape
const float kTopRadius = 14;          // the coarsest level is about this big: larger keeps fine detail such as text, but a small part then takes over a second
const int kMaxLevels = 6;
const size_t kMaxPoints[] = {2500, 1000, 500, 250, 150, 100};  // by level, more than this only adds time
const int kKeepPerPose = 24;          // peaks to keep from each pose at the coarsest level
const int kKeepToRefine = 48;         // candidates to take down the pyramid
const int kKeepPerLevel = 12;         // and how many survive each level

// An image's edges as unit vectors, so comparing them gives the same answer in bright light and dim.
struct DirectionField {
    cv::Mat dx, dy, magnitude;  // CV_32F; dx and dy are zero where there's no edge to speak of
    int rows = 0, cols = 0;
};

DirectionField makeField(const cv::Mat& gray, float floorMagnitude) {
    DirectionField field;
    cv::Mat gx, gy;
    cv::Sobel(gray, gx, CV_32F, 1, 0, 3);
    cv::Sobel(gray, gy, CV_32F, 0, 1, 3);
    cv::magnitude(gx, gy, field.magnitude);
    field.dx.create(gray.size(), CV_32F);
    field.dy.create(gray.size(), CV_32F);
    field.rows = gray.rows;
    field.cols = gray.cols;
    for (int y = 0; y < gray.rows; y++) {
        const float* ax = gx.ptr<float>(y);
        const float* ay = gy.ptr<float>(y);
        const float* m = field.magnitude.ptr<float>(y);
        float* ux = field.dx.ptr<float>(y);
        float* uy = field.dy.ptr<float>(y);
        for (int x = 0; x < gray.cols; x++) {
            if (m[x] >= floorMagnitude) {
                ux[x] = ax[x] / m[x];
                uy[x] = ay[x] / m[x];
            } else {
                ux[x] = 0;
                uy[x] = 0;
            }
        }
    }
    return field;
}

// Sobel's response is 8 times the brightness step per pixel; edge settings are in brightness levels per pixel.
const float kSobelGain = 8;

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

Level extractLevel(const cv::Mat& gray, double minEdge, int levelIndex) {
    cv::Mat gx16, gy16;
    cv::Sobel(gray, gx16, CV_16S, 1, 0, 3);
    cv::Sobel(gray, gy16, CV_16S, 0, 1, 3);

    double high = minEdge * kSobelGain;
    if (high <= 0) {
        cv::Mat gx32, gy32, magnitude;
        gx16.convertTo(gx32, CV_32F);
        gy16.convertTo(gy32, CV_32F);
        cv::magnitude(gx32, gy32, magnitude);
        high = automaticEdgeStrength(magnitude);
    }
    cv::Mat edges;
    cv::Canny(gx16, gy16, edges, high * 0.5, high, true);

    // Whole contours, so the sampling below keeps the points spread along the shape.
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(edges, contours, cv::RETR_LIST, cv::CHAIN_APPROX_NONE);
    size_t shortest = levelIndex == 0 ? 12 : 4;  // specks aren't part of the shape
    size_t total = 0;
    for (const auto& contour : contours) {
        if (contour.size() >= shortest) {
            total += contour.size();
        }
    }

    Level level;
    size_t cap = kMaxPoints[std::min(levelIndex, 5)];
    size_t stride = std::max<size_t>(1, total / cap);
    float centerX = (gray.cols - 1) / 2.f, centerY = (gray.rows - 1) / 2.f;

    cv::Mat gx32, gy32, magnitude;
    gx16.convertTo(gx32, CV_32F);
    gy16.convertTo(gy32, CV_32F);
    cv::magnitude(gx32, gy32, magnitude);

    size_t counted = 0;
    for (const auto& contour : contours) {
        if (contour.size() < shortest) {
            continue;
        }
        for (const cv::Point& p : contour) {
            if (counted++ % stride != 0) {
                continue;
            }
            float gx = gx32.at<float>(p), gy = gy32.at<float>(p);
            float size = std::hypot(gx, gy);
            if (size <= 0) {
                continue;
            }
            float nx = gx / size, ny = gy / size;
            // Canny's points sit on whole pixels. Finding where the edge really peaks between them removes a bias that
            // otherwise shows up as a small error in the measured size, worst on small parts.
            float before = sampleBilinear(magnitude, p.x - nx, p.y - ny);
            float here = magnitude.at<float>(p);
            float after = sampleBilinear(magnitude, p.x + nx, p.y + ny);
            float curve = before - 2 * here + after;
            float shift = curve < 0 ? std::clamp(0.5f * (before - after) / curve, -0.5f, 0.5f) : 0.f;
            float x = p.x + shift * nx - centerX, y = p.y + shift * ny - centerY;
            level.points.push_back({x, y, nx, ny});
            level.radius = std::max(level.radius, std::hypot(x, y));
        }
        level.contourEnds.push_back(level.points.size());
    }
    level.outline = level.points;
    // A random order finds out sooner that a position can't reach the score, which is most of the search's speed.
    std::mt19937 shuffler(7);
    std::shuffle(level.points.begin(), level.points.end(), shuffler);
    return level;
}

struct Pose {
    double x = 0, y = 0;       // the part's center, in pixels of the level it was found at
    double degrees = 0;        // clockwise as stored, since image y runs down
    double scale = 1;
    double score = 0;
};

// How well the edges agree at a pose: the mean of how closely each model point's direction matches the image's there.
// Taking the size of the sum, rather than summing the sizes, accepts a part whose contrast has reversed as a whole,
// while edges that merely happen to lie at the right angle, with either sign, tend to cancel out.
double scoreAt(const DirectionField& field, const std::vector<EdgePoint>& points, const Pose& pose, bool anyPolarity) {
    double radians = pose.degrees * CV_PI / 180;
    double c = std::cos(radians), s = std::sin(radians);
    double sum = 0;
    for (const EdgePoint& p : points) {
        int x = int(std::lround(pose.x + pose.scale * (c * p.x - s * p.y)));
        int y = int(std::lround(pose.y + pose.scale * (s * p.x + c * p.y)));
        if (x >= 0 && y >= 0 && x < field.cols && y < field.rows) {
            sum += (c * p.dx - s * p.dy) * field.dx.at<float>(y, x) + (s * p.dx + c * p.dy) * field.dy.at<float>(y, x);
        }
    }
    return (anyPolarity ? std::abs(sum) : sum) / double(points.size());
}

// Every position at one angle and size at the coarsest level, keeping the best peaks.
void scanPose(const DirectionField& field, const std::vector<EdgePoint>& points, double degrees, double scale, double threshold, bool anyPolarity, std::vector<Pose>& found) {
    double radians = degrees * CV_PI / 180;
    float c = float(std::cos(radians)), s = float(std::sin(radians));
    size_t n = points.size();
    std::vector<int> offsetX(n), offsetY(n);
    std::vector<float> dirX(n), dirY(n);
    for (size_t i = 0; i < n; i++) {
        offsetX[i] = int(std::lround(scale * (c * points[i].x - s * points[i].y)));
        offsetY[i] = int(std::lround(scale * (s * points[i].x + c * points[i].y)));
        dirX[i] = c * points[i].dx - s * points[i].dy;
        dirY[i] = s * points[i].dx + c * points[i].dy;
    }

    float needed = float(threshold * double(n));
    std::vector<Pose> peaks;
    const int rows = field.rows, cols = field.cols;
    for (int y = 0; y < rows; y++) {
        for (int x = 0; x < cols; x++) {
            float sum = 0;
            size_t i = 0;
            for (; i < n; i++) {
                int px = x + offsetX[i], py = y + offsetY[i];
                if (px >= 0 && py >= 0 && px < cols && py < rows) {
                    sum += dirX[i] * field.dx.at<float>(py, px) + dirY[i] * field.dy.at<float>(py, px);
                }
                // Even if every remaining point agreed perfectly, could this still reach the score?
                float best = (anyPolarity ? std::abs(sum) : sum) + float(n - i - 1);
                if (best < needed) {
                    break;
                }
            }
            if (i == n) {
                float total = anyPolarity ? std::abs(sum) : sum;
                if (total >= needed) {
                    Pose pose;
                    pose.x = x;
                    pose.y = y;
                    pose.degrees = degrees;
                    pose.scale = scale;
                    pose.score = total / float(n);
                    peaks.push_back(pose);
                }
            }
        }
    }
    if (int(peaks.size()) > kKeepPerPose) {
        std::partial_sort(peaks.begin(), peaks.begin() + kKeepPerPose, peaks.end(), [](const Pose& a, const Pose& b) { return a.score > b.score; });
        peaks.resize(size_t(kKeepPerPose));
    }
    found = std::move(peaks);
}

// Tries the neighbouring poses at one level and keeps the best.
Pose refineOnLevel(const DirectionField& field, const std::vector<EdgePoint>& points, Pose pose, double angleStep, double scaleStep, bool anyPolarity) {
    Pose best = pose;
    best.score = scoreAt(field, points, pose, anyPolarity);
    for (int round = 0; round < 2; round++) {
        Pose center = best;
        for (double da : {-angleStep, 0.0, angleStep}) {
            for (double ds : {1 - scaleStep, 1.0, 1 + scaleStep}) {
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        Pose candidate = center;
                        candidate.degrees += da;
                        candidate.scale *= ds;
                        candidate.x += dx;
                        candidate.y += dy;
                        candidate.score = scoreAt(field, points, candidate, anyPolarity);
                        if (candidate.score > best.score) {
                            best = candidate;
                        }
                    }
                }
            }
        }
        angleStep /= 2;
        scaleStep /= 2;
    }
    return best;
}

// A located part. a, b, c, d, tx, ty map model coordinates to image pixels.
struct Fit {
    double a = 1, b = 0, c = 0, d = 1, tx = 0, ty = 0;
    int hits = 0;
    double rms = 0, meanAgreement = 0;
};

struct Assessment {
    double connectedShare = 0, meanAgreement = 0;
    int hits = 0;
};

// How much of the part is really there. A point counts only if the image has a true edge crest right beside it, facing
// the same way, and only as part of an unbroken run along its contour. A busy image has plenty of edges that happen to
// lie near some of the points, but they're scattered, whereas the part's own outline comes in long connected runs.
void assessFit(const DirectionField& field, const Level& level, const Fit& fit, bool anyPolarity, Assessment& result) {
    double polaritySum = 0;
    size_t n = level.outline.size();
    std::vector<char> hit(n, 0);
    std::vector<float> agreement(n, 0.f);
    for (int pass = 0; pass < 2; pass++) {
        double polarity = pass == 1 && anyPolarity && polaritySum < 0 ? -1 : 1;
        for (size_t i = 0; i < n; i++) {
            const EdgePoint& p = level.outline[i];
            double px = fit.a * p.x + fit.b * p.y + fit.tx;
            double py = fit.c * p.x + fit.d * p.y + fit.ty;
            double nx = fit.a * p.dx + fit.b * p.dy, ny = fit.c * p.dx + fit.d * p.dy;
            double size = std::hypot(nx, ny);
            if (size <= 0) {
                continue;
            }
            nx /= size;
            ny /= size;
            if (pass == 0) {
                int ix = int(std::lround(px)), iy = int(std::lround(py));
                if (ix >= 0 && iy >= 0 && ix < field.cols && iy < field.rows) {
                    polaritySum += nx * field.dx.at<float>(iy, ix) + ny * field.dy.at<float>(iy, ix);
                }
                continue;
            }
            double best = -1, bestT = 0, bestDot = 0;
            for (double t = -1.0; t <= 1.0; t += 0.25) {
                int ix = int(std::lround(px + t * nx)), iy = int(std::lround(py + t * ny));
                if (ix < 1 || iy < 1 || ix + 1 >= field.cols || iy + 1 >= field.rows) {
                    continue;
                }
                double dot = polarity * (nx * field.dx.at<float>(iy, ix) + ny * field.dy.at<float>(iy, ix));
                if (dot < 0.9) {
                    continue;
                }
                float magnitude = sampleBilinear(field.magnitude, px + t * nx, py + t * ny);
                if (magnitude > best) {
                    best = magnitude;
                    bestT = t;
                    bestDot = dot;
                }
            }
            if (best < 0) {
                continue;
            }
            // A crest falls away on both sides. Partway up a slope isn't the edge.
            float inner = sampleBilinear(field.magnitude, px + (bestT - 1) * nx, py + (bestT - 1) * ny);
            float outer = sampleBilinear(field.magnitude, px + (bestT + 1) * nx, py + (bestT + 1) * ny);
            if (best >= inner && best >= outer) {
                hit[i] = 1;
                agreement[i] = float(bestDot);
            }
        }
    }

    const size_t shortestRun = 6;
    size_t counted = 0, begin = 0;
    double agreementSum = 0;
    size_t anyHits = 0;
    for (size_t end : level.contourEnds) {
        size_t length = end - begin;
        size_t needed = std::min(shortestRun, length);
        size_t i = begin;
        while (i < end) {
            if (!hit[i]) {
                i++;
                continue;
            }
            // One missed point doesn't break a run: noise can drop a single point from a real edge.
            size_t last = i, members = 0;
            double sum = 0;
            size_t j = i;
            while (j < end && (hit[j] || (j + 1 < end && hit[j + 1]))) {
                if (hit[j]) {
                    members++;
                    sum += agreement[j];
                    last = j;
                }
                j++;
            }
            anyHits += members;
            if (members >= needed) {
                counted += members;
                agreementSum += sum;
            }
            i = last + 1;
        }
        begin = end;
    }
    result.connectedShare = n > 0 ? double(counted) / double(n) : 0;
    result.meanAgreement = counted > 0 ? agreementSum / double(counted) : 0;
    result.hits = int(anyHits);
}

// Looks along each model point's normal for the real edge, placing it to a fraction of a pixel, and solves for the pose
// that best lines them up. Only the distance along the normal counts, as an edge says nothing about sliding along it.
// With `affine`, the fit can also shear and stretch, which follows a part tilted a little away from the camera.
void fitToEdges(const DirectionField& field, const std::vector<EdgePoint>& points, Fit& fit, double reach, bool affine, bool anyPolarity, int rounds) {
    // Which way round the contrast is, taken from the points as a whole, so that an edge of the wrong sign can't be picked.
    double polaritySum = 0;
    for (const EdgePoint& p : points) {
        int x = int(std::lround(fit.a * p.x + fit.b * p.y + fit.tx)), y = int(std::lround(fit.c * p.x + fit.d * p.y + fit.ty));
        if (x >= 0 && y >= 0 && x < field.cols && y < field.rows) {
            double nx = fit.a * p.dx + fit.b * p.dy, ny = fit.c * p.dx + fit.d * p.dy;
            polaritySum += nx * field.dx.at<float>(y, x) + ny * field.dy.at<float>(y, x);
        }
    }
    double polarity = anyPolarity && polaritySum < 0 ? -1 : 1;

    const int unknowns = affine ? 6 : 4;
    for (int round = 0; round < rounds; round++) {
        cv::Mat normal = cv::Mat::zeros(unknowns, unknowns, CV_64F), right = cv::Mat::zeros(unknowns, 1, CV_64F);
        int hits = 0;
        double squares = 0, agreement = 0, weightTotal = 0;
        for (const EdgePoint& p : points) {
            double px = fit.a * p.x + fit.b * p.y + fit.tx;
            double py = fit.c * p.x + fit.d * p.y + fit.ty;
            // A gradient is a normal, so it transforms by the inverse transpose. With small shear, this is close enough.
            double nx = fit.a * p.dx + fit.b * p.dy, ny = fit.c * p.dx + fit.d * p.dy;
            double size = std::hypot(nx, ny);
            if (size <= 0) {
                continue;
            }
            nx /= size;
            ny /= size;

            double bestOffset = 0, bestMagnitude = -1;
            double bestAgreement = 0;
            for (double t = -reach; t <= reach; t += 0.5) {
                double sx = px + t * nx, sy = py + t * ny;
                int ix = int(std::lround(sx)), iy = int(std::lround(sy));
                if (ix < 1 || iy < 1 || ix + 1 >= field.cols || iy + 1 >= field.rows) {
                    continue;
                }
                float ux = field.dx.at<float>(iy, ix), uy = field.dy.at<float>(iy, ix);
                double dot = polarity * (nx * ux + ny * uy);
                if (dot < 0.8) {
                    continue;
                }
                float magnitude = sampleBilinear(field.magnitude, sx, sy);
                if (magnitude > bestMagnitude) {
                    bestMagnitude = magnitude;
                    bestOffset = t;
                    bestAgreement = dot;
                }
            }
            if (bestMagnitude < 0) {
                continue;
            }
            // The peak between its neighbours, by a parabola, which is where the fraction of a pixel comes from.
            float before = sampleBilinear(field.magnitude, px + (bestOffset - 0.5) * nx, py + (bestOffset - 0.5) * ny);
            float after = sampleBilinear(field.magnitude, px + (bestOffset + 0.5) * nx, py + (bestOffset + 0.5) * ny);
            float curve = before - 2 * float(bestMagnitude) + after;
            double offset = bestOffset;
            if (curve < 0) {
                offset += std::clamp(0.5 * 0.5 * double(before - after) / double(curve), -0.5, 0.5);
            }

            double weight = 1 - (offset / (reach + 0.5)) * (offset / (reach + 0.5));
            weight *= weight;  // nearer edges count more, so a stray edge can't drag the pose
            double row[6];
            if (affine) {
                double values[6] = {nx * p.x, nx * p.y, nx, ny * p.x, ny * p.y, ny};
                std::copy(values, values + 6, row);
            } else {
                double values[4] = {nx * p.x + ny * p.y, nx * p.y - ny * p.x, nx, ny};
                std::copy(values, values + 4, row);
            }
            // The residual to remove, for the step from the current pose.
            for (int i = 0; i < unknowns; i++) {
                for (int j = 0; j < unknowns; j++) {
                    normal.at<double>(i, j) += weight * row[i] * row[j];
                }
                right.at<double>(i, 0) += weight * row[i] * offset;
            }
            hits++;
            squares += weight * offset * offset;
            weightTotal += weight;
            agreement += bestAgreement;
        }
        fit.hits = hits;
        fit.rms = weightTotal > 0 ? std::sqrt(squares / weightTotal) : 0;
        fit.meanAgreement = hits > 0 ? agreement / hits : 0;
        if (hits < unknowns * 2) {
            return;
        }
        cv::Mat step;
        if (!cv::solve(normal, right, step, cv::DECOMP_CHOLESKY)) {
            return;
        }
        if (affine) {
            fit.a += step.at<double>(0);
            fit.b += step.at<double>(1);
            fit.tx += step.at<double>(2);
            fit.c += step.at<double>(3);
            fit.d += step.at<double>(4);
            fit.ty += step.at<double>(5);
        } else {
            double scaleStep = step.at<double>(0), turnStep = step.at<double>(1);
            fit.a += scaleStep;
            fit.d += scaleStep;
            fit.b += turnStep;
            fit.c -= turnStep;
            fit.tx += step.at<double>(2);
            fit.ty += step.at<double>(3);
        }
    }
}

}  // namespace

double automaticEdgeStrength(const cv::Mat& magnitude) {
    double largest = 0;
    cv::minMaxLoc(magnitude, nullptr, &largest);
    if (largest <= 0) {
        return 40;
    }
    cv::Mat scaled, ignored;
    magnitude.convertTo(scaled, CV_8U, 255.0 / largest);
    double level = cv::threshold(scaled, ignored, 0, 255, cv::THRESH_BINARY | cv::THRESH_OTSU);
    return std::max(40.0, level * largest / 255.0);
}

void EdgeMatcher::build(const cv::Mat& pattern, double minEdge) {
    bool same = cachedEdge == minEdge && cachedPattern.size() == pattern.size() && !cachedPattern.empty();
    for (int y = 0; same && y < pattern.rows; y++) {
        same = std::memcmp(cachedPattern.ptr(y), pattern.ptr(y), size_t(pattern.cols)) == 0;
    }
    if (same) {
        return;
    }
    cachedPattern = pattern.clone();
    cachedEdge = minEdge;
    levels.clear();

    cv::Mat image;
    cv::GaussianBlur(pattern, image, cv::Size(3, 3), 0);
    for (int index = 0; index < kMaxLevels; index++) {
        Level level = extractLevel(image, minEdge, index);
        if (int(level.points.size()) < kMinModelPoints) {
            break;
        }
        levels.push_back(std::move(level));
        if (levels.back().radius <= kTopRadius || image.cols < 16 || image.rows < 16) {
            break;
        }
        cv::Mat smaller;
        cv::pyrDown(image, smaller);
        image = smaller;
    }
}

void EdgeMatcher::run(const cv::Mat& gray, const cv::Mat& pattern, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    build(pattern, input.number("minEdge", 0));
    if (levels.empty()) {
        out.error = "This pattern has too few clear edges to search by. Teach a region with visible outlines, or lower Edge contrast.";
        return;
    }

    double minScore = input.number("minScore", 0.7);
    int maxInstances = std::max(1, int(input.number("maxInstances", 1)));
    bool anyPolarity = input.number("anyPolarity", 1) != 0;
    bool allowTilt = input.number("allowTilt", 1) != 0;
    double smallest = std::max(0.1, input.number("scaleMin", 0.7));
    double largest = std::max(smallest, input.number("scaleMax", 1.4));
    double angleRange = std::clamp(input.number("angleRange", 180.0), 0.0, 180.0);

    // The image's pyramid, as deep as the model's.
    int depth = int(levels.size());
    std::vector<DirectionField> fields(static_cast<size_t>(depth));
    {
        cv::Mat image;
        cv::GaussianBlur(gray, image, cv::Size(3, 3), 0);
        for (int index = 0; index < depth; index++) {
            fields[size_t(index)] = makeField(image, 16);
            if (index + 1 < depth) {
                cv::Mat smaller;
                cv::pyrDown(image, smaller);
                image = smaller;
            }
        }
    }

    // How finely to try poses, so that the far end of the part moves by about two pixels between tries.
    int top = depth - 1;
    double angleStep = std::min(20.0, 2.0 / levels[size_t(top)].radius * 180 / CV_PI);
    double scaleStep = std::min(0.25, 2.0 / levels[size_t(top)].radius);
    std::vector<double> angles;
    if (angleRange >= 180) {
        for (double a = 0; a < 360; a += angleStep) {
            angles.push_back(a);
        }
    } else {
        for (double a = -angleRange; a <= angleRange + angleStep / 2; a += angleStep) {
            angles.push_back(a);
        }
    }
    std::vector<double> scales;
    for (double s = smallest; s <= largest * (1 + scaleStep / 2); s *= 1 + scaleStep) {
        scales.push_back(s);
    }

    struct Task {
        double degrees, scale;
    };
    std::vector<Task> tasks;
    for (double a : angles) {
        for (double s : scales) {
            tasks.push_back({a, s});
        }
    }

    // The coarsest level blurs edges together, so it's held to a lower bar than the final score.
    double coarseBar = std::max(0.3, minScore * 0.6);
    std::vector<std::vector<Pose>> perTask(tasks.size());
    const Level& topLevel = levels[size_t(top)];
    const DirectionField& topField = fields[size_t(top)];
    cv::parallel_for_(cv::Range(0, int(tasks.size())), [&](const cv::Range& range) {
        for (int i = range.start; i < range.end; i++) {
            scanPose(topField, topLevel.points, tasks[size_t(i)].degrees, tasks[size_t(i)].scale, coarseBar, anyPolarity, perTask[size_t(i)]);
        }
    });

    std::vector<Pose> candidates;
    for (auto& list : perTask) {
        candidates.insert(candidates.end(), list.begin(), list.end());
    }
    std::sort(candidates.begin(), candidates.end(), [](const Pose& a, const Pose& b) { return a.score > b.score; });

    // Peaks of the same part at nearby poses: the best one stands for them.
    std::vector<Pose> distinct;
    double apart = std::max(2.0, topLevel.radius * 0.25);
    for (const Pose& pose : candidates) {
        bool isNew = std::none_of(distinct.begin(), distinct.end(), [&](const Pose& other) {
            double turn = std::abs(std::fmod(std::abs(pose.degrees - other.degrees), 360.0));
            turn = std::min(turn, 360 - turn);
            return std::hypot(pose.x - other.x, pose.y - other.y) < apart && turn < 3 * angleStep && std::abs(std::log(pose.scale / other.scale)) < 2 * scaleStep;
        });
        if (isNew) {
            distinct.push_back(pose);
            if (int(distinct.size()) >= kKeepToRefine) {
                break;
            }
        }
    }

    // Down the pyramid, each level sharpening the pose found on the one above.
    double levelAngle = angleStep, levelScale = scaleStep;
    std::vector<Pose> refined = distinct;
    for (int index = top; index >= 0; index--) {
        const Level& level = levels[size_t(index)];
        cv::parallel_for_(cv::Range(0, int(refined.size())), [&](const cv::Range& range) {
            for (int i = range.start; i < range.end; i++) {
                refined[size_t(i)] = refineOnLevel(fields[size_t(index)], level.points, refined[size_t(i)], levelAngle / 2, levelScale / 2, anyPolarity);
            }
        });
        // A false lead rarely improves as the detail sharpens, so only the best go on, which keeps a busy scene from
        // slowing every level below. It's a count and not a score, because dense detail such as text scores low until
        // the finer levels can see it.
        std::sort(refined.begin(), refined.end(), [](const Pose& a, const Pose& b) { return a.score > b.score; });
        if (int(refined.size()) > std::max(kKeepPerLevel, maxInstances * 3)) {
            refined.resize(size_t(std::max(kKeepPerLevel, maxInstances * 3)));
        }
        if (index > 0) {
            for (Pose& pose : refined) {
                pose.x *= 2;
                pose.y *= 2;
            }
            levelAngle /= 2;
            levelScale /= 2;
        }
    }
    std::sort(refined.begin(), refined.end(), [](const Pose& a, const Pose& b) { return a.score > b.score; });

    struct Part {
        Fit fit;
        double score, x, y, degrees, scale, tilt, coverage, fitQuality, clutter;
        std::vector<cv::Point2f> corners;
    };
    std::vector<Part> parts;
    Part best{};
    bool haveBest = false;

    const std::vector<EdgePoint>& finest = levels[0].points;
    float halfW = (pattern.cols - 1) / 2.f, halfH = (pattern.rows - 1) / 2.f;
    cv::Mat imageEdges;
    for (const Pose& pose : refined) {
        if (int(parts.size()) >= maxInstances) {
            break;
        }
        // A part already found, seen again from a nearby start, or at a symmetric turn of itself.
        bool known = std::any_of(parts.begin(), parts.end(), [&](const Part& other) {
            return std::hypot(other.x - pose.x, other.y - pose.y) < std::min(halfW, halfH) * pose.scale;
        });
        if (known) {
            continue;
        }

        double radians = pose.degrees * CV_PI / 180;
        Fit fit;
        fit.a = pose.scale * std::cos(radians);
        fit.b = -pose.scale * std::sin(radians);
        fit.c = pose.scale * std::sin(radians);
        fit.d = pose.scale * std::cos(radians);
        fit.tx = pose.x;
        fit.ty = pose.y;

        fitToEdges(fields[0], finest, fit, 3.0, false, anyPolarity, 4);
        fitToEdges(fields[0], finest, fit, 1.5, false, anyPolarity, 4);
        if (allowTilt) {
            Fit tilted = fit;
            fitToEdges(fields[0], finest, tilted, 3.0, true, anyPolarity, 4);
            fitToEdges(fields[0], finest, tilted, 1.5, true, anyPolarity, 4);
            // Only worth keeping if it explains more of the edges, since extra freedom always fits a little better.
            if (tilted.hits > fit.hits * 1.03 || (tilted.hits >= fit.hits && tilted.rms < fit.rms * 0.9)) {
                fit = tilted;
            }
        }

        double determinant = fit.a * fit.d - fit.b * fit.c;
        if (determinant <= 0) {
            continue;  // a mirror image isn't the part
        }
        // The fit can drift to any size, but a part outside the allowed sizes isn't what was asked for.
        double fittedScale = std::sqrt(determinant);
        if (fittedScale < smallest * 0.95 || fittedScale > largest * 1.05) {
            continue;
        }
        Assessment assessment;
        assessFit(fields[0], levels[0], fit, anyPolarity, assessment);

        Part part;
        part.fit = fit;
        part.coverage = assessment.connectedShare;
        part.fitQuality = std::clamp(1 - fit.rms / 1.5, 0.0, 1.0);
        part.score = part.coverage * assessment.meanAgreement;
        part.x = fit.tx;
        part.y = fit.ty;
        part.degrees = -std::atan2(fit.c, fit.a) * 180 / CV_PI;
        part.scale = std::sqrt(determinant);
        double squares = fit.a * fit.a + fit.b * fit.b + fit.c * fit.c + fit.d * fit.d;
        double root = std::sqrt(std::max(0.0, squares * squares - 4 * determinant * determinant));
        double high = std::sqrt((squares + root) / 2), low = std::sqrt(std::max(0.0, (squares - root) / 2));
        part.tilt = high > 0 ? std::acos(std::min(1.0, low / high)) * 180 / CV_PI : 0;
        for (cv::Point2f corner : {cv::Point2f(-halfW, -halfH), cv::Point2f(halfW, -halfH), cv::Point2f(halfW, halfH), cv::Point2f(-halfW, halfH)}) {
            part.corners.emplace_back(float(fit.a * corner.x + fit.b * corner.y + fit.tx), float(fit.c * corner.x + fit.d * corner.y + fit.ty));
        }

        // Clutter: edges inside the part's outline that the model doesn't explain, as a share of the model's size.
        if (imageEdges.empty()) {
            cv::Mat blurred;
            cv::GaussianBlur(gray, blurred, cv::Size(3, 3), 0);
            cv::Canny(blurred, imageEdges, 40, 100);
        }
        cv::Mat explained = cv::Mat::zeros(gray.size(), CV_8U), inside = cv::Mat::zeros(gray.size(), CV_8U);
        for (const EdgePoint& p : finest) {
            int x = int(std::lround(fit.a * p.x + fit.b * p.y + fit.tx)), y = int(std::lround(fit.c * p.x + fit.d * p.y + fit.ty));
            if (x >= 0 && y >= 0 && x < gray.cols && y < gray.rows) {
                explained.at<uchar>(y, x) = 255;
            }
        }
        cv::dilate(explained, explained, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(7, 7)));
        std::vector<cv::Point> outline;
        for (const auto& corner : part.corners) {
            outline.emplace_back(int(corner.x), int(corner.y));
        }
        cv::fillConvexPoly(inside, outline, cv::Scalar(255));
        cv::Mat unexplained;
        cv::bitwise_and(imageEdges, inside, unexplained);
        unexplained.setTo(0, explained);
        part.clutter = std::min(1.0, cv::countNonZero(unexplained) / std::max(1.0, double(finest.size())));

        if (!haveBest || part.score > best.score) {
            best = part;
            haveBest = true;
        }
        if (part.score >= minScore) {
            parts.push_back(part);
            Overlay overlay;
            overlay.style = OverlayStyle::Good;
            overlay.label = cv::format("%.3f, %.0f°", part.score, part.degrees);
            for (const auto& corner : part.corners) {
                overlay.points.emplace_back(corner.x + float(roi.x), corner.y + float(roi.y));
            }
            out.overlays.push_back(std::move(overlay));
        }
    }

    out.measures.push_back({"count", double(parts.size()), ""});
    out.measures.push_back({"score", haveBest ? best.score : 0.0, ""});
    if (haveBest) {
        out.measures.push_back({"x", best.x + roi.x, "px"});
        out.measures.push_back({"y", best.y + roi.y, "px"});
        out.measures.push_back({"angle", best.degrees, "°"});
        out.measures.push_back({"scale", best.scale, "×"});
        out.measures.push_back({"tilt", best.tilt, "°"});
        out.measures.push_back({"matches", double(best.fit.hits), ""});
        out.measures.push_back({"fit", best.fitQuality, ""});
        out.measures.push_back({"coverage", best.coverage, ""});
        out.measures.push_back({"clutter", best.clutter, ""});
    }
}

}  // namespace mxv
