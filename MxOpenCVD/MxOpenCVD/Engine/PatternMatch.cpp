#include "PatternMatch.hpp"

#include <opencv2/calib3d.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>
#include <array>
#include <cstring>
#include <map>
#include <set>

namespace mxv {

namespace {

const int kMinPatternFeatures = 16;
const int kMinInliers = 8;
const int kMaxVerifications = 16;  // the most candidates to score, so a scene with no part in it stays quick

struct Match {
    cv::Point2f from, to;   // in the pattern, in the image
    float degrees, scale;   // how the feature's own orientation and size changed between them
};

// One located part. pose maps pattern pixels to image pixels.
struct Located {
    cv::Mat pose;
    std::vector<int> inliers;
    double score = 0;
    cv::Point2d center;
    double degrees = 0, scale = 0, tilt = 0;
};

cv::Point2d apply(const cv::Mat& pose, cv::Point2d p) {
    const double* h = pose.ptr<double>(0);
    double w = h[6] * p.x + h[7] * p.y + h[8];
    return {(h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w};
}

// Reads the part's angle, size and tilt from how the pose stretches a small step around the part's center.
void describePose(Located& part, cv::Size patternSize) {
    cv::Point2d middle(patternSize.width / 2.0, patternSize.height / 2.0);
    part.center = apply(part.pose, middle);
    cv::Point2d dx = apply(part.pose, middle + cv::Point2d(1, 0)) - part.center;
    cv::Point2d dy = apply(part.pose, middle + cv::Point2d(0, 1)) - part.center;
    // Image y runs down, so this is the angle as seen: positive turns the part counter-clockwise.
    part.degrees = -std::atan2(dx.y, dx.x) * 180 / CV_PI;
    double area = std::abs(dx.x * dy.y - dx.y * dy.x);
    part.scale = std::sqrt(area);
    // A tilted plane looks squashed one way: the ratio of the stretch's two singular values is the cosine of the tilt.
    double squares = dx.x * dx.x + dx.y * dx.y + dy.x * dy.x + dy.y * dy.y;
    double root = std::sqrt(std::max(0.0, squares * squares - 4 * area * area));
    double largest = std::sqrt((squares + root) / 2), smallest = std::sqrt(std::max(0.0, (squares - root) / 2));
    part.tilt = largest > 0 ? std::acos(std::min(1.0, smallest / largest)) * 180 / CV_PI : 0;
}

// False for a pose no real view of a flat part could give: mirrored, collapsed, or wildly stretched.
bool isPlausible(const cv::Mat& pose, cv::Size patternSize) {
    double w = patternSize.width, h = patternSize.height;
    cv::Point2d corners[4] = {apply(pose, {0, 0}), apply(pose, {w, 0}), apply(pose, {w, h}), apply(pose, {0, h})};
    double shortest = 1e12, longest = 0;
    for (int i = 0; i < 4; i++) {
        cv::Point2d a = corners[(i + 1) % 4] - corners[i];
        cv::Point2d b = corners[(i + 2) % 4] - corners[(i + 1) % 4];
        if (a.x * b.y - a.y * b.x <= 0) {
            return false;  // not convex with the pattern's own winding, so mirrored or folded
        }
        double scale = std::hypot(a.x, a.y) / (i % 2 == 0 ? w : h);
        shortest = std::min(shortest, scale);
        longest = std::max(longest, scale);
    }
    return shortest >= 0.15 && longest <= 6 && longest / shortest <= 5;
}

cv::Mat similarityAsPose(const cv::Mat& affine) {
    cv::Mat pose = cv::Mat::eye(3, 3, CV_64F);
    affine.copyTo(pose(cv::Rect(0, 0, 3, 2)));
    return pose;
}

// How well the image matches the pattern where the part should be, from 0 to 1. It takes the median across a grid of
// cells rather than one figure for the whole pattern, because a taught region usually includes some background, and
// that shouldn't count against a part in a new place. Plain cells have nothing to compare, and cells beyond the edge of
// the image have nothing to compare them with, so neither votes.
double verifyPose(const cv::Mat& gray, const cv::Mat& pattern, const cv::Mat& pose, double scale) {
    // Most of the pattern must be in view, since a part cut off by the image's edge can't be measured. It isn't stricter
    // because background in the taught region can fall outside the image while the part itself is fully in view.
    const int gridSamples = 10;
    int inside = 0;
    for (int y = 0; y < gridSamples; y++) {
        for (int x = 0; x < gridSamples; x++) {
            cv::Point2d p = apply(pose, {(x + 0.5) * pattern.cols / gridSamples, (y + 0.5) * pattern.rows / gridSamples});
            if (p.x >= 0 && p.y >= 0 && p.x < gray.cols && p.y < gray.rows) {
                inside++;
            }
        }
    }
    if (inside < gridSamples * gridSamples * 6 / 10) {
        return 0;
    }

    // When the part looks smaller than the pattern, compare at its size, since the extra detail isn't in the image.
    double shrink = std::min(scale, 1.0);
    cv::Mat small = pattern;
    cv::Mat toImage = pose;
    if (shrink < 1) {
        cv::resize(pattern, small, cv::Size(), shrink, shrink, cv::INTER_AREA);
        cv::Mat enlarge = cv::Mat::eye(3, 3, CV_64F);
        enlarge.at<double>(0, 0) = enlarge.at<double>(1, 1) = 1 / shrink;
        toImage = pose * enlarge;
    }
    if (small.cols < 12 || small.rows < 12) {
        return 0;
    }
    cv::Mat patch;
    cv::warpPerspective(gray, patch, toImage, small.size(), cv::INTER_LINEAR | cv::WARP_INVERSE_MAP, cv::BORDER_CONSTANT, cv::Scalar(0));

    int cell = std::max(12, std::max(small.cols, small.rows) / 12);
    std::vector<float> scores;
    for (int y = 0; y + cell <= small.rows; y += cell) {
        for (int x = 0; x + cell <= small.cols; x += cell) {
            cv::Rect area(x, y, cell, cell);
            cv::Point2d middle = apply(toImage, {x + cell / 2.0, y + cell / 2.0});
            if (middle.x < 0 || middle.y < 0 || middle.x >= gray.cols || middle.y >= gray.rows) {
                continue;
            }
            cv::Scalar mean, deviation;
            cv::meanStdDev(small(area), mean, deviation);
            if (deviation[0] < 5) {
                continue;
            }
            cv::meanStdDev(patch(area), mean, deviation);
            float score = 0;
            if (deviation[0] >= 1) {
                cv::Mat result;
                cv::matchTemplate(patch(area), small(area), result, cv::TM_CCOEFF_NORMED);
                score = result.at<float>(0, 0);
            }
            scores.push_back(score);
        }
    }
    if (scores.size() < 4) {
        cv::Scalar mean, deviation;
        cv::meanStdDev(patch, mean, deviation);
        if (deviation[0] < 1) {
            return 0;
        }
        cv::Mat result;
        cv::matchTemplate(patch, small, result, cv::TM_CCOEFF_NORMED);
        return result.at<float>(0, 0);
    }
    std::nth_element(scores.begin(), scores.begin() + long(scores.size() / 2), scores.end());
    return scores[scores.size() / 2];
}

// The candidates worth considering for each pattern feature. Up to `instances` neighbours can be real, one on each part
// in view, so a neighbour must be clearly better than the first that can't be: the usual best-versus-second-best test,
// generalized. That test alone would reject every feature as soon as two identical parts are in view.
std::vector<Match> findCandidates(const std::vector<cv::KeyPoint>& patternPoints, const cv::Mat& patternDescriptors,
                                  const std::vector<cv::KeyPoint>& imagePoints, const cv::Mat& imageDescriptors,
                                  int norm, int instances, float ratio, float largestDistance) {
    std::vector<Match> candidates;
    if (imageDescriptors.empty()) {
        return candidates;
    }
    cv::BFMatcher matcher(norm);
    std::vector<std::vector<cv::DMatch>> neighbours;
    matcher.knnMatch(patternDescriptors, imageDescriptors, neighbours, instances + 1);

    std::set<std::array<int, 4>> seen;  // SIFT repeats a point at each strong orientation; one vote is enough
    for (const auto& list : neighbours) {
        for (int i = 0; i < int(list.size()) && i < instances; i++) {
            bool clearlyBetter = int(list.size()) <= instances || list[size_t(i)].distance < ratio * list[size_t(instances)].distance;
            if (!clearlyBetter || list[size_t(i)].distance > largestDistance) {
                continue;
            }
            const cv::KeyPoint& a = patternPoints[size_t(list[size_t(i)].queryIdx)];
            const cv::KeyPoint& b = imagePoints[size_t(list[size_t(i)].trainIdx)];
            if (!seen.insert({int(a.pt.x * 4), int(a.pt.y * 4), int(b.pt.x * 4), int(b.pt.y * 4)}).second) {
                continue;
            }
            float degrees = b.angle - a.angle;
            candidates.push_back({a.pt, b.pt, degrees, a.size > 0 ? b.size / a.size : 1});
        }
    }
    return candidates;
}

// Each candidate predicts the part's angle, size and center from its own feature. Those that agree fall in the same
// bin, as in Lowe's Hough voting, which splits several parts apart and leaves most false matches on their own. Each
// candidate votes in the two nearest bins of each dimension, so a part near a bin's edge isn't divided in two.
std::vector<std::vector<int>> clusterByPose(const std::vector<Match>& candidates, cv::Size patternSize) {
    const double angleStep = 30, scaleStep = 1;  // degrees, and octaves of size
    cv::Point2d middle(patternSize.width / 2.0, patternSize.height / 2.0);
    double reach = std::max(patternSize.width, patternSize.height) * 0.5;

    std::map<std::array<int, 4>, std::vector<int>> bins;
    for (int i = 0; i < int(candidates.size()); i++) {
        const Match& match = candidates[size_t(i)];
        double radians = match.degrees * CV_PI / 180;
        double c = std::cos(radians) * match.scale, s = std::sin(radians) * match.scale;
        double dx = middle.x - match.from.x, dy = middle.y - match.from.y;
        double centerX = match.to.x + c * dx - s * dy;
        double centerY = match.to.y + s * dx + c * dy;

        double angle = std::fmod(std::fmod(double(match.degrees), 360) + 360, 360) / angleStep;
        double octave = std::log2(std::max(1e-3f, match.scale)) / scaleStep;
        double size = reach * std::max(0.25, double(match.scale));
        double position[4] = {angle, octave, centerX / size, centerY / size};
        int low[4];
        for (int d = 0; d < 4; d++) {
            low[d] = int(std::floor(position[d] - 0.5));
        }
        for (int vote = 0; vote < 16; vote++) {
            std::array<int, 4> bin;
            for (int d = 0; d < 4; d++) {
                bin[size_t(d)] = low[d] + ((vote >> d) & 1);
            }
            bin[0] = (bin[0] % 12 + 12) % 12;  // angles wrap around
            bins[bin].push_back(i);
        }
    }

    std::vector<std::vector<int>> clusters;
    for (auto& bin : bins) {
        if (int(bin.second.size()) >= 3) {
            clusters.push_back(std::move(bin.second));
        }
    }
    std::sort(clusters.begin(), clusters.end(), [](const auto& a, const auto& b) { return a.size() > b.size(); });
    return clusters;
}

// Starts from a rigid pose fitted to one cluster, then grows it: all the candidates near that pose refine it into a
// perspective one, which brings in more candidates, and so on. Fitting perspective from the start can't work on a small
// cluster, and a rigid pose alone can't follow a tilted part, whose features disagree more the further apart they are.
bool fitPose(const std::vector<int>& cluster, const std::vector<Match>& candidates, const std::vector<bool>& used, bool allowTilt,
             cv::Size patternSize, Located& part) {
    std::vector<cv::Point2f> from, to;
    for (int index : cluster) {
        if (!used[size_t(index)]) {
            from.push_back(candidates[size_t(index)].from);
            to.push_back(candidates[size_t(index)].to);
        }
    }
    if (from.size() < 3) {
        return false;
    }
    cv::Mat mask;
    cv::Mat affine = cv::estimateAffinePartial2D(from, to, mask, cv::RANSAC, 6.0, 500, 0.99, 5);
    if (affine.empty()) {
        return false;
    }
    cv::Mat pose = similarityAsPose(affine);

    std::vector<int> inliers;
    auto collect = [&](double tolerance) {
        inliers.clear();
        from.clear();
        to.clear();
        for (int i = 0; i < int(candidates.size()); i++) {
            if (used[size_t(i)]) {
                continue;
            }
            cv::Point2d mapped = apply(pose, candidates[size_t(i)].from);
            cv::Point2f target = candidates[size_t(i)].to;
            if (std::hypot(mapped.x - target.x, mapped.y - target.y) <= tolerance) {
                inliers.push_back(i);
                from.push_back(candidates[size_t(i)].from);
                to.push_back(target);
            }
        }
    };

    // The tolerance tightens as the pose improves. It starts loose relative to the part's size, since a rigid pose
    // can be well off at the far corners of a tilted part.
    double spread = std::max(patternSize.width, patternSize.height) * std::hypot(pose.at<double>(0, 0), pose.at<double>(1, 0));
    double tolerance = allowTilt ? std::max(8.0, spread * 0.05) : 5.0;
    for (int round = 0; round < 4; round++) {
        collect(tolerance);
        if (int(from.size()) < kMinInliers) {
            return false;
        }
        cv::Mat refined;
        if (allowTilt && from.size() >= 12) {
            refined = cv::findHomography(from, to, cv::RANSAC, 4.0, cv::noArray(), 1000, 0.995);
        } else {
            cv::Mat affineRefined = cv::estimateAffinePartial2D(from, to, cv::noArray(), cv::RANSAC, 4.0, 500, 0.99, 5);
            if (!affineRefined.empty()) {
                refined = similarityAsPose(affineRefined);
            }
        }
        if (refined.empty() || !isPlausible(refined, patternSize)) {
            break;  // keep the last good pose
        }
        pose = refined;
        tolerance = std::max(4.0, tolerance * 0.6);
    }
    collect(4.0);
    if (int(inliers.size()) < kMinInliers || !isPlausible(pose, patternSize)) {
        return false;
    }
    part.pose = pose;
    part.inliers = inliers;
    describePose(part, patternSize);
    return true;
}

Overlay outline(const cv::Mat& pose, cv::Size patternSize, cv::Rect roi, const std::string& label) {
    Overlay overlay;
    overlay.style = OverlayStyle::Good;
    overlay.label = label;
    double w = patternSize.width, h = patternSize.height;
    for (cv::Point2d corner : {cv::Point2d(0, 0), cv::Point2d(w, 0), cv::Point2d(w, h), cv::Point2d(0, h)}) {
        cv::Point2d mapped = apply(pose, corner);
        overlay.points.emplace_back(float(mapped.x + roi.x), float(mapped.y + roi.y));
    }
    return overlay;
}

// Slides the pattern over the image: the most exact position, for parts that keep their angle and size.
void findExact(const cv::Mat& gray, const cv::Mat& pattern, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    if (pattern.cols > roi.width || pattern.rows > roi.height) {
        out.error = "The taught pattern is larger than the search region.";
        return;
    }
    cv::Mat scores;
    cv::matchTemplate(gray, pattern, scores, cv::TM_CCOEFF_NORMED);

    double minScore = input.number("minScore", 0.7);
    int maxInstances = std::max(1, int(input.number("maxInstances", 1)));
    double best = 0;
    cv::Point bestAt;
    int found = 0;
    for (int i = 0; i < maxInstances; i++) {
        double score;
        cv::Point at;
        cv::minMaxLoc(scores, nullptr, &score, nullptr, &at);
        if (i == 0) {
            best = score;
            bestAt = at;
        }
        if (score < minScore) {
            break;
        }
        found++;
        cv::Mat pose = cv::Mat::eye(3, 3, CV_64F);
        pose.at<double>(0, 2) = at.x;
        pose.at<double>(1, 2) = at.y;
        out.overlays.push_back(outline(pose, pattern.size(), roi, cv::format("%.3f", score)));

        // Clear the neighbourhood of this match so the next pass finds a different part.
        cv::Rect around(at.x - pattern.cols / 2, at.y - pattern.rows / 2, pattern.cols, pattern.rows);
        scores(around & cv::Rect(0, 0, scores.cols, scores.rows)).setTo(-1);
    }

    out.measures.push_back({"count", double(found), ""});
    out.measures.push_back({"score", best, ""});
    out.measures.push_back({"x", double(bestAt.x + roi.x + pattern.cols / 2), "px"});
    out.measures.push_back({"y", double(bestAt.y + roi.y + pattern.rows / 2), "px"});
    out.measures.push_back({"angle", 0, "°"});
    out.measures.push_back({"scale", 1, "×"});
}

}  // namespace

const PatternMatcher::Features& PatternMatcher::patternFeatures(const cv::Mat& pattern, Kind kind) {
    bool same = cachedPattern.size() == pattern.size() && cachedPattern.type() == pattern.type() && !cachedPattern.empty();
    for (int y = 0; same && y < pattern.rows; y++) {
        same = std::memcmp(cachedPattern.ptr(y), pattern.ptr(y), size_t(pattern.cols) * pattern.elemSize()) == 0;
    }
    if (!same) {
        cachedPattern = pattern.clone();
        haveCached[ORB] = haveCached[SIFT] = false;
    }
    if (!haveCached[kind]) {
        Features& features = cached[kind];
        features = Features();
        if (kind == SIFT) {
            cv::SIFT::create(6000, 3, 0.03)->detectAndCompute(pattern, cv::noArray(), features.points, features.descriptors);
        } else {
            cv::ORB::create(6000, 1.2f, 8, 15, 0, 2, cv::ORB::HARRIS_SCORE, 31, 10)->detectAndCompute(pattern, cv::noArray(), features.points, features.descriptors);
        }
        haveCached[kind] = true;
    }
    return cached[kind];
}

void PatternMatcher::findByFeatures(const cv::Mat& gray, const cv::Mat& pattern, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    Kind kind = input.number("features", 0) == 1 ? SIFT : ORB;
    const Features& patternSide = patternFeatures(pattern, kind);
    if (int(patternSide.points.size()) < kMinPatternFeatures) {
        out.error = cv::format("This pattern has too little surface detail to search at any angle (%d features). Teach a more detailed area, or set Search to Same angle and size.", int(patternSide.points.size()));
        return;
    }

    double minScore = input.number("minScore", 0.7);
    int maxInstances = std::max(1, int(input.number("maxInstances", 1)));
    bool allowTilt = input.number("allowTilt", 1) != 0;

    Features imageSide;
    if (kind == SIFT) {
        cv::SIFT::create(6000, 3, 0.03)->detectAndCompute(gray, cv::noArray(), imageSide.points, imageSide.descriptors);
    } else {
        cv::ORB::create(6000, 1.2f, 8, 15, 0, 2, cv::ORB::HARRIS_SCORE, 31, 10)->detectAndCompute(gray, cv::noArray(), imageSide.points, imageSide.descriptors);
    }

    std::vector<Match> candidates = kind == SIFT
        ? findCandidates(patternSide.points, patternSide.descriptors, imageSide.points, imageSide.descriptors, cv::NORM_L2, maxInstances, 0.8f, 1e9f)
        : findCandidates(patternSide.points, patternSide.descriptors, imageSide.points, imageSide.descriptors, cv::NORM_HAMMING, maxInstances, 0.85f, 64);
    std::vector<std::vector<int>> clusters = clusterByPose(candidates, pattern.size());

    std::vector<bool> used(candidates.size(), false);
    std::vector<Located> parts;
    Located best;
    bool haveBest = false;
    int verifications = 0;
    double separation = std::min(pattern.cols, pattern.rows) / 2.0;
    for (const auto& cluster : clusters) {
        if (int(parts.size()) >= maxInstances || verifications >= kMaxVerifications) {
            break;
        }
        Located part;
        if (!fitPose(cluster, candidates, used, allowTilt, pattern.size(), part)) {
            continue;
        }
        bool isKnown = std::any_of(parts.begin(), parts.end(), [&](const Located& other) {
            return cv::norm(other.center - part.center) < separation * std::min(other.scale, part.scale);
        });
        if (isKnown) {
            continue;
        }
        verifications++;
        part.score = verifyPose(gray, pattern, part.pose, part.scale);
        if (!haveBest || part.score > best.score) {
            haveBest = true;
            best = part;
        }
        if (part.score >= minScore) {
            for (int index : part.inliers) {
                used[size_t(index)] = true;
            }
            parts.push_back(part);
            out.overlays.push_back(outline(part.pose, pattern.size(), roi, cv::format("%.3f, %.0f°", part.score, part.degrees)));
        }
    }

    out.measures.push_back({"count", double(parts.size()), ""});
    out.measures.push_back({"score", haveBest ? best.score : 0.0, ""});
    if (haveBest) {
        out.measures.push_back({"x", best.center.x + roi.x, "px"});
        out.measures.push_back({"y", best.center.y + roi.y, "px"});
        out.measures.push_back({"angle", best.degrees, "°"});
        out.measures.push_back({"scale", best.scale, "×"});
        out.measures.push_back({"tilt", best.tilt, "°"});
        out.measures.push_back({"matches", double(best.inliers.size()), ""});
    }
}

void PatternMatcher::run(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    if (input.templ.empty()) {
        out.error = "No pattern taught yet. Draw a region around the part and press Teach Pattern.";
        return;
    }
    cv::Mat gray, pattern;
    cv::cvtColor(bgr(roi), gray, cv::COLOR_BGR2GRAY);
    cv::cvtColor(input.templ, pattern, cv::COLOR_BGR2GRAY);
    double search = input.number("search", 0);
    if (search == 1) {
        findExact(gray, pattern, roi, input, out);
    } else if (search == 2) {
        edges.run(gray, pattern, roi, input, out);
    } else {
        findByFeatures(gray, pattern, roi, input, out);
    }
}

}  // namespace mxv
