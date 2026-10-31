// Engine tests against images with known answers. Run with Tests/run.sh.
#include "../MxOpenCVD/Engine/ColorTools.hpp"
#include "../MxOpenCVD/Engine/Engine.hpp"

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <cstdio>
#include <algorithm>
#include <utility>
#include <vector>
#include <cmath>
#include <string>

using namespace mxv;

static int failures = 0;
static int checks = 0;

#define CHECK(condition, ...)                                     \
    do {                                                          \
        checks++;                                                 \
        if (!(condition)) {                                       \
            failures++;                                           \
            printf("  FAILED %s:%d: %s  ", __FILE__, __LINE__, #condition); \
            printf(__VA_ARGS__);                                  \
            printf("\n");                                         \
        }                                                         \
    } while (0)

static double measure(const ToolOutput& out, const std::string& name) {
    for (const auto& m : out.measures) {
        if (m.name == name) {
            return m.value;
        }
    }
    return NAN;
}

static bool hasText(const ToolOutput& out, const std::string& text) {
    return std::find(out.texts.begin(), out.texts.end(), text) != out.texts.end();
}

static std::string joined(const ToolOutput& out) {
    std::string all;
    for (const auto& t : out.texts) {
        all += "[" + t + "] ";
    }
    return all + (out.error.empty() ? "" : " error: " + out.error);
}

static void testQuality(Engine& engine) {
    cv::Mat sharp(400, 600, CV_8UC3);
    cv::randu(sharp, cv::Scalar::all(0), cv::Scalar::all(255));
    cv::Mat soft;
    cv::GaussianBlur(sharp, soft, cv::Size(21, 21), 0);
    ToolOutput a = engine.run("quality", sharp, {});
    ToolOutput b = engine.run("quality", soft, {});
    CHECK(measure(a, "sharpness") > 50 * measure(b, "sharpness"), "sharp %f, soft %f", measure(a, "sharpness"), measure(b, "sharpness"));

    cv::Mat white(100, 100, CV_8UC3, cv::Scalar::all(255));
    ToolOutput c = engine.run("quality", white, {});
    CHECK(measure(c, "clipped_highlights") == 100, "%f", measure(c, "clipped_highlights"));
    CHECK(measure(c, "brightness") == 255, "%f", measure(c, "brightness"));
}

static void testBlobs(Engine& engine) {
    cv::Mat image(480, 640, CV_8UC3, cv::Scalar::all(235));
    for (int i = 0; i < 5; i++) {
        cv::circle(image, cv::Point(80 + i * 120, 240), 30, cv::Scalar::all(25), cv::FILLED, cv::LINE_AA);
    }
    cv::circle(image, cv::Point(320, 60), 2, cv::Scalar::all(25), cv::FILLED);  // dust, below minArea

    ToolInput input;
    input.numbers = {{"polarity", 0}, {"minArea", 100}};
    ToolOutput out = engine.run("blobs", image, input);
    CHECK(out.error.empty(), "%s", out.error.c_str());
    CHECK(measure(out, "count") == 5, "%f", measure(out, "count"));
    double expected = M_PI * 30 * 30;
    CHECK(std::abs(measure(out, "largest_area") - expected) < expected * 0.05, "%f", measure(out, "largest_area"));
    CHECK(std::abs(measure(out, "largest_length") - 60) < 3, "%f", measure(out, "largest_length"));

    // Calibrated, the same part reads in millimetres.
    input.mmPerPixel = 0.1;
    ToolOutput mm = engine.run("blobs", image, input);
    CHECK(std::abs(measure(mm, "largest_length") - 6) < 0.3, "%f", measure(mm, "largest_length"));

    // The region of interest limits the count, and overlays come back in full-image coordinates.
    input.mmPerPixel = 0;
    input.roi = cv::Rect(0, 150, 260, 180);
    ToolOutput region = engine.run("blobs", image, input);
    CHECK(measure(region, "count") == 2, "%f", measure(region, "count"));
    CHECK(!region.overlays.empty() && region.overlays[0].points[0].y > 150, "overlay is in region coordinates");

    // Bright-on-dark polarity sees the inverse image the same way.
    cv::Mat inverted = cv::Scalar::all(255) - image;
    ToolInput bright;
    bright.numbers = {{"polarity", 1}, {"minArea", 100}};
    CHECK(measure(engine.run("blobs", inverted, bright), "count") == 5, "inverted count");

    // The fixed threshold.
    ToolInput fixedLevel;
    fixedLevel.numbers = {{"polarity", 0}, {"method", 1}, {"threshold", 128}, {"minArea", 100}};
    CHECK(measure(engine.run("blobs", image, fixedLevel), "count") == 5, "fixed threshold count");
}

static void testCaliper(Engine& engine) {
    cv::Mat image(300, 800, CV_8UC3, cv::Scalar::all(230));
    cv::rectangle(image, cv::Rect(150, 0, 250, 300), cv::Scalar::all(40), cv::FILLED);
    cv::Mat noise(image.size(), CV_8UC3);
    cv::randn(noise, cv::Scalar::all(0), cv::Scalar::all(6));
    image = image + noise;

    ToolInput input;
    input.numbers = {{"axis", 0}, {"minEdge", 4}};
    ToolOutput out = engine.run("caliper", image, input);
    CHECK(measure(out, "edges") == 2, "%f", measure(out, "edges"));
    CHECK(std::abs(measure(out, "distance") - 250) < 1, "%f", measure(out, "distance"));

    input.mmPerPixel = 0.05;
    CHECK(std::abs(measure(engine.run("caliper", image, input), "distance") - 12.5) < 0.05, "calibrated");

    cv::Mat turned;
    cv::rotate(image, turned, cv::ROTATE_90_CLOCKWISE);
    ToolInput vertical;
    vertical.numbers = {{"axis", 1}, {"minEdge", 4}};
    CHECK(std::abs(measure(engine.run("caliper", turned, vertical), "distance") - 250) < 1, "vertical");
}

// A copy of the part, turned and scaled about its middle, on a plain background with a little noise.
static cv::Mat partInFrame(const cv::Mat& part, double degrees, double scale, cv::Point2f center, cv::Size size = cv::Size(1920, 1440)) {
    cv::Mat frame(size, CV_8UC3, cv::Scalar(150, 160, 170));
    cv::Mat pose = cv::getRotationMatrix2D(cv::Point2f(part.cols / 2.f, part.rows / 2.f), degrees, scale);
    pose.at<double>(0, 2) += center.x - part.cols / 2.0;
    pose.at<double>(1, 2) += center.y - part.rows / 2.0;
    cv::warpAffine(part, frame, pose, size, cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
    return frame;
}

// A flat part seen by a camera tilted away from it, centered unless offset, through a 1500-pixel focal length.
static cv::Mat partTilted(const cv::Mat& part, double tiltDegrees, double spinDegrees, double scale, cv::Point2f offset = cv::Point2f(0, 0), cv::Size size = cv::Size(1920, 1440)) {
    cv::Mat frame(size, CV_8UC3, cv::Scalar(150, 160, 170));
    double t = tiltDegrees * CV_PI / 180, s = spinDegrees * CV_PI / 180;
    cv::Matx33d rotation = cv::Matx33d(std::cos(s), -std::sin(s), 0, std::sin(s), std::cos(s), 0, 0, 0, 1) * cv::Matx33d(1, 0, 0, 0, std::cos(t), -std::sin(t), 0, std::sin(t), std::cos(t));
    cv::Point2f from[4] = {{0, 0}, {float(part.cols), 0}, {float(part.cols), float(part.rows)}, {0, float(part.rows)}};
    cv::Point2f to[4];
    for (int i = 0; i < 4; i++) {
        cv::Vec3d p = rotation * cv::Vec3d(from[i].x - part.cols / 2.0, from[i].y - part.rows / 2.0, 0);
        double z = p[2] + 1500 / scale;
        to[i] = cv::Point2f(float(1500 * p[0] / z + size.width / 2.0 + offset.x), float(1500 * p[1] / z + size.height / 2.0 + offset.y));
    }
    cv::warpPerspective(part, frame, cv::getPerspectiveTransform(from, to), size, cv::INTER_LINEAR, cv::BORDER_TRANSPARENT);
    return frame;
}

static cv::Mat withNoise(const cv::Mat& image, double sigma = 3) {
    cv::Mat noise(image.size(), CV_8UC3);
    cv::randn(noise, cv::Scalar::all(0), cv::Scalar::all(sigma));
    return image + noise;
}

static double angleDifference(double a, double b) {
    double d = std::fmod(std::abs(a - b), 360);
    return d > 180 ? 360 - d : d;
}

static void testPattern(Engine& engine, const std::string& fixtures, const std::string& extraPatterns) {
    // Same angle and size, the exact search: the old behaviour, available as a setting.
    cv::Mat image(480, 640, CV_8UC3);
    cv::randu(image, cv::Scalar::all(0), cv::Scalar::all(255));
    cv::GaussianBlur(image, image, cv::Size(5, 5), 0);
    cv::Rect place(300, 200, 60, 40);

    ToolInput exact;
    exact.templ = image(place).clone();
    exact.numbers = {{"minScore", 0.8}, {"search", 1}};
    ToolOutput out = engine.run("pattern", image, exact);
    CHECK(measure(out, "count") == 1, "%f", measure(out, "count"));
    CHECK(measure(out, "score") > 0.99, "%f", measure(out, "score"));
    CHECK(measure(out, "x") == 330 && measure(out, "y") == 220, "%f,%f", measure(out, "x"), measure(out, "y"));
    CHECK(measure(out, "angle") == 0 && measure(out, "scale") == 1, "%f,%f", measure(out, "angle"), measure(out, "scale"));
    exact.roi = cv::Rect(0, 0, 200, 150);
    CHECK(measure(engine.run("pattern", image, exact), "count") == 0, "found outside the search region");

    ToolOutput untaught = engine.run("pattern", image, {});
    CHECK(!untaught.error.empty(), "an untaught pattern should say so");

    // Any angle, the default: the part is found wherever it's turned, and reports how.
    cv::Mat label = cv::imread(fixtures + "/label.png");
    ToolInput anyAngle;
    anyAngle.templ = label;
    anyAngle.numbers = {{"minScore", 0.7}};
    struct Placement { double degrees, scale; };
    double slowest = 0;
    for (Placement placement : {Placement{0, 1}, {10, 1}, {30, 1}, {90, 1}, {180, 1}, {-135, 1}, {30, 0.7}, {-60, 1.4}, {15, 0.5}, {25, 0.35}, {200, 1.8}}) {
        cv::Point2f center(1000, 700);
        ToolOutput found = engine.run("pattern", withNoise(partInFrame(label, placement.degrees, placement.scale, center)), anyAngle);
        CHECK(found.error.empty(), "%s", found.error.c_str());
        CHECK(measure(found, "count") == 1, "rot %.0f scale %.1f: count %f, score %f", placement.degrees, placement.scale, measure(found, "count"), measure(found, "score"));
        CHECK(measure(found, "score") >= 0.7, "rot %.0f scale %.1f: score %f", placement.degrees, placement.scale, measure(found, "score"));
        CHECK(std::hypot(measure(found, "x") - center.x, measure(found, "y") - center.y) < 3, "rot %.0f scale %.1f: at %f,%f", placement.degrees, placement.scale, measure(found, "x"), measure(found, "y"));
        CHECK(angleDifference(measure(found, "angle"), placement.degrees) < 1, "rot %.0f scale %.1f: angle %f", placement.degrees, placement.scale, measure(found, "angle"));
        CHECK(std::abs(measure(found, "scale") - placement.scale) < 0.03 * placement.scale, "rot %.0f scale %.1f: scale %f", placement.degrees, placement.scale, measure(found, "scale"));
        slowest = std::max(slowest, found.elapsedMs);
    }
    printf("  Any-angle pattern search at 1920 x 1440: %.0f ms at slowest\n", slowest);

    // The outline turns with the part, in full-image coordinates.
    ToolOutput turned = engine.run("pattern", withNoise(partInFrame(label, 90, 1, cv::Point2f(1000, 700))), anyAngle);
    if (!turned.overlays.empty() && turned.overlays[0].points.size() == 4) {
        const auto& corners = turned.overlays[0].points;
        CHECK(std::abs(cv::norm(corners[0] - corners[1]) - label.cols) < 4, "outline width %f", cv::norm(corners[0] - corners[1]));
        CHECK(std::abs(corners[0].x - corners[1].x) < 4, "a part turned 90 degrees should have a vertical top edge");
    } else {
        CHECK(false, "no outline for the turned part");
    }

    // Real-world changes that shouldn't stop it finding the part.
    cv::Mat brighter = partInFrame(label, 25, 1, cv::Point2f(1000, 700)) * 0.75;
    CHECK(measure(engine.run("pattern", withNoise(brighter), anyAngle), "count") == 1, "darker exposure");
    cv::Mat soft;
    cv::GaussianBlur(partInFrame(label, 25, 1, cv::Point2f(1000, 700)), soft, cv::Size(5, 5), 0);
    CHECK(measure(engine.run("pattern", withNoise(soft), anyAngle), "count") == 1, "slightly out of focus");

    // Several parts, each at its own angle.
    cv::Mat three = partInFrame(label, 20, 0.8, cv::Point2f(500, 300));
    cv::Mat second = partInFrame(label, -40, 0.8, cv::Point2f(1400, 400));
    cv::Mat third = partInFrame(label, 150, 0.8, cv::Point2f(900, 1100));
    cv::Mat background(three.size(), CV_8UC3, cv::Scalar(150, 160, 170));
    for (const cv::Mat& layer : {second, third}) {
        cv::Mat difference;
        cv::absdiff(layer, background, difference);
        cv::Mat mask;
        cv::cvtColor(difference, mask, cv::COLOR_BGR2GRAY);
        layer.copyTo(three, mask > 0);
    }
    ToolInput several = anyAngle;
    several.numbers["maxInstances"] = 5;
    ToolOutput parts = engine.run("pattern", withNoise(three), several);
    CHECK(measure(parts, "count") == 3, "three parts in view: found %f", measure(parts, "count"));
    CHECK(parts.overlays.size() == 3, "three outlines: %zu", parts.overlays.size());

    // The search stays inside its region.
    ToolInput limited = anyAngle;
    limited.roi = cv::Rect(0, 0, 500, 400);
    CHECK(measure(engine.run("pattern", withNoise(partInFrame(label, 30, 1, cv::Point2f(1300, 1000))), limited), "count") == 0, "found outside the search region");
    limited.roi = cv::Rect(700, 500, 1100, 800);
    ToolOutput inRegion = engine.run("pattern", withNoise(partInFrame(label, 30, 1, cv::Point2f(1300, 900))), limited);
    CHECK(measure(inRegion, "count") == 1, "in the region: %f", measure(inRegion, "count"));
    CHECK(std::hypot(measure(inRegion, "x") - 1300, measure(inRegion, "y") - 900) < 3, "region offset: %f,%f", measure(inRegion, "x"), measure(inRegion, "y"));

    // What must not be found: another part, a mirror image, or a part that's missing.
    cv::Mat other(320, 900, CV_8UC3, cv::Scalar(246, 244, 238));
    cv::putText(other, "SERIAL 4471-Q", cv::Point(50, 100), cv::FONT_HERSHEY_SIMPLEX, 2, cv::Scalar::all(20), 3, cv::LINE_AA);
    cv::putText(other, "BATCH 30-11-98", cv::Point(50, 220), cv::FONT_HERSHEY_COMPLEX, 1.6, cv::Scalar::all(30), 2, cv::LINE_AA);
    ToolOutput wrong = engine.run("pattern", withNoise(partInFrame(other, 20, 1, cv::Point2f(1000, 700))), anyAngle);
    CHECK(measure(wrong, "count") == 0, "found a different part, score %f", measure(wrong, "score"));
    cv::Mat mirrored;
    cv::flip(label, mirrored, 1);
    CHECK(measure(engine.run("pattern", withNoise(partInFrame(mirrored, 10, 1, cv::Point2f(1000, 700))), anyAngle), "count") == 0, "a mirror image isn't the part");
    cv::Mat empty(1440, 1920, CV_8UC3, cv::Scalar(150, 160, 170));
    ToolOutput none = engine.run("pattern", withNoise(empty), anyAngle);
    CHECK(none.error.empty() && measure(none, "count") == 0, "an empty scene: %s", none.error.c_str());
    cv::Mat blackFrame(1440, 1920, CV_8UC3, cv::Scalar::all(0));
    ToolOutput black = engine.run("pattern", blackFrame, anyAngle);
    CHECK(black.error.empty() && measure(black, "count") == 0, "a black frame: %s", black.error.c_str());

    // A plain pattern can't be searched for by features, and has to say so rather than quietly finding nothing.
    ToolInput plain;
    plain.templ = cv::Mat(100, 100, CV_8UC3, cv::Scalar::all(128));
    ToolOutput plainOut = engine.run("pattern", withNoise(empty), plain);
    CHECK(!plainOut.error.empty(), "a plain pattern should explain itself");
    CHECK(plainOut.error.find("Same angle") != std::string::npos, "%s", plainOut.error.c_str());

    // A small pattern, the size a tight region gives, and a pattern larger than the search region.
    ToolInput small;
    small.templ = label(cv::Rect(40, 30, 330, 75)).clone();
    small.numbers = {{"minScore", 0.7}};
    ToolOutput smallOut = engine.run("pattern", withNoise(partInFrame(label, 35, 1, cv::Point2f(1000, 700))), small);
    CHECK(smallOut.error.empty(), "%s", smallOut.error.c_str());
    CHECK(measure(smallOut, "count") == 1, "a small pattern: count %f, score %f", measure(smallOut, "count"), measure(smallOut, "score"));
    CHECK(angleDifference(measure(smallOut, "angle"), 35) < 2, "a small pattern's angle: %f", measure(smallOut, "angle"));
    // The top of the documented size range, and a part too cut off by the frame's edge to be trusted.
    ToolOutput enlarged = engine.run("pattern", withNoise(partInFrame(small.templ, 25, 4, cv::Point2f(960, 720))), small);
    CHECK(measure(enlarged, "count") == 1 && std::abs(measure(enlarged, "scale") - 4) < 0.12, "four times the size: count %f, scale %f", measure(enlarged, "count"), measure(enlarged, "scale"));
    ToolOutput cutOff = engine.run("pattern", withNoise(partInFrame(label, 0, 1, cv::Point2f(0, 720))), anyAngle);
    CHECK(measure(cutOff, "count") == 0, "half the part is out of view: count %f, score %f", measure(cutOff, "count"), measure(cutOff, "score"));
    // A flat part viewed at an angle, as a phone rarely sits square to it. Both feature types, and a rigid pose as a
    // control: with tilt turned off these scenes should fail, or the test wouldn't show that tilt is what's handled.
    for (double features : {0.0, 1.0}) {
        ToolInput tilting = anyAngle;
        tilting.numbers["features"] = features;
        for (double tilt : {15.0, 30.0, 45.0}) {
            ToolOutput seen = engine.run("pattern", withNoise(partTilted(label, tilt, 20, 1)), tilting);
            CHECK(seen.error.empty(), "%s", seen.error.c_str());
            CHECK(measure(seen, "count") == 1, "features %.0f tilt %.0f: count %f, score %f", features, tilt, measure(seen, "count"), measure(seen, "score"));
            CHECK(measure(seen, "score") > 0.9, "features %.0f tilt %.0f: score %f", features, tilt, measure(seen, "score"));
            CHECK(std::hypot(measure(seen, "x") - 960, measure(seen, "y") - 720) < 6, "features %.0f tilt %.0f: at %f,%f", features, tilt, measure(seen, "x"), measure(seen, "y"));
            CHECK(std::abs(measure(seen, "tilt") - tilt) < 6, "features %.0f tilt %.0f: measured %f", features, tilt, measure(seen, "tilt"));
            CHECK(measure(seen, "matches") >= 8, "features %.0f tilt %.0f: matches %f", features, tilt, measure(seen, "matches"));
        }
        ToolOutput flat = engine.run("pattern", withNoise(partInFrame(label, 30, 1, cv::Point2f(960, 720))), tilting);
        CHECK(measure(flat, "count") == 1, "features %.0f flat: %f", features, measure(flat, "count"));
        CHECK(measure(flat, "tilt") < 5, "features %.0f: a flat part measured a tilt of %f", features, measure(flat, "tilt"));
    }
    ToolInput rigid = anyAngle;
    rigid.numbers["allowTilt"] = 0;
    CHECK(measure(engine.run("pattern", withNoise(partTilted(label, 45, 20, 1)), rigid), "count") == 0, "a rigid pose can't follow a 45 degree tilt");
    CHECK(measure(engine.run("pattern", withNoise(partInFrame(label, 30, 1, cv::Point2f(960, 720))), rigid), "count") == 1, "a rigid pose finds a flat part");

    // The outline follows the tilt: the near edge of a tilted part looks longer than the far edge.
    ToolOutput skewed = engine.run("pattern", withNoise(partTilted(label, 45, 0, 1)), anyAngle);
    if (!skewed.overlays.empty() && skewed.overlays[0].points.size() == 4) {
        const auto& corners = skewed.overlays[0].points;
        double top = cv::norm(corners[0] - corners[1]), bottom = cv::norm(corners[3] - corners[2]);
        CHECK(std::abs(top - bottom) > 10, "a tilted outline should be a trapezoid: %f and %f", top, bottom);
    } else {
        CHECK(false, "no outline for the tilted part");
    }

    // A taught region usually includes background. A wide border around the part, in strong contrast to where it's
    // found later, used to bring the whole score below any sensible limit.
    cv::Mat framed(label.rows + 200, label.cols + 200, CV_8UC3, cv::Scalar(30, 60, 90));
    cv::randu(framed, cv::Scalar::all(0), cv::Scalar::all(255));
    cv::GaussianBlur(framed, framed, cv::Size(15, 15), 0);
    label.copyTo(framed(cv::Rect(100, 100, label.cols, label.rows)));
    ToolInput withBackground = anyAngle;
    withBackground.templ = framed;
    cv::Mat elsewhere(1440, 1920, CV_8UC3, cv::Scalar(150, 160, 170));
    label.copyTo(elsewhere(cv::Rect(500, 500, label.cols, label.rows)));
    ToolOutput backgroundTaught = engine.run("pattern", withNoise(elsewhere), withBackground);
    CHECK(measure(backgroundTaught, "count") == 1, "background in the taught region: count %f, score %f", measure(backgroundTaught, "count"), measure(backgroundTaught, "score"));

    // Several parts with different tilts can't share one pose, so each needs its own.
    cv::Mat twoTilted = partTilted(label, 30, 10, 0.55, cv::Point2f(-480, -320));
    cv::Mat otherTilted = partTilted(label, -25, -35, 0.55, cv::Point2f(480, 320));
    cv::Mat tiltedMask;
    cv::absdiff(otherTilted, background, tiltedMask);
    cv::cvtColor(tiltedMask, tiltedMask, cv::COLOR_BGR2GRAY);
    otherTilted.copyTo(twoTilted, tiltedMask > 0);
    ToolOutput bothTilted = engine.run("pattern", withNoise(twoTilted), several);
    CHECK(measure(bothTilted, "count") == 2, "two parts at different tilts: found %f", measure(bothTilted, "count"));

    // Teaching a new pattern can't leave the old one's features behind.
    ToolInput first = anyAngle;
    first.templ = label;
    ToolInput second2 = anyAngle;
    second2.templ = other;
    cv::Mat firstScene = withNoise(partInFrame(label, 20, 1, cv::Point2f(960, 720)));
    CHECK(measure(engine.run("pattern", firstScene, first), "count") == 1, "the first pattern");
    CHECK(measure(engine.run("pattern", firstScene, second2), "count") == 0, "a newly taught pattern, in a scene without it");
    CHECK(measure(engine.run("pattern", firstScene, first), "count") == 1, "the first pattern again");

    ToolInput tooBig = anyAngle;
    tooBig.roi = cv::Rect(0, 0, 200, 100);
    CHECK(engine.run("pattern", empty, tooBig).error.empty(), "any-angle allows a part that looks smaller than its pattern");

    // Optional: patterns from real use, each turned about its middle. Skipped when none are given.
    if (!extraPatterns.empty()) {
        for (const std::string& file : {std::string("user_pattern_1.png"), std::string("user_pattern_4.png")}) {
            cv::Mat pattern = cv::imread(extraPatterns + "/" + file);
            if (pattern.empty()) {
                continue;
            }
            ToolInput real;
            real.templ = pattern;
            real.numbers = {{"minScore", 0.7}};
            for (double degrees : {0.0, 12.0, 45.0, 180.0}) {
                cv::Point2f center(960, 720);
                ToolOutput found = engine.run("pattern", withNoise(partInFrame(pattern, degrees, 1, center)), real);
                printf("  %s rot %3.0f: count %.0f score %.3f angle %.1f pos err %.1f (%.0f ms) %s\n", file.c_str(), degrees, measure(found, "count"), measure(found, "score"),
                       measure(found, "angle"), std::hypot(measure(found, "x") - center.x, measure(found, "y") - center.y), found.elapsedMs, found.error.c_str());
            }
        }
    }
}

static void testChessboard() {
    int cols = 9, rows = 6, square = 40;
    cv::Mat image(600, 800, CV_8UC3, cv::Scalar::all(255));
    cv::Point origin(120, 100);
    for (int y = 0; y < rows + 1; y++) {
        for (int x = 0; x < cols + 1; x++) {
            if ((x + y) % 2 == 0) {
                cv::rectangle(image, cv::Rect(origin.x + x * square, origin.y + y * square, square, square), cv::Scalar::all(0), cv::FILLED);
            }
        }
    }
    ChessboardScale scale = measureChessboard(image, cols, rows, 10);
    CHECK(scale.found, "no board found");
    CHECK(std::abs(scale.mmPerPixel - 0.25) < 0.0025, "%f", scale.mmPerPixel);

    cv::Mat blank(600, 800, CV_8UC3, cv::Scalar::all(255));
    CHECK(!measureChessboard(blank, cols, rows, 10).found, "found a board in a blank image");
}

static void testOCR(Engine& engine, const std::string& fixtures) {
    cv::Mat label = cv::imread(fixtures + "/label.png");
    CHECK(!label.empty(), "no label.png");

    ToolOutput out = engine.run("ocr", label, {});
    printf("  OCR read %s in %.0f ms (with model load)\n", joined(out).c_str(), out.elapsedMs);
    CHECK(out.error.empty(), "%s", out.error.c_str());
    CHECK(hasText(out, "LOT A7-20391"), "%s", joined(out).c_str());
    CHECK(hasText(out, "EXP 2027-03-15"), "%s", joined(out).c_str());
    CHECK(measure(out, "lines") == 3, "%f", measure(out, "lines"));
    CHECK(measure(out, "mean_score") > 0.9, "%f", measure(out, "mean_score"));
    if (out.texts.size() >= 2) {
        CHECK(out.texts[0] == "LOT A7-20391", "reading order: %s", joined(out).c_str());
    }

    ToolOutput again = engine.run("ocr", label, {});
    printf("  OCR again in %.0f ms\n", again.elapsedMs);

    // Upside down: the orientation model has to turn every line back over.
    cv::Mat flipped;
    cv::rotate(label, flipped, cv::ROTATE_180);
    ToolOutput upside = engine.run("ocr", flipped, {});
    CHECK(hasText(upside, "LOT A7-20391"), "upside down: %s", joined(upside).c_str());

    // A tight region reads just that line, and its boxes land in full-image coordinates.
    ToolInput region;
    region.roi = cv::Rect(30, 25, 500, 75);
    ToolOutput tight = engine.run("ocr", label, region);
    CHECK(tight.texts.size() == 1 && tight.texts[0] == "LOT A7-20391", "%s", joined(tight).c_str());
    CHECK(!tight.overlays.empty() && tight.overlays[0].points[0].x >= 30, "region offset");

    // Slightly rotated and small, as from a hand-placed part.
    cv::Mat turned;
    cv::warpAffine(label, turned, cv::getRotationMatrix2D(cv::Point2f(450, 160), 6, 0.7), label.size(), cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(246, 244, 238));
    ToolOutput skew = engine.run("ocr", turned, {});
    CHECK(hasText(skew, "LOT A7-20391"), "skewed: %s", joined(skew).c_str());

    cv::Mat blank(400, 600, CV_8UC3, cv::Scalar::all(128));
    CHECK(measure(engine.run("ocr", blank, {}), "lines") == 0, "read text from a blank image");
}

static void testCustomOnnx(Engine& engine, const std::string& models, const std::string& fixtures) {
    cv::Mat image(200, 200, CV_8UC3, cv::Scalar::all(128));

    ToolOutput none = engine.run("onnx", image, {});
    CHECK(!none.error.empty(), "no model should be an error");

    ToolInput missing;
    missing.strings = {{"modelPath", "/nonexistent.onnx"}};
    ToolOutput bad = engine.run("onnx", image, missing);
    CHECK(!bad.error.empty(), "a missing model should be an error");

    // The orientation model is a real two-class classifier with fixed 80 × 160 input.
    ToolInput classify;
    classify.strings = {{"modelPath", models + "/pplcnet_x025_textline_ori.onnx"}};
    classify.numbers = {{"colorOrder", 0}, {"normalization", 1}};
    cv::Mat label = cv::imread(fixtures + "/label.png");
    cv::Mat flipped;
    cv::rotate(label, flipped, cv::ROTATE_180);
    ToolOutput upright = engine.run("onnx", label(cv::Rect(40, 30, 420, 75)), classify);
    ToolOutput upside = engine.run("onnx", flipped(cv::Rect(440, 215, 420, 75)), classify);
    CHECK(upright.error.empty(), "%s", upright.error.c_str());
    CHECK(measure(upright, "class") == 0, "upright class %f", measure(upright, "class"));
    CHECK(measure(upside, "class") == 1, "upside-down class %f", measure(upside, "class"));
    CHECK(measure(upright, "score") > 0.5 && measure(upright, "score") <= 1, "%f", measure(upright, "score"));

    // The fixtures return fixed boxes in a 64 × 64 input. A 128 × 128 image scales them by two.
    cv::Mat square(128, 128, CV_8UC3, cv::Scalar::all(50));
    for (const char* file : {"/tiny_yolo.onnx", "/tiny_yolo_channels_first.onnx"}) {
        ToolInput yolo;
        yolo.strings = {{"modelPath", fixtures + file}};
        yolo.numbers = {{"modelMode", 1}, {"confidence", 0.25}, {"iou", 0.45}};
        ToolOutput found = engine.run("onnx", square, yolo);
        CHECK(found.error.empty(), "%s: %s", file, found.error.c_str());
        CHECK(measure(found, "count") == 2, "%s: %f", file, measure(found, "count"));
        CHECK(std::abs(measure(found, "top_score") - 0.9) < 1e-5, "%s: %f", file, measure(found, "top_score"));
        if (!found.overlays.empty()) {
            CHECK(std::abs(found.overlays[0].points[0].x - 44) < 1, "%s: %f", file, found.overlays[0].points[0].x);
            CHECK(std::abs(found.overlays[0].points[2].y - 84) < 1, "%s: %f", file, found.overlays[0].points[2].y);
        }
    }
}

// A plain machined part: one flat shade with holes, no surface detail to speak of.
static cv::Mat plainBracket() {
    cv::Mat part(300, 420, CV_8UC3, cv::Scalar::all(225));
    std::vector<cv::Point> outline{{40, 40}, {380, 40}, {380, 140}, {240, 140}, {240, 260}, {120, 260}, {120, 140}, {40, 140}};
    cv::fillPoly(part, std::vector<std::vector<cv::Point>>{outline}, cv::Scalar::all(60), cv::LINE_AA);
    for (cv::Point hole : {cv::Point(90, 90), cv::Point(330, 90)}) {
        cv::circle(part, hole, 24, cv::Scalar::all(225), cv::FILLED, cv::LINE_AA);
    }
    cv::circle(part, cv::Point(180, 210), 18, cv::Scalar::all(225), cv::FILLED, cv::LINE_AA);
    return part;
}

static cv::Mat plainGasket() {
    cv::Mat part(320, 320, CV_8UC3, cv::Scalar::all(230));
    cv::ellipse(part, cv::Point(160, 160), cv::Size(130, 95), 0, 0, 360, cv::Scalar::all(70), cv::FILLED, cv::LINE_AA);
    cv::rectangle(part, cv::Point(120, 130), cv::Point(200, 190), cv::Scalar::all(230), cv::FILLED, cv::LINE_AA);
    cv::circle(part, cv::Point(60, 160), 12, cv::Scalar::all(230), cv::FILLED, cv::LINE_AA);
    cv::circle(part, cv::Point(260, 160), 12, cv::Scalar::all(230), cv::FILLED, cv::LINE_AA);
    cv::circle(part, cv::Point(160, 90), 8, cv::Scalar::all(230), cv::FILLED, cv::LINE_AA);
    return part;
}

// The part with its center exactly here, to a fraction of a pixel, on a plain background.
static cv::Mat placed(const cv::Mat& part, double degrees, double scale, cv::Point2f center, cv::Scalar background = cv::Scalar::all(205)) {
    cv::Mat frame(1440, 1920, CV_8UC3, background);
    cv::Mat pose = cv::getRotationMatrix2D(cv::Point2f((part.cols - 1) / 2.f, (part.rows - 1) / 2.f), degrees, scale);
    pose.at<double>(0, 2) += center.x - (part.cols - 1) / 2.0;
    pose.at<double>(1, 2) += center.y - (part.rows - 1) / 2.0;
    cv::warpAffine(part, frame, pose, frame.size(), cv::INTER_CUBIC, cv::BORDER_TRANSPARENT);
    return frame;
}

static cv::Mat busyScene(int seed, int shapes = 300) {
    cv::RNG random(seed);
    cv::Mat frame(1440, 1920, CV_8UC3, cv::Scalar::all(205));
    for (int i = 0; i < shapes; i++) {
        cv::Scalar color = cv::Scalar::all(random.uniform(20, 250));
        cv::Point at(random.uniform(0, 1920), random.uniform(0, 1440));
        int kind = random.uniform(0, 3);
        if (kind == 0) {
            cv::rectangle(frame, cv::Rect(at.x, at.y, random.uniform(10, 150), random.uniform(10, 150)), color, cv::FILLED);
        } else if (kind == 1) {
            cv::circle(frame, at, random.uniform(5, 60), color, cv::FILLED, cv::LINE_AA);
        } else {
            cv::line(frame, at, cv::Point(at.x + random.uniform(-200, 200), at.y + random.uniform(-200, 200)), color, random.uniform(1, 6), cv::LINE_AA);
        }
    }
    return frame;
}

static void testEdgeSearch(Engine& engine) {
    cv::Mat bracket = plainBracket(), gasket = plainGasket();
    ToolInput edges;
    edges.templ = bracket;
    edges.numbers = {{"search", 2}, {"minScore", 0.7}};

    // Known sub-pixel poses. These are best-case images, so the limits are for catching a regression, and they say
    // nothing about what a real camera can do. Use --repeat for that.
    cv::RNG random(42);
    double slowest = 0, worstPosition = 0, worstAngle = 0, worstScale = 0;
    for (int i = 0; i < 25; i++) {
        double degrees = random.uniform(-180.0, 180.0), scale = random.uniform(0.75, 1.3);
        cv::Point2f center(960 + random.uniform(-200.f, 200.f), 720 + random.uniform(-120.f, 120.f));
        ToolOutput out = engine.run("pattern", withNoise(placed(bracket, degrees, scale, center), 4), edges);
        CHECK(measure(out, "count") == 1, "pose %d: count %f, score %f", i, measure(out, "count"), measure(out, "score"));
        worstPosition = std::max(worstPosition, std::hypot(measure(out, "x") - center.x, measure(out, "y") - center.y));
        worstAngle = std::max(worstAngle, angleDifference(measure(out, "angle"), degrees));
        worstScale = std::max(worstScale, std::abs(measure(out, "scale") / scale - 1));
        slowest = std::max(slowest, out.elapsedMs);
    }
    printf("  Edge search on 25 poses: worst position %.3f px, angle %.3f deg, size %.2f%%, slowest %.0f ms\n", worstPosition, worstAngle, worstScale * 100, slowest);
    CHECK(worstPosition < 0.1, "position error %f px", worstPosition);
    CHECK(worstAngle < 0.05, "angle error %f degrees", worstAngle);
    CHECK(worstScale < 0.002, "size error %f", worstScale);

    // Separate scores, and what surface features can't do on this part.
    ToolOutput clean = engine.run("pattern", withNoise(placed(bracket, 25, 1, cv::Point2f(960, 720))), edges);
    CHECK(measure(clean, "coverage") > 0.95, "coverage %f", measure(clean, "coverage"));
    CHECK(measure(clean, "fit") > 0.8, "fit %f", measure(clean, "fit"));
    CHECK(measure(clean, "clutter") < 0.05, "clutter %f", measure(clean, "clutter"));
    CHECK(clean.overlays.size() == 1, "one outline: %zu", clean.overlays.size());

    // Lighting. Dim, uneven, and reversed, where a brightness comparison can't work at all.
    cv::Point2f middle(960, 720);
    cv::Mat scene = withNoise(placed(bracket, 25, 1, middle));
    CHECK(measure(engine.run("pattern", scene * 0.3, edges), "count") == 1, "dim");
    cv::Mat reversed = cv::Scalar::all(255) - scene;
    ToolOutput flipped = engine.run("pattern", reversed, edges);
    CHECK(measure(flipped, "count") == 1 && std::hypot(measure(flipped, "x") - 960, measure(flipped, "y") - 720) < 0.1, "reversed contrast: count %f", measure(flipped, "count"));
    ToolInput sameContrast = edges;
    sameContrast.numbers["anyPolarity"] = 0;
    CHECK(measure(engine.run("pattern", scene, sameContrast), "count") == 1, "same contrast still works with reversal off");
    CHECK(measure(engine.run("pattern", reversed, sameContrast), "count") == 0, "reversal turned off must reject reversed contrast");

    // Partly hidden: found, with less coverage, and still in the right place.
    cv::Mat hidden = placed(bracket, 0, 1, middle);
    cv::rectangle(hidden, cv::Rect(960 - 210, 720 - 150, 90, 300), cv::Scalar(120, 140, 160), cv::FILLED);
    ToolInput lenient = edges;
    lenient.numbers["minScore"] = 0.55;
    ToolOutput covered = engine.run("pattern", withNoise(hidden), lenient);
    CHECK(measure(covered, "count") == 1, "partly hidden: count %f, score %f", measure(covered, "count"), measure(covered, "score"));
    CHECK(measure(covered, "coverage") < 0.95, "something on top of the part should cost coverage: %f", measure(covered, "coverage"));
    CHECK(std::hypot(measure(covered, "x") - 960, measure(covered, "y") - 720) < 0.2, "partly hidden, at %f,%f", measure(covered, "x"), measure(covered, "y"));

    // Busy background, with the part present.
    cv::Mat inBusy = busyScene(3);
    cv::Mat pose = cv::getRotationMatrix2D(cv::Point2f((bracket.cols - 1) / 2.f, (bracket.rows - 1) / 2.f), 40, 1);
    pose.at<double>(0, 2) += 960 - (bracket.cols - 1) / 2.0;
    pose.at<double>(1, 2) += 720 - (bracket.rows - 1) / 2.0;
    cv::warpAffine(bracket, inBusy, pose, inBusy.size(), cv::INTER_CUBIC, cv::BORDER_TRANSPARENT);
    ToolOutput busyFound = engine.run("pattern", withNoise(inBusy), edges);
    CHECK(measure(busyFound, "count") == 1 && std::hypot(measure(busyFound, "x") - 960, measure(busyFound, "y") - 720) < 0.2, "in a busy scene: count %f at %f,%f", measure(busyFound, "count"), measure(busyFound, "x"), measure(busyFound, "y"));

    // What must not be found. These caught the first version, whose score counted any edge lying near a point.
    cv::RNG noiseSource(1);
    for (double sigma : {14.0, 40.0}) {
        cv::Mat noise(1440, 1920, CV_8UC3);
        noiseSource.fill(noise, cv::RNG::NORMAL, cv::Scalar::all(128), cv::Scalar::all(sigma));
        CHECK(measure(engine.run("pattern", noise, edges), "count") == 0, "found the part in noise, sigma %f", sigma);
    }
    CHECK(measure(engine.run("pattern", cv::Mat(1440, 1920, CV_8UC3, cv::Scalar::all(180)), edges), "count") == 0, "found the part in a blank image");
    for (int seed : {5, 6, 7, 8}) {
        ToolOutput busy = engine.run("pattern", busyScene(seed, seed % 2 == 0 ? 1200 : 300), edges);
        CHECK(measure(busy, "count") == 0, "found the bracket in busy scene %d, score %f", seed, measure(busy, "score"));
    }
    CHECK(measure(engine.run("pattern", withNoise(placed(gasket, 30, 1, middle)), edges), "count") == 0, "a gasket isn't a bracket");
    ToolInput gasketEdges = edges;
    gasketEdges.templ = gasket;
    CHECK(measure(engine.run("pattern", withNoise(placed(bracket, 30, 1, middle)), gasketEdges), "count") == 0, "a bracket isn't a gasket");
    cv::Mat mirrored;
    cv::flip(bracket, mirrored, 1);
    ToolInput strict = edges;
    strict.numbers["minScore"] = 0.75;
    CHECK(measure(engine.run("pattern", withNoise(placed(mirrored, 30, 1, middle)), strict), "count") == 0, "a mirror image isn't the part");

    // Sizes and angles outside what was asked for.
    CHECK(measure(engine.run("pattern", withNoise(placed(bracket, 30, 2, middle)), edges), "count") == 0, "twice the size, with a limit of 1.4");
    ToolInput larger = edges;
    larger.numbers["scaleMax"] = 2.2;
    ToolOutput doubled = engine.run("pattern", withNoise(placed(bracket, 30, 2, middle)), larger);
    CHECK(measure(doubled, "count") == 1 && std::abs(measure(doubled, "scale") - 2) < 0.02, "twice the size, allowed: count %f, scale %f", measure(doubled, "count"), measure(doubled, "scale"));
    ToolInput narrow = edges;
    narrow.numbers["angleRange"] = 15;
    CHECK(measure(engine.run("pattern", withNoise(placed(bracket, 10, 1, middle)), narrow), "count") == 1, "10 degrees, within 15");
    CHECK(measure(engine.run("pattern", withNoise(placed(bracket, 90, 1, middle)), narrow), "count") == 0, "90 degrees, outside 15");

    // Several parts, and a region. Each gets its own position.
    cv::Mat several(1440, 1920, CV_8UC3, cv::Scalar::all(205));
    for (auto [degrees, center] : std::vector<std::pair<double, cv::Point2f>>{{20, {500, 350}}, {-70, {1400, 400}}, {150, {950, 1100}}}) {
        cv::Mat turn = cv::getRotationMatrix2D(cv::Point2f((bracket.cols - 1) / 2.f, (bracket.rows - 1) / 2.f), degrees, 0.8);
        turn.at<double>(0, 2) += center.x - (bracket.cols - 1) / 2.0;
        turn.at<double>(1, 2) += center.y - (bracket.rows - 1) / 2.0;
        cv::warpAffine(bracket, several, turn, several.size(), cv::INTER_CUBIC, cv::BORDER_TRANSPARENT);
    }
    ToolInput many = edges;
    many.numbers["maxInstances"] = 5;
    ToolOutput three = engine.run("pattern", withNoise(several), many);
    CHECK(measure(three, "count") == 3, "three parts: found %f", measure(three, "count"));
    ToolInput region = edges;
    region.roi = cv::Rect(1100, 100, 700, 600);
    ToolOutput inRegion = engine.run("pattern", withNoise(several), region);
    CHECK(measure(inRegion, "count") == 1 && std::hypot(measure(inRegion, "x") - 1400, measure(inRegion, "y") - 400) < 0.2, "the part in the region: count %f at %f,%f", measure(inRegion, "count"), measure(inRegion, "x"), measure(inRegion, "y"));

    // A slight tilt is followed, and the limit of that is stated in the README.
    for (double tilt : {5.0, 10.0}) {
        ToolOutput tilted = engine.run("pattern", withNoise(partTilted(bracket, tilt, 20, 1)), edges);
        CHECK(measure(tilted, "count") == 1, "tilt %.0f: count %f, score %f", tilt, measure(tilted, "count"), measure(tilted, "score"));
    }

    // A pattern with no edges has to say so, and a newly taught one can't reuse the old model.
    ToolInput blank = edges;
    blank.templ = cv::Mat(200, 200, CV_8UC3, cv::Scalar::all(128));
    ToolOutput noEdges = engine.run("pattern", scene, blank);
    CHECK(noEdges.error.find("edges") != std::string::npos, "%s", noEdges.error.c_str());
    CHECK(measure(engine.run("pattern", scene, gasketEdges), "count") == 0, "a gasket pattern, taught after a bracket one");
    CHECK(measure(engine.run("pattern", scene, edges), "count") == 1, "the bracket pattern again");
}

// True sub-pixel shapes: polygons drawn 8 times oversized, with vertices to 1/256 of a pixel, then reduced.
static cv::Mat renderShapes(const std::vector<std::pair<std::vector<cv::Point2d>, int>>& shapes, double noise = 3) {
    cv::Size size(1000, 800);
    cv::Mat big(size.height * 8, size.width * 8, CV_8UC1, cv::Scalar(220));
    for (const auto& [polygon, shade] : shapes) {
        std::vector<std::vector<cv::Point>> points(1);
        for (const auto& p : polygon) {
            points[0].emplace_back(int(std::lround((p.x + 0.5) * 2048)), int(std::lround((p.y + 0.5) * 2048)));
        }
        cv::fillPoly(big, points, cv::Scalar(shade), cv::LINE_8, 8);
    }
    cv::Mat gray;
    cv::resize(big, gray, size, 0, 0, cv::INTER_AREA);
    cv::GaussianBlur(gray, gray, cv::Size(0, 0), 0.7);
    cv::Mat speckle(size, CV_8UC1);
    cv::randn(speckle, 0, noise);
    cv::Mat frame;
    cv::cvtColor(gray + speckle, frame, cv::COLOR_GRAY2BGR);
    return frame;
}

static std::vector<cv::Point2d> circleShape(cv::Point2d center, double radius) {
    std::vector<cv::Point2d> polygon;
    for (int i = 0; i < 2000; i++) {
        double t = i * 2 * CV_PI / 2000;
        polygon.emplace_back(center.x + radius * std::cos(t), center.y + radius * std::sin(t));
    }
    return polygon;
}

static std::vector<cv::Point2d> rectangleShape(cv::Point2d center, double length, double width, double degrees) {
    double t = -degrees * CV_PI / 180;
    cv::Point2d along(std::cos(t), std::sin(t)), across(-along.y, along.x);
    return {center - along * (length / 2) - across * (width / 2), center + along * (length / 2) - across * (width / 2),
            center + along * (length / 2) + across * (width / 2), center - along * (length / 2) + across * (width / 2)};
}

static std::vector<cv::Point2d> ellipseShape(cv::Point2d center, double a, double b, double degrees) {
    double t0 = -degrees * CV_PI / 180;
    std::vector<cv::Point2d> polygon;
    for (int i = 0; i < 2000; i++) {
        double t = i * 2 * CV_PI / 2000, x = a * std::cos(t), y = b * std::sin(t);
        polygon.emplace_back(center.x + x * std::cos(t0) - y * std::sin(t0), center.y + x * std::sin(t0) + y * std::cos(t0));
    }
    return polygon;
}

static void testContours(Engine& engine) {
    // Known sizes. These are best-case images, so the limits are for catching a regression.
    cv::Point2d center(500.3, 400.2);
    for (double radius : {60.0, 100.0, 250.0}) {
        ToolOutput out = engine.run("contours", renderShapes({{circleShape(center, radius), 50}}), {});
        CHECK(out.error.empty(), "%s", out.error.c_str());
        CHECK(measure(out, "count") == 1 && measure(out, "closed") == 1 && measure(out, "open") == 0, "a circle: count %f", measure(out, "count"));
        CHECK(std::abs(measure(out, "largest_area") / (CV_PI * radius * radius) - 1) < 0.003, "r %.0f: area %f", radius, measure(out, "largest_area"));
        CHECK(std::abs(measure(out, "perimeter") / (2 * CV_PI * radius) - 1) < 0.004, "r %.0f: perimeter %f", radius, measure(out, "perimeter"));
        CHECK(std::hypot(measure(out, "x") - center.x, measure(out, "y") - center.y) < 0.2, "r %.0f: center %f,%f", radius, measure(out, "x"), measure(out, "y"));
        CHECK(measure(out, "circularity") > 0.98, "r %.0f: circularity %f", radius, measure(out, "circularity"));
        CHECK(measure(out, "convexity") > 0.99, "r %.0f: convexity %f", radius, measure(out, "convexity"));
    }
    ToolOutput square = engine.run("contours", renderShapes({{rectangleShape(center, 300, 300, 17), 50}}), {});
    CHECK(std::abs(measure(square, "largest_area") / 90000 - 1) < 0.002, "a square's area: %f", measure(square, "largest_area"));
    CHECK(std::abs(measure(square, "perimeter") / 1200 - 1) < 0.01, "a square's perimeter: %f", measure(square, "perimeter"));
    CHECK(measure(square, "corners") == 4, "a square's corners: %f", measure(square, "corners"));
    CHECK(std::abs(measure(square, "circularity") - CV_PI / 4) < 0.02, "a square's circularity: %f", measure(square, "circularity"));

    // A sharp edge falling exactly between two pixels, with no blur at all. Its strength has a flat top, which used to
    // read as a crest at the far end, half a pixel too large all round.
    cv::Mat sharp(600, 800, CV_8UC3, cv::Scalar::all(225));
    cv::rectangle(sharp, cv::Rect(100, 100, 400, 300), cv::Scalar::all(50), cv::FILLED);
    ToolOutput aligned = engine.run("contours", sharp, {});
    CHECK(std::abs(measure(aligned, "largest_area") / 120000 - 1) < 0.001, "a pixel-aligned rectangle's area: %f", measure(aligned, "largest_area"));
    ToolInput boxFit;
    boxFit.numbers = {{"shape", 3}};
    ToolOutput alignedBox = engine.run("shapefit", sharp, boxFit);
    CHECK(std::abs(measure(alignedBox, "length") - 400) < 0.1 && std::abs(measure(alignedBox, "width") - 300) < 0.1, "a pixel-aligned rectangle: %f x %f", measure(alignedBox, "length"), measure(alignedBox, "width"));

    // Tracing whole pixels alone would be half a pixel small all round. This is what the refinement is for.
    ToolInput unsmoothed;
    unsmoothed.numbers = {{"smoothContour", 0}};
    ToolOutput rough = engine.run("contours", renderShapes({{circleShape(center, 100), 50}}), unsmoothed);
    CHECK(std::abs(measure(rough, "largest_area") / (CV_PI * 10000) - 1) < 0.003, "refined area without smoothing: %f", measure(rough, "largest_area"));
    cv::Mat noisy = renderShapes({{circleShape(center, 100), 50}}, 12);
    double smoothedLength = measure(engine.run("contours", noisy, {}), "perimeter");
    double roughLength = measure(engine.run("contours", noisy, unsmoothed), "perimeter");
    CHECK(roughLength > smoothedLength, "smoothing should shorten a noisy outline: %f, against %f", roughLength, smoothedLength);
    CHECK(std::abs(smoothedLength / (2 * CV_PI * 100) - 1) < 0.01, "a smoothed perimeter on a noisy image: %f", smoothedLength);

    // Holes, the filters, and what each method can tell.
    cv::Mat plate = renderShapes({{rectangleShape({350, 300}, 500, 400, 0), 50}, {circleShape({250, 250}, 60), 220}, {circleShape({450, 350}, 40), 220}, {circleShape({800, 300}, 50), 50}});
    ToolOutput all = engine.run("contours", plate, {});
    CHECK(measure(all, "count") == 4 && measure(all, "holes") == 2, "a plate with two holes and a disc: count %f, holes %f", measure(all, "count"), measure(all, "holes"));
    CHECK(std::abs(measure(all, "largest_area") / 200000 - 1) < 0.002, "the largest area ignores holes: %f", measure(all, "largest_area"));
    CHECK(all.overlays.size() == 4, "one outline each: %zu", all.overlays.size());
    ToolInput outer;
    outer.numbers = {{"includeHoles", 0}};
    CHECK(measure(engine.run("contours", plate, outer), "count") == 2, "outer outlines only");
    ToolInput smallOnly;
    smallOnly.numbers = {{"maxArea", 20000}, {"includeHoles", 0}};
    CHECK(measure(engine.run("contours", plate, smallOnly), "count") == 1, "the area filter");
    ToolInput longOnly;
    longOnly.numbers = {{"minLength", 1000}};
    CHECK(measure(engine.run("contours", plate, longOnly), "count") == 1, "the length filter");
    ToolInput region;
    region.roi = cv::Rect(700, 200, 200, 200);
    ToolOutput inRegion = engine.run("contours", plate, region);
    CHECK(measure(inRegion, "count") == 1 && std::hypot(measure(inRegion, "x") - 800, measure(inRegion, "y") - 300) < 0.2, "the disc in a region: %f at %f,%f", measure(inRegion, "count"), measure(inRegion, "x"), measure(inRegion, "y"));
    ToolInput bright;
    bright.numbers = {{"polarity", 1}, {"includeHoles", 0}, {"dropBorder", 0}};
    CHECK(measure(engine.run("contours", cv::Scalar::all(255) - plate, bright), "count") == 2, "bright objects on dark");
    ToolInput calibrated;
    calibrated.mmPerPixel = 0.05;
    ToolOutput inMM = engine.run("contours", renderShapes({{circleShape(center, 100), 50}}), calibrated);
    CHECK(std::abs(measure(inMM, "largest_area") / (CV_PI * 25) - 1) < 0.003, "area in mm²: %f", measure(inMM, "largest_area"));

    // Edges give open outlines. findContours alone would return this as a closed loop, traced there and back.
    std::vector<cv::Point2d> runsOff{{-20, 300}, {500, 200}, {1100, 350}, {1100, 900}, {-20, 900}};
    cv::Mat offFrame = renderShapes({{runsOff, 50}});
    ToolInput edges;
    edges.numbers = {{"method", 3}, {"dropBorder", 0}};
    ToolOutput openEdge = engine.run("contours", offFrame, edges);
    CHECK(measure(openEdge, "count") == 1 && measure(openEdge, "open") == 1 && measure(openEdge, "closed") == 0, "a shape running out of view: count %f, open %f", measure(openEdge, "count"), measure(openEdge, "open"));
    CHECK(std::abs(measure(openEdge, "longest") - 1024) < 10, "its length: %f", measure(openEdge, "longest"));
    CHECK(openEdge.overlays.size() == 1 && !openEdge.overlays[0].closed, "an open outline is drawn open");
    CHECK(std::isnan(measure(openEdge, "holes")), "edges can't tell holes, so shouldn't claim a count");
    ToolInput noBorder = edges;
    noBorder.numbers["dropBorder"] = 1;
    CHECK(measure(engine.run("contours", offFrame, noBorder), "count") == 0, "an outline touching the edge can be ignored");
    ToolInput closedOnly = edges;
    closedOnly.numbers["keep"] = 1;
    CHECK(measure(engine.run("contours", offFrame, closedOnly), "count") == 0, "closed only");
    ToolOutput edgeCircle = engine.run("contours", renderShapes({{circleShape(center, 100), 50}}), edges);
    CHECK(measure(edgeCircle, "closed") == 1 && std::abs(measure(edgeCircle, "largest_area") / (CV_PI * 10000) - 1) < 0.003, "edges close a circle too: closed %f, area %f", measure(edgeCircle, "closed"), measure(edgeCircle, "largest_area"));

    // Nothing there.
    cv::Mat blank(800, 1000, CV_8UC3, cv::Scalar::all(128));
    ToolOutput none = engine.run("contours", blank, {});
    CHECK(none.error.empty() && measure(none, "count") == 0, "a blank image: %f", measure(none, "count"));
    CHECK(std::isnan(measure(none, "largest_area")), "no outlines, no area");
}

static void testShapeFit(Engine& engine) {
    auto fit = [&](const std::vector<std::pair<std::vector<cv::Point2d>, int>>& shapes, double shape) {
        ToolInput input;
        input.numbers = {{"shape", shape}};
        return engine.run("shapefit", renderShapes(shapes), input);
    };

    // Known sizes. The limits allow for a constant bias of about 0.1 px from how the test draws its shapes.
    cv::RNG random(7);
    for (int i = 0; i < 8; i++) {
        double radius = random.uniform(40.0, 300.0);
        cv::Point2d center(500 + random.uniform(-40.0, 40.0), 400 + random.uniform(-40.0, 40.0));
        ToolOutput out = fit({{circleShape(center, radius), 50}}, 1);
        CHECK(measure(out, "found") == 1, "circle %d not found", i);
        CHECK(std::abs(measure(out, "diameter") - 2 * radius) < 0.25, "circle %d: diameter %f, true %f", i, measure(out, "diameter"), 2 * radius);
        CHECK(std::hypot(measure(out, "x") - center.x, measure(out, "y") - center.y) < 0.2, "circle %d: center %f,%f", i, measure(out, "x"), measure(out, "y"));
        CHECK(measure(out, "arc_coverage") > 0.95, "a whole circle's arc coverage: %f", measure(out, "arc_coverage"));

        double length = random.uniform(200.0, 500.0), width = random.uniform(80.0, 190.0), degrees = random.uniform(-80.0, 80.0);
        ToolOutput box = fit({{rectangleShape(center, length, width, degrees), 50}}, 3);
        CHECK(measure(box, "found") == 1, "rectangle %d not found", i);
        CHECK(std::abs(measure(box, "length") - length) < 0.3 && std::abs(measure(box, "width") - width) < 0.3, "rectangle %d: %f x %f, true %f x %f", i, measure(box, "length"), measure(box, "width"), length, width);
        CHECK(angleDifference(measure(box, "angle"), degrees) < 0.05 || angleDifference(measure(box, "angle"), degrees + 180) < 0.05, "rectangle %d: angle %f, true %f", i, measure(box, "angle"), degrees);

        double a = random.uniform(120.0, 300.0), b = random.uniform(60.0, 110.0);
        ToolOutput oval = fit({{ellipseShape(center, a, b, degrees), 50}}, 2);
        CHECK(measure(oval, "found") == 1, "ellipse %d not found", i);
        CHECK(std::abs(measure(oval, "major_axis") - 2 * a) < 0.3 && std::abs(measure(oval, "minor_axis") - 2 * b) < 0.3, "ellipse %d: %f x %f, true %f x %f", i, measure(oval, "major_axis"), measure(oval, "minor_axis"), 2 * a, 2 * b);
        CHECK(angleDifference(measure(oval, "angle"), degrees) < 0.2 || angleDifference(measure(oval, "angle"), degrees + 180) < 0.2, "ellipse %d: angle %f, true %f", i, measure(oval, "angle"), degrees);

        cv::Point2d along(std::cos(-degrees * CV_PI / 180), std::sin(-degrees * CV_PI / 180)), across(-along.y, along.x);
        ToolOutput line = fit({{{center - along * 2000, center + along * 2000, center + along * 2000 + across * 2000, center - along * 2000 + across * 2000}, 50}}, 0);
        CHECK(measure(line, "found") == 1, "line %d not found", i);
        CHECK(angleDifference(measure(line, "angle"), degrees) < 0.05 || angleDifference(measure(line, "angle"), degrees + 180) < 0.05, "line %d: angle %f, true %f", i, measure(line, "angle"), degrees);
    }

    // A half circle, and everything else in view: the burr and other shapes have no say in the size.
    ToolOutput half = fit({{[] { std::vector<cv::Point2d> sector{{500, 400}}; for (int i = 0; i <= 400; i++) { double t = i * CV_PI / 400; sector.emplace_back(500 + 200 * std::cos(t), 400 + 200 * std::sin(t)); } return sector; }(), 50}}, 1);
    CHECK(measure(half, "found") == 1 && std::abs(measure(half, "diameter") - 400) < 0.3, "a half circle: found %f, diameter %f", measure(half, "found"), measure(half, "diameter"));
    CHECK(measure(half, "arc_coverage") < 0.6, "a half circle's arc coverage: %f", measure(half, "arc_coverage"));
    ToolOutput busy = fit({{circleShape({500, 400}, 150), 50}, {rectangleShape({628, 392}, 60, 14, 0), 50}, {circleShape({150, 150}, 40), 50}, {{{100, 700}, {900, 720}, {900, 725}, {100, 705}}, 50}}, 1);
    CHECK(std::abs(measure(busy, "diameter") - 300) < 0.25, "a circle among other things: %f", measure(busy, "diameter"));
    CHECK(measure(busy, "share_used") < 0.6, "the share used should show there's more in view: %f", measure(busy, "share_used"));
    ToolInput region;
    region.numbers = {{"shape", 1}};
    region.roi = cv::Rect(90, 90, 120, 120);
    ToolOutput smallOne = engine.run("shapefit", renderShapes({{circleShape({500, 400}, 150), 50}, {circleShape({150, 150}, 40), 50}}), region);
    CHECK(std::abs(measure(smallOne, "diameter") - 80) < 0.25 && std::hypot(measure(smallOne, "x") - 150, measure(smallOne, "y") - 150) < 0.2, "a region picks the small circle: %f at %f,%f", measure(smallOne, "diameter"), measure(smallOne, "x"), measure(smallOne, "y"));

    // A straight edge isn't a circle of enormous radius, which is where the fit used to run away to.
    std::vector<cv::Point2d> halfPlane{{-100, 300}, {1100, 320}, {1100, 900}, {-100, 900}};
    ToolOutput straight = fit({{halfPlane, 50}}, 1);
    CHECK(measure(straight, "found") == 0 || measure(straight, "diameter") < 3000, "a straight edge as a circle: diameter %f", measure(straight, "diameter"));

    // A long edge among a lot of fine texture, as with a card on wood grain. With few of the points on the line, sampling
    // from the whole pool could miss it altogether, and the answer jumped from one frame's noise to the next.
    cv::Mat grain(800, 1000, CV_8UC1, cv::Scalar(170));
    cv::RNG grainSource(9);
    for (int i = 0; i < 2500; i++) {
        cv::Point start(grainSource.uniform(0, 1000), grainSource.uniform(0, 800));
        int length = grainSource.uniform(20, 90), rise = grainSource.uniform(-4, 5);
        cv::line(grain, start, start + cv::Point(length, rise), cv::Scalar(grainSource.uniform(110, 235)), 1, cv::LINE_AA);
    }
    std::vector<cv::Point> sheet{{100, 300}, {900, 180}, {900, 800}, {100, 800}};
    cv::fillPoly(grain, std::vector<std::vector<cv::Point>>{sheet}, cv::Scalar(240), cv::LINE_AA);
    ToolInput grainInput;
    grainInput.numbers = {{"shape", 0}, {"tolerance", 1.5}};
    grainInput.roi = cv::Rect(200, 180, 600, 130);
    double trueAngle = std::atan2(120.0, 800.0) * 180 / CV_PI, lowest = 1e9, highest = -1e9;
    cv::RNG speckleSource(3);
    for (int i = 0; i < 12; i++) {
        cv::Mat speckle(grain.size(), CV_8UC1);
        speckleSource.fill(speckle, cv::RNG::NORMAL, 0, 3);
        cv::Mat frame;
        cv::cvtColor(grain + speckle, frame, cv::COLOR_GRAY2BGR);
        ToolOutput seen = engine.run("shapefit", frame, grainInput);
        CHECK(measure(seen, "found") == 1 && std::abs(measure(seen, "angle") - trueAngle) < 0.3, "frame %d, a long edge on texture: found %f, angle %f, true %f", i, measure(seen, "found"), measure(seen, "angle"), trueAngle);
        lowest = std::min(lowest, measure(seen, "y"));
        highest = std::max(highest, measure(seen, "y"));
    }
    CHECK(highest - lowest < 5, "a long edge on texture should stay put: y ranges over %f", highest - lowest);

    // That texture has no circle in it, though short edges crossing a large imaginary one used to be enough.
    cv::Mat textureOnly;
    cv::cvtColor(grain, textureOnly, cv::COLOR_GRAY2BGR);
    ToolInput grainCircle;
    grainCircle.numbers = {{"shape", 1}};
    grainCircle.roi = cv::Rect(0, 0, 1000, 170);
    ToolOutput falseCircle = engine.run("shapefit", textureOnly, grainCircle);
    CHECK(measure(falseCircle, "found") == 0, "a circle in texture: diameter %f, share %f", measure(falseCircle, "diameter"), measure(falseCircle, "share_used"));

    // The wrong shape. Any closed outline can be given an ellipse or a bounding rectangle, so these must not count.
    ToolInput ovalFit, boxFit;
    ovalFit.numbers = {{"shape", 2}};
    boxFit.numbers = {{"shape", 3}};
    cv::Mat star = renderShapes({{{{500, 150}, {560, 350}, {760, 400}, {560, 450}, {500, 650}, {440, 450}, {240, 400}, {440, 350}}, 50}});
    ToolOutput starOval = engine.run("shapefit", star, ovalFit);
    CHECK(measure(starOval, "found") == 0, "a star isn't an ellipse: rms %f", measure(starOval, "rms_error"));
    CHECK(measure(engine.run("shapefit", star, boxFit), "found") == 0, "a star isn't a rectangle");
    CHECK(measure(engine.run("shapefit", renderShapes({{circleShape({500, 400}, 200), 50}}), boxFit), "found") == 0, "a circle isn't a rectangle");

    // Nothing there. Noise used to find a shape, since some points always agree by chance.
    ToolInput circleInput, lineInput;
    circleInput.numbers = {{"shape", 1}};
    lineInput.numbers = {{"shape", 0}};
    cv::Mat blank(800, 1000, CV_8UC3, cv::Scalar::all(128));
    CHECK(measure(engine.run("shapefit", blank, circleInput), "found") == 0, "a circle in a blank image");
    CHECK(measure(engine.run("shapefit", blank, lineInput), "found") == 0, "a line in a blank image");
    cv::RNG noiseSource(1);
    for (double sigma : {14.0, 40.0}) {
        cv::Mat noise(800, 1000, CV_8UC3);
        noiseSource.fill(noise, cv::RNG::NORMAL, cv::Scalar::all(128), cv::Scalar::all(sigma));
        CHECK(measure(engine.run("shapefit", noise, circleInput), "found") == 0, "a circle in noise, sigma %f: diameter %f", sigma, measure(engine.run("shapefit", noise, circleInput), "diameter"));
        CHECK(measure(engine.run("shapefit", noise, lineInput), "found") == 0, "a line in noise, sigma %f", sigma);
    }
    ToolInput oval;
    oval.numbers = {{"shape", 2}};
    CHECK(measure(engine.run("shapefit", blank, oval), "found") == 0, "an ellipse in a blank image");
    ToolInput calibrated;
    calibrated.mmPerPixel = 0.05;
    calibrated.numbers = {{"shape", 1}};
    ToolOutput inMM = engine.run("shapefit", renderShapes({{circleShape({500, 400}, 100), 50}}), calibrated);
    CHECK(std::abs(measure(inMM, "diameter") - 10) < 0.02, "diameter in mm: %f", measure(inMM, "diameter"));
}

static cv::Scalar rgb(int r, int g, int b) { return cv::Scalar(b, g, r); }

static ColorReference taught(const cv::Mat& image, cv::Rect region, const std::string& name) {
    ToolInput input;
    ColorReference color = trainColor(image, region, input);
    color.name = name;
    return color;
}

static void testColorTools(Engine& engine) {
    // Documented HSI: hue the angle on the wheel, scaled to 0 through 255; saturation 0 is grey; intensity the mean of R, G, B.
    struct Known { float r, g, b, h, s, i; };
    for (const Known& k : {Known{255, 0, 0, 0, 255, 85}, Known{0, 255, 0, 85.33f, 255, 85}, Known{0, 0, 255, 170.67f, 255, 85},
                           Known{255, 255, 0, 42.67f, 255, 170}, Known{0, 255, 255, 128, 255, 170}, Known{255, 0, 255, 213.33f, 255, 170},
                           Known{128, 128, 128, 0, 0, 128}, Known{0, 0, 0, 0, 0, 0}, Known{255, 255, 255, 0, 0, 255}}) {
        cv::Vec3f hsi = rgbToHsi(k.r, k.g, k.b);
        CHECK(std::abs(hsi[0] - k.h) < 0.05 && std::abs(hsi[1] - k.s) < 0.05 && std::abs(hsi[2] - k.i) < 0.05, "HSI of %.0f,%.0f,%.0f: %.2f,%.2f,%.2f", k.r, k.g, k.b, hsi[0], hsi[1], hsi[2]);
    }

    // Six patches on grey, with known areas, plus noise.
    cv::Mat chart(600, 900, CV_8UC3, cv::Scalar::all(128));
    struct Patch { cv::Rect rect; cv::Scalar color; const char* name; };
    std::vector<Patch> patches{{{50, 50, 200, 200}, rgb(220, 30, 30), "red"}, {{350, 50, 200, 200}, rgb(30, 180, 40), "green"}, {{650, 50, 200, 200}, rgb(40, 60, 210), "blue"},
                               {{50, 350, 200, 200}, rgb(230, 200, 40), "yellow"}, {{350, 350, 100, 200}, rgb(150, 30, 30), "dark red"}, {{650, 350, 200, 200}, rgb(240, 240, 240), "white"}};
    for (const Patch& p : patches) {
        cv::rectangle(chart, p.rect, p.color, cv::FILLED);
    }
    chart = withNoise(chart, 3);
    cv::Rect insideRed(90, 90, 120, 120), insideBlue(690, 90, 120, 120), insideGreen(390, 90, 120, 120), insideYellow(90, 390, 120, 120);
    ColorReference red = taught(chart, insideRed, "red"), blue = taught(chart, insideBlue, "blue"), green = taught(chart, insideGreen, "green");
    CHECK(std::abs(red.meanRGB[0] - 220) < 2 && std::abs(red.meanRGB[1] - 30) < 2 && std::abs(red.meanRGB[2] - 30) < 2, "taught red: %f,%f,%f", red.meanRGB[0], red.meanRGB[1], red.meanRGB[2]);

    // Color Segmenter. HSI, the default.
    ToolInput segment;
    segment.colors = {red};
    ToolOutput segmented = engine.run("colorsegmenter", chart, segment);
    CHECK(segmented.error.empty(), "%s", segmented.error.c_str());
    CHECK(measure(segmented, "count") == 1, "one red patch: %f", measure(segmented, "count"));
    CHECK(std::abs(measure(segmented, "matched_pixels") / 40000 - 1) < 0.02, "its pixels: %f", measure(segmented, "matched_pixels"));
    CHECK(std::hypot(measure(segmented, "x") - 150, measure(segmented, "y") - 150) < 2, "its center: %f,%f", measure(segmented, "x"), measure(segmented, "y"));
    CHECK(std::abs(measure(segmented, "matched_share") - 40000.0 * 100 / (900 * 600)) < 0.3, "its share: %f", measure(segmented, "matched_share"));

    ToolInput rgbSpace = segment;
    rgbSpace.numbers["colorSpace"] = 0;
    CHECK(std::abs(measure(engine.run("colorsegmenter", chart, rgbSpace), "matched_pixels") / 40000 - 1) < 0.02, "the same patch in RGB");

    // Multiple ranges combine by logical OR.
    ToolInput both;
    both.colors = {red, blue};
    ToolOutput orResult = engine.run("colorsegmenter", chart, both);
    CHECK(measure(orResult, "count") == 2 && std::abs(measure(orResult, "matched_pixels") / 80000 - 1) < 0.02, "red OR blue: count %f, pixels %f", measure(orResult, "count"), measure(orResult, "matched_pixels"));

    // Narrow tolerances exclude the dark red, which only differs in intensity, and wider ones take it in.
    ToolInput wide = segment;
    wide.colors[0].lowHSI[2] = -80;
    wide.colors[0].lowHSI[1] = -60;
    CHECK(measure(engine.run("colorsegmenter", chart, wide), "count") == 2, "wider intensity tolerance includes the dark red");

    // Softness: outside the tolerances but inside the band, a graded grey that isn't counted as in range.
    ToolInput soft = segment;
    soft.colors[0].softness = 40;
    CHECK(std::abs(measure(engine.run("colorsegmenter", chart, soft), "matched_pixels") / 40000 - 1) < 0.02, "softness doesn't change what's fully in range");

    // Hue wraps around red: a range centered near 0 has to accept hues just below 256.
    cv::Mat wrap(200, 200, CV_8UC3, cv::Scalar::all(128));
    cv::rectangle(wrap, cv::Rect(20, 20, 70, 160), rgb(220, 40, 60), cv::FILLED);   // red toward magenta, hue about 252
    cv::rectangle(wrap, cv::Rect(110, 20, 70, 160), rgb(220, 60, 40), cv::FILLED);  // red toward orange, hue about 4
    cv::Mat mixed(200, 200, CV_8UC3, rgb(220, 50, 50));
    ColorReference nearRed = taught(mixed, cv::Rect(0, 0, 200, 200), "red");
    ToolInput wrapping;
    wrapping.colors = {nearRed};
    wrapping.colors[0].lowHSI = {-12, -60, -60};
    wrapping.colors[0].highHSI = {12, 60, 60};
    ToolOutput wrapped = engine.run("colorsegmenter", wrap, wrapping);
    CHECK(measure(wrapped, "count") == 2, "both sides of red: %f, nominal hue %f", measure(wrapped, "count"), nearRed.meanHSI[0]);
    cv::Mat twoSides(200, 200, CV_8UC3);
    cv::rectangle(twoSides, cv::Rect(0, 0, 100, 200), rgb(220, 40, 60), cv::FILLED);
    cv::rectangle(twoSides, cv::Rect(100, 0, 100, 200), rgb(220, 60, 40), cv::FILLED);
    double meanOfSides = taught(twoSides, cv::Rect(0, 0, 200, 200), "both").meanHSI[0];
    CHECK(meanOfSides < 6 || meanOfSides > 250, "the mean hue of colors either side of red is red, not cyan: %f", meanOfSides);

    // Greys have no hue to go by.
    cv::Mat greyScene(300, 300, CV_8UC3, cv::Scalar::all(128));
    CHECK(measure(engine.run("colorsegmenter", withNoise(greyScene, 3), segment), "matched_pixels") < 100, "grey isn't red");

    // An ellipse region only looks inside the ellipse.
    ToolInput oval = both;
    oval.numbers["regionShape"] = 1;
    oval.roi = cv::Rect(50, 50, 200, 200);
    ToolOutput inOval = engine.run("colorsegmenter", chart, oval);
    CHECK(std::abs(measure(inOval, "matched_pixels") / (CV_PI * 10000) - 1) < 0.03, "the red inside an ellipse: %f", measure(inOval, "matched_pixels"));
    CHECK(measure(inOval, "matched_share") > 97, "and it's nearly all of it: %f", measure(inOval, "matched_share"));

    ToolOutput noColors = engine.run("colorsegmenter", chart, {});
    CHECK(!noColors.error.empty(), "no colors taught should say so");

    // Color Extractor: RGB volumes, and a count per color.
    ToolInput extract;
    extract.colors = {red, blue};
    ToolOutput extracted = engine.run("colorextractor", chart, extract);
    CHECK(extracted.error.empty(), "%s", extracted.error.c_str());
    CHECK(std::abs(measure(extracted, "matched_pixels") / 80000 - 1) < 0.05, "red and blue pixels: %f", measure(extracted, "matched_pixels"));
    CHECK(measure(extracted, "count") == 2, "two blobs: %f", measure(extracted, "count"));
    ToolInput redOnly;
    redOnly.colors = {taught(chart, cv::Rect(50, 50, 200, 200), "red")};
    ToolOutput onlyRed = engine.run("colorextractor", chart, redOnly);
    CHECK(hasText(onlyRed, "red") && measure(onlyRed, "best_index") == 1, "the best color: %s", joined(onlyRed).c_str());

    // More of one color wins, as In-Sight's documents say.
    ToolInput moreBlue;
    moreBlue.colors = {red, blue};
    moreBlue.roi = cv::Rect(600, 0, 300, 300);
    ToolOutput blueWins = engine.run("colorextractor", chart, moreBlue);
    CHECK(measure(blueWins, "best_index") == 2 && hasText(blueWins, "blue"), "blue is the most in this region: %s", joined(blueWins).c_str());

    // Dilation grows the volume, so a slightly different red starts to count.
    cv::Mat shifted(300, 300, CV_8UC3, rgb(232, 44, 26));
    shifted = withNoise(shifted, 2);
    ToolInput strict;
    strict.colors = {red};
    double before = measure(engine.run("colorextractor", shifted, strict), "matched_pixels");
    ToolInput dilated = strict;
    dilated.colors[0].dilation = 24;
    double after = measure(engine.run("colorextractor", shifted, dilated), "matched_pixels");
    CHECK(before < 90000 * 0.5 && after > 90000 * 0.95, "dilation should take in a nearby red: %f, then %f", before, after);

    // Cognex: raising softness doesn't add counted pixels, unless the threshold comes down from 255.
    ToolInput softExtract = strict;
    softExtract.colors[0].softness = 60;
    double softCount = measure(engine.run("colorextractor", shifted, softExtract), "matched_pixels");
    CHECK(softCount == before, "softness alone shouldn't change the count: %f, against %f", softCount, before);
    ToolInput lowered = softExtract;
    lowered.numbers["softnessThreshold"] = 100;
    CHECK(measure(engine.run("colorextractor", shifted, lowered), "matched_pixels") > 90000 * 0.95, "a lower threshold counts the grey pixels");

    // Matte lines: the same color lit less or more. Highlight: from the color toward white.
    cv::Mat shadow(200, 200, CV_8UC3, rgb(110, 15, 15));
    shadow = withNoise(shadow, 2);
    ToolInput matte = strict;
    CHECK(measure(engine.run("colorextractor", shadow, matte), "matched_pixels") < 40000 * 0.05, "a shadowed red doesn't count at first");
    matte.colors[0].matteLow = 0.6;
    CHECK(measure(engine.run("colorextractor", shadow, matte), "matched_pixels") > 40000 * 0.6, "the low matte line takes it in");
    cv::Mat glare(200, 200, CV_8UC3, rgb(240, 150, 150));
    glare = withNoise(glare, 2);
    ToolInput highlight = strict;
    CHECK(measure(engine.run("colorextractor", glare, highlight), "matched_pixels") < 40000 * 0.05, "a glare on red doesn't count at first");
    highlight.colors[0].highlight = 1;
    CHECK(measure(engine.run("colorextractor", glare, highlight), "matched_pixels") > 40000 * 0.5, "the highlight line takes it in");

    // Color Match: the region's average against the references, in both spaces.
    ToolInput matching;
    matching.colors = {red, green, blue};
    for (double space : {0.0, 1.0}) {
        matching.numbers["colorSpace"] = space;
        struct Case { cv::Rect region; const char* expected; int index; };
        for (const Case& c : {Case{insideRed, "red", 1}, Case{insideGreen, "green", 2}, Case{insideBlue, "blue", 3}}) {
            matching.roi = c.region;
            ToolOutput match = engine.run("colormatch", chart, matching);
            CHECK(hasText(match, c.expected) && measure(match, "best_index") == c.index, "space %.0f: %s", space, joined(match).c_str());
            CHECK(measure(match, "score") > 0.98, "the same color scores high: %f", measure(match, "score"));
            CHECK(measure(match, "margin") > 0.1, "and clearly beats the others: %f", measure(match, "margin"));
        }
    }
    matching.numbers["colorSpace"] = 0;
    matching.roi = insideYellow;
    ToolOutput unknown = engine.run("colormatch", chart, matching);
    CHECK(measure(unknown, "score") < 0.8, "yellow isn't a close match to any of these: %f", measure(unknown, "score"));
    matching.roi = insideRed;
    ToolOutput averages = engine.run("colormatch", chart, matching);
    CHECK(std::abs(measure(averages, "red") - 220) < 2 && std::min(measure(averages, "hue"), 256 - measure(averages, "hue")) < 3, "the averages: red %f, hue %f", measure(averages, "red"), measure(averages, "hue"));

    // Dimmer light. A brown and a dark red that read alike once the brown is dim, which is what happened on a real card:
    // Color Match in RGB called dimmed wood maroon. Ignoring brightness must get these right at any level.
    cv::Mat surfaces(300, 600, CV_8UC3);
    cv::rectangle(surfaces, cv::Rect(0, 0, 300, 300), rgb(192, 138, 75), cv::FILLED);
    cv::rectangle(surfaces, cv::Rect(300, 0, 300, 300), rgb(109, 56, 69), cv::FILLED);
    surfaces = withNoise(surfaces, 3);
    cv::Rect woodArea(50, 50, 200, 200), maroonArea(350, 50, 200, 200);
    std::vector<ColorReference> surfaceColors{taught(surfaces, woodArea, "wood"), taught(surfaces, maroonArea, "maroon")};
    for (double gain : {0.5, 0.7, 1.0, 1.3}) {
        cv::Mat lit = surfaces * gain;
        for (double space : {0.0, 1.0}) {
            ToolInput steady;
            steady.colors = surfaceColors;
            steady.numbers = {{"colorSpace", space}, {"ignoreBrightness", 1}};
            steady.roi = woodArea;
            ToolOutput onWood = engine.run("colormatch", lit, steady);
            CHECK(hasText(onWood, "wood"), "gain %.1f, space %.0f, on wood: %s", gain, space, joined(onWood).c_str());
            steady.roi = maroonArea;
            CHECK(hasText(engine.run("colormatch", lit, steady), "maroon"), "gain %.1f, space %.0f, on maroon", gain, space);
        }
        ToolInput steadyMix;
        steadyMix.colors = surfaceColors;
        steadyMix.numbers = {{"ignoreBrightness", 1}};
        steadyMix.roi = woodArea;
        ToolOutput mixOnWood = engine.run("compositecolor", lit, steadyMix);
        CHECK(hasText(mixOnWood, "wood") && measure(mixOnWood, "score") > 0.8, "gain %.1f, composite: %s, score %f", gain, joined(mixOnWood).c_str(), measure(mixOnWood, "score"));
        ToolInput steadyRange;
        steadyRange.colors = {surfaceColors[0]};
        steadyRange.numbers = {{"ignoreBrightness", 1}};
        double found = measure(engine.run("colorsegmenter", lit, steadyRange), "matched_pixels");
        CHECK(std::abs(found / 90000 - 1) < 0.03, "gain %.1f, segmenter ignoring brightness: %f", gain, found);
    }
    // And what it gives up: a black, grey and white all have the same zero saturation.
    cv::Mat greys(100, 300, CV_8UC3);
    cv::rectangle(greys, cv::Rect(0, 0, 150, 100), cv::Scalar::all(40), cv::FILLED);
    cv::rectangle(greys, cv::Rect(150, 0, 150, 100), cv::Scalar::all(220), cv::FILLED);
    ToolInput darkVersusLight;
    darkVersusLight.colors = {taught(greys, cv::Rect(0, 0, 150, 100), "dark"), taught(greys, cv::Rect(150, 0, 150, 100), "light")};
    darkVersusLight.roi = cv::Rect(150, 0, 150, 100);
    CHECK(hasText(engine.run("colormatch", greys, darkVersusLight), "light"), "with brightness, light grey is light");
    darkVersusLight.numbers = {{"ignoreBrightness", 1}};
    CHECK(measure(engine.run("colormatch", greys, darkVersusLight), "margin") < 0.01, "without it, greys can't be told apart: %f", measure(engine.run("colormatch", greys, darkVersusLight), "margin"));

    // Composite Color Match compares distributions. A fine red-and-blue check averages to the same purple as a flat purple,
    // so Color Match can't tell them apart, and telling them apart is what the composite tool is for.
    cv::Mat check(200, 400, CV_8UC3, cv::Scalar::all(0));
    for (int y = 0; y < 200; y += 10) {
        for (int x = 0; x < 200; x += 10) {
            cv::rectangle(check, cv::Rect(x, y, 10, 10), (x + y) % 20 == 0 ? rgb(220, 30, 30) : rgb(30, 30, 220), cv::FILLED);
        }
    }
    cv::rectangle(check, cv::Rect(200, 0, 200, 200), rgb(125, 30, 125), cv::FILLED);
    check = withNoise(check, 3);
    cv::Rect checkArea(0, 0, 200, 200), flatArea(200, 0, 200, 200);
    ToolInput composite;
    composite.colors = {taught(check, checkArea, "check"), taught(check, flatArea, "flat")};
    composite.roi = checkArea;
    ToolOutput compositeCheck = engine.run("compositecolor", check, composite);
    CHECK(hasText(compositeCheck, "check") && measure(compositeCheck, "score") > 0.95, "composite on the check: %s, score %f", joined(compositeCheck).c_str(), measure(compositeCheck, "score"));
    CHECK(measure(compositeCheck, "margin") > 0.5, "and it's sure: %f", measure(compositeCheck, "margin"));
    composite.roi = flatArea;
    CHECK(hasText(engine.run("compositecolor", check, composite), "flat"), "composite on the flat purple");
    ToolInput plainMatch;
    plainMatch.colors = composite.colors;
    plainMatch.roi = checkArea;
    CHECK(measure(engine.run("colormatch", check, plainMatch), "margin") < 0.02, "Color Match sees the same average in both: %f", measure(engine.run("colormatch", check, plainMatch), "margin"));
}

static void testBadInput(Engine& engine) {
    cv::Mat image(100, 100, CV_8UC3, cv::Scalar::all(128));
    ToolInput outside;
    outside.roi = cv::Rect(500, 500, 50, 50);
    CHECK(!engine.run("blobs", image, outside).error.empty(), "a region outside the image should be an error");
    CHECK(!engine.run("nonsense", image, {}).error.empty(), "an unknown tool should be an error");
    CHECK(!engine.run("quality", cv::Mat(), {}).error.empty(), "an empty image should be an error");
}

int main(int argc, char** argv) {
    if (argc < 3) {
        printf("usage: engine_tests <models dir> <fixtures dir>\n");
        return 2;
    }
    std::string models = argv[1], fixtures = argv[2];
    Engine engine(models);

    testQuality(engine);
    testBlobs(engine);
    testCaliper(engine);
    testPattern(engine, fixtures, argc > 3 ? argv[3] : "");
    testEdgeSearch(engine);
    testContours(engine);
    testShapeFit(engine);
    testColorTools(engine);
    testChessboard();
    testOCR(engine, fixtures);
    testCustomOnnx(engine, models, fixtures);
    testBadInput(engine);

    printf("%d checks, %d failed\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
