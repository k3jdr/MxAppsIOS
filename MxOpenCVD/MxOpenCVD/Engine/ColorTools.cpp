#include "ColorTools.hpp"

#include <opencv2/core/utility.hpp>
#include <opencv2/imgproc.hpp>

#include <algorithm>
#include <cmath>
#include <map>
#include <numeric>
#include <unordered_map>

namespace mxv {

namespace {

const double kHueScale = 256.0 / (2 * CV_PI);

// Mean of angles on the 0-to-256 hue circle. A plain mean of hues either side of red would come out as cyan.
double meanHue(double sumSin, double sumCos) {
    if (std::abs(sumSin) < 1e-9 && std::abs(sumCos) < 1e-9) {
        return 0;
    }
    double angle = std::atan2(sumSin, sumCos);
    if (angle < 0) {
        angle += 2 * CV_PI;
    }
    return angle * kHueScale;
}

struct RegionStats {
    std::array<double, 3> meanRGB{}, meanHSI{}, spreadRGB{}, spreadHSI{};
    double pixels = 0;
};

RegionStats statsOf(const cv::Mat& crop, const cv::Mat& mask) {
    RegionStats stats;
    double sumRGB[3] = {0, 0, 0}, squareRGB[3] = {0, 0, 0};
    double sumS = 0, sumI = 0, squareS = 0, squareI = 0, sumSin = 0, sumCos = 0, weight = 0;
    for (int y = 0; y < crop.rows; y++) {
        const cv::Vec3b* row = crop.ptr<cv::Vec3b>(y);
        const uchar* allowed = mask.empty() ? nullptr : mask.ptr<uchar>(y);
        for (int x = 0; x < crop.cols; x++) {
            if (allowed && !allowed[x]) {
                continue;
            }
            float r = row[x][2], g = row[x][1], b = row[x][0];
            cv::Vec3f hsi = rgbToHsi(r, g, b);
            sumRGB[0] += r;
            sumRGB[1] += g;
            sumRGB[2] += b;
            squareRGB[0] += double(r) * r;
            squareRGB[1] += double(g) * g;
            squareRGB[2] += double(b) * b;
            sumS += hsi[1];
            sumI += hsi[2];
            squareS += double(hsi[1]) * hsi[1];
            squareI += double(hsi[2]) * hsi[2];
            // Weighted by saturation, because the hue of a nearly grey pixel is mostly noise.
            double angle = hsi[0] / kHueScale;
            sumSin += std::sin(angle) * hsi[1];
            sumCos += std::cos(angle) * hsi[1];
            weight += hsi[1];
            stats.pixels += 1;
        }
    }
    if (stats.pixels <= 0) {
        return stats;
    }
    double n = stats.pixels;
    double spreadOf[3];
    for (int k = 0; k < 3; k++) {
        stats.meanRGB[size_t(k)] = sumRGB[k] / n;
        spreadOf[k] = std::sqrt(std::max(0.0, squareRGB[k] / n - stats.meanRGB[size_t(k)] * stats.meanRGB[size_t(k)]));
        stats.spreadRGB[size_t(k)] = spreadOf[k];
    }
    stats.meanHSI[0] = meanHue(sumSin, sumCos);
    stats.meanHSI[1] = sumS / n;
    stats.meanHSI[2] = sumI / n;
    stats.spreadHSI[1] = std::sqrt(std::max(0.0, squareS / n - stats.meanHSI[1] * stats.meanHSI[1]));
    stats.spreadHSI[2] = std::sqrt(std::max(0.0, squareI / n - stats.meanHSI[2] * stats.meanHSI[2]));
    // The circular spread: 0 when every hue agrees, and growing as they scatter.
    double resultant = weight > 0 ? std::hypot(sumSin, sumCos) / weight : 1;
    stats.spreadHSI[0] = std::sqrt(std::max(0.0, -2 * std::log(std::max(1e-6, resultant)))) * kHueScale;
    return stats;
}

// How far around the hue circle, from a to b, signed and the short way.
inline float hueOffset(float a, float b) {
    float d = a - b;
    if (d > 128) {
        d -= 256;
    } else if (d < -128) {
        d += 256;
    }
    return d;
}

inline float planeMembership(float offset, float low, float high, float softness) {
    if (offset >= low && offset <= high) {
        return 1;
    }
    if (softness <= 0) {
        return 0;
    }
    float beyond = offset < low ? low - offset : offset - high;
    return beyond >= softness ? 0.f : 1.f - beyond / softness;
}

// Blobs in a grey result image, as a Blob tool would find them. Cognex passes the segmented image to its Blob tool. This
// app doesn't chain tools, so the color tools report their own.
void reportBlobs(const cv::Mat& grey, cv::Rect roi, int threshold, const ToolInput& input, const std::string& label, ToolOutput& out) {
    cv::Mat counted = grey >= threshold;
    double minArea = input.number("minArea", 50);
    double mm = input.mmPerPixel;
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(counted, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
    int count = 0;
    double largestArea = 0, largestX = 0, largestY = 0;
    for (const auto& contour : contours) {
        double area = cv::contourArea(contour);
        if (area < minArea) {
            continue;
        }
        count++;
        cv::Moments moments = cv::moments(contour);
        if (area > largestArea && moments.m00 > 0) {
            largestArea = area;
            largestX = moments.m10 / moments.m00 + roi.x;
            largestY = moments.m01 / moments.m00 + roi.y;
        }
        if (count <= 200) {
            std::vector<cv::Point> simple;
            cv::approxPolyDP(contour, simple, 1.5, true);
            Overlay overlay;
            overlay.style = OverlayStyle::Good;
            for (const auto& p : simple) {
                overlay.points.emplace_back(float(p.x + roi.x), float(p.y + roi.y));
            }
            out.overlays.push_back(std::move(overlay));
        }
    }
    if (!out.overlays.empty() && !label.empty()) {
        out.overlays.front().label = label;
    }
    out.measures.push_back({"count", double(count), ""});
    if (count > 0) {
        out.measures.push_back({"largest_area", mm > 0 ? largestArea * mm * mm : largestArea, mm > 0 ? "mm²" : "px²"});
        out.measures.push_back({"x", largestX, "px"});
        out.measures.push_back({"y", largestY, "px"});
    }
}

void drawRegion(cv::Rect roi, const ToolInput& input, const std::string& label, OverlayStyle style, ToolOutput& out) {
    Overlay overlay;
    overlay.style = style;
    overlay.label = label;
    if (input.number("regionShape", 0) == 1) {
        for (int i = 0; i < 72; i++) {
            double t = i * 2 * CV_PI / 72;
            overlay.points.emplace_back(float(roi.x + roi.width / 2.0 + roi.width / 2.0 * std::cos(t)), float(roi.y + roi.height / 2.0 + roi.height / 2.0 * std::sin(t)));
        }
    } else {
        overlay.points = {cv::Point2f(float(roi.x), float(roi.y)), cv::Point2f(float(roi.x + roi.width), float(roi.y)),
                          cv::Point2f(float(roi.x + roi.width), float(roi.y + roi.height)), cv::Point2f(float(roi.x), float(roi.y + roi.height))};
    }
    out.overlays.push_back(std::move(overlay));
}

double regionPixels(cv::Rect roi, const cv::Mat& mask) {
    return mask.empty() ? double(roi.area()) : double(cv::countNonZero(mask));
}

const size_t kExtractorCells = 64 * 64 * 64;

inline uint32_t cellOf(int r, int g, int b) {
    return uint32_t((r >> 2) << 12 | (g >> 2) << 6 | (b >> 2));
}

// The grid's grey table for one color: 255 in the volume, fading with distance across the softness band.
std::vector<uint8_t> buildExtractorTable(const ColorReference& color) {
    std::vector<uint8_t> occupied(kExtractorCells, 0);
    auto mark = [&](double r, double g, double b) {
        occupied[cellOf(std::clamp(int(r), 0, 255), std::clamp(int(g), 0, 255), std::clamp(int(b), 0, 255))] = 1;
    };
    for (uint32_t cell : color.voxels) {
        if (cell >= kExtractorCells) {
            continue;
        }
        double r = ((cell >> 12) & 63) * 4 + 2, g = ((cell >> 6) & 63) * 4 + 2, b = (cell & 63) * 4 + 2;
        mark(r, g, b);
        // The matte lines are the same color lit less or more. The highlight line runs from the color toward pure white.
        // Steps of two levels at most, since the grid's cells are four levels wide and a coarser line would leave gaps in it.
        double farthest = std::max({color.matteLow * std::max({r, g, b}), color.matteHigh * std::max({r, g, b}), color.highlight * (255 - std::min({r, g, b}))});
        int steps = int(std::ceil(farthest / 2));
        for (int i = 1; i <= steps; i++) {
            double t = double(i) / steps;
            if (color.matteLow > 0) {
                mark(r * (1 - color.matteLow * t), g * (1 - color.matteLow * t), b * (1 - color.matteLow * t));
            }
            if (color.matteHigh > 0) {
                mark(r * (1 + color.matteHigh * t), g * (1 + color.matteHigh * t), b * (1 + color.matteHigh * t));
            }
            if (color.highlight > 0) {
                mark(r + (255 - r) * color.highlight * t, g + (255 - g) * color.highlight * t, b + (255 - b) * color.highlight * t);
            }
        }
    }

    std::vector<uint8_t> table(kExtractorCells, 0);
    double reach = color.dilation + color.softness;
    if (reach <= 0) {
        for (size_t i = 0; i < kExtractorCells; i++) {
            table[i] = occupied[i] ? 255 : 0;
        }
        return table;
    }
    // Distance to the nearest occupied cell, in RGB levels, by a 3-D chamfer sweep.
    const float cell = 4;
    const float big = 1e6f;
    std::vector<float> distance(kExtractorCells, big);
    for (size_t i = 0; i < kExtractorCells; i++) {
        if (occupied[i]) {
            distance[i] = 0;
        }
    }
    auto at = [&](int r, int g, int b) -> float& { return distance[size_t(r) << 12 | size_t(g) << 6 | size_t(b)]; };
    auto relax = [&](float& value, int r, int g, int b, float weight) {
        if (r >= 0 && g >= 0 && b >= 0 && r < 64 && g < 64 && b < 64) {
            value = std::min(value, at(r, g, b) + weight);
        }
    };
    const float a = cell, d2 = cell * 1.4142f, d3 = cell * 1.7321f;
    for (int r = 0; r < 64; r++) {
        for (int g = 0; g < 64; g++) {
            for (int b = 0; b < 64; b++) {
                float& v = at(r, g, b);
                for (int dr = -1; dr <= 0; dr++) {
                    for (int dg = -1; dg <= 1; dg++) {
                        for (int db = -1; db <= 1; db++) {
                            if (dr == 0 && (dg > 0 || (dg == 0 && db >= 0))) {
                                continue;
                            }
                            int order = (dr != 0) + (dg != 0) + (db != 0);
                            relax(v, r + dr, g + dg, b + db, order == 1 ? a : (order == 2 ? d2 : d3));
                        }
                    }
                }
            }
        }
    }
    for (int r = 63; r >= 0; r--) {
        for (int g = 63; g >= 0; g--) {
            for (int b = 63; b >= 0; b--) {
                float& v = at(r, g, b);
                for (int dr = 0; dr <= 1; dr++) {
                    for (int dg = -1; dg <= 1; dg++) {
                        for (int db = -1; db <= 1; db++) {
                            if (dr == 0 && (dg < 0 || (dg == 0 && db <= 0))) {
                                continue;
                            }
                            int order = (dr != 0) + (dg != 0) + (db != 0);
                            relax(v, r + dr, g + dg, b + db, order == 1 ? a : (order == 2 ? d2 : d3));
                        }
                    }
                }
            }
        }
    }
    for (size_t i = 0; i < kExtractorCells; i++) {
        float d = distance[i];
        if (d <= color.dilation) {
            table[i] = 255;
        } else if (color.softness > 0 && d < reach) {
            // Cognex: raising softness doesn't add counted pixels, since by default only 255 counts. It only brightens
            // the greys of pixels near the color. Cognex gives no formula, so this straight fade is this project's own.
            table[i] = uint8_t(std::clamp(254.0 * (1 - (d - color.dilation) / color.softness), 0.0, 254.0));
        }
    }
    return table;
}

// Average of color distance turned into 0 to 1, in the double cone Cognex describes for HSI: greys on the axis, and
// fully saturated colors around the outside, so that hue counts for less the greyer a color is.
double colorSimilarity(const std::array<double, 3>& a, const std::array<double, 3>& b, bool hsi, bool ignoreBrightness) {
    if (!hsi && ignoreBrightness) {
        // Compare the proportions of red, green and blue. They stay the same when the light only gets dimmer or brighter.
        double sumA = std::max(1.0, a[0] + a[1] + a[2]), sumB = std::max(1.0, b[0] + b[1] + b[2]);
        double d = 0;
        for (size_t k = 0; k < 3; k++) {
            double difference = a[k] / sumA - b[k] / sumB;
            d += difference * difference;
        }
        return 1 - std::sqrt(d) / std::sqrt(2.0);
    }
    if (!hsi) {
        double d = std::sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
        return 1 - d / (255 * std::sqrt(3.0));
    }
    double ta = a[0] / kHueScale, tb = b[0] / kHueScale;
    double xa = a[1] * std::cos(ta), ya = a[1] * std::sin(ta), xb = b[1] * std::cos(tb), yb = b[1] * std::sin(tb);
    if (ignoreBrightness) {
        return 1 - std::hypot(xa - xb, ya - yb) / 510.0;
    }
    double d = std::sqrt((xa - xb) * (xa - xb) + (ya - yb) * (ya - yb) + (a[2] - b[2]) * (a[2] - b[2]));
    return 1 - d / std::sqrt(510.0 * 510.0 + 255.0 * 255.0);
}

// A 16 × 16 × 16 RGB histogram collapsed to the proportions of red and green in each cell, which brightness doesn't change.
// Very dark cells have proportions that are mostly noise, so they don't vote.
std::vector<float> chromaticityOf(const std::vector<float>& histogram) {
    const int bins = 24;
    std::vector<float> result(size_t(bins * bins), 0.f);
    double total = 0;
    for (int r = 0; r < 16; r++) {
        for (int g = 0; g < 16; g++) {
            for (int b = 0; b < 16; b++) {
                size_t index = size_t(r << 8 | g << 4 | b);
                if (index >= histogram.size() || histogram[index] <= 0) {
                    continue;
                }
                double cr = r * 16 + 8, cg = g * 16 + 8, cb = b * 16 + 8, sum = cr + cg + cb;
                if (sum < 60) {
                    continue;
                }
                int u = std::min(bins - 1, int(cr / sum * bins)), v = std::min(bins - 1, int(cg / sum * bins));
                result[size_t(u * bins + v)] += histogram[index];
                total += histogram[index];
            }
        }
    }
    if (total > 0) {
        for (float& value : result) {
            value = float(value / total);
        }
    }
    return result;
}

void reportScores(const std::vector<double>& scores, const ToolInput& input, cv::Rect roi, ToolOutput& out) {
    size_t best = size_t(std::max_element(scores.begin(), scores.end()) - scores.begin());
    double second = -1;
    for (size_t i = 0; i < scores.size(); i++) {
        if (i != best) {
            second = std::max(second, scores[i]);
        }
    }
    out.measures.push_back({"score", scores[best], ""});
    out.measures.push_back({"best_index", double(best + 1), ""});
    if (second >= 0) {
        out.measures.push_back({"margin", scores[best] - second, ""});
    }
    out.texts.push_back(input.colors[best].name);
    drawRegion(roi, input, cv::format("%s %.3f", input.colors[best].name.c_str(), scores[best]), OverlayStyle::Good, out);
}

}  // namespace

cv::Vec3f rgbToHsi(float r, float g, float b) {
    float intensity = (r + g + b) / 3;
    float smallest = std::min(r, std::min(g, b));
    float saturation = intensity > 0 ? (1 - smallest / intensity) * 255 : 0;
    float hue = 0;
    float numerator = 0.5f * ((r - g) + (r - b));
    float denominator = std::sqrt((r - g) * (r - g) + (r - b) * (g - b));
    if (denominator > 1e-6f) {
        float angle = std::acos(std::clamp(numerator / denominator, -1.f, 1.f));
        if (b > g) {
            angle = float(2 * CV_PI) - angle;
        }
        hue = angle * float(kHueScale);
        if (hue >= 256) {
            hue -= 256;
        }
    }
    return cv::Vec3f(hue, saturation, intensity);
}

cv::Mat regionMask(cv::Size size, const ToolInput& input) {
    if (input.number("regionShape", 0) != 1) {
        return {};
    }
    cv::Mat mask = cv::Mat::zeros(size, CV_8U);
    cv::ellipse(mask, cv::Point(size.width / 2, size.height / 2), cv::Size(size.width / 2, size.height / 2), 0, 0, 360, cv::Scalar(255), cv::FILLED);
    return mask;
}

ColorReference trainColor(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input) {
    ColorReference color;
    cv::Mat crop = bgr(roi);
    cv::Mat mask = regionMask(crop.size(), input);
    RegionStats stats = statsOf(crop, mask);
    color.meanRGB = stats.meanRGB;
    color.meanHSI = stats.meanHSI;
    color.spreadRGB = stats.spreadRGB;
    color.spreadHSI = stats.spreadHSI;
    // Cognex generates starting tolerances automatically. Three spreads, with a floor for a very even region, is this
    // project's own choice, and it's meant to be adjusted.
    for (size_t k = 0; k < 3; k++) {
        double rgb = std::max(8.0, stats.spreadRGB[k] * 3);
        double hsi = std::max(k == 0 ? 6.0 : 15.0, stats.spreadHSI[k] * 3);
        color.lowRGB[k] = -rgb;
        color.highRGB[k] = rgb;
        color.lowHSI[k] = -hsi;
        color.highHSI[k] = hsi;
    }

    std::vector<int> cells(kExtractorCells, 0);
    color.histogram.assign(16 * 16 * 16, 0.f);
    double total = 0;
    for (int y = 0; y < crop.rows; y++) {
        const cv::Vec3b* row = crop.ptr<cv::Vec3b>(y);
        const uchar* allowed = mask.empty() ? nullptr : mask.ptr<uchar>(y);
        for (int x = 0; x < crop.cols; x++) {
            if (allowed && !allowed[x]) {
                continue;
            }
            int r = row[x][2], g = row[x][1], b = row[x][0];
            cells[cellOf(r, g, b)]++;
            color.histogram[size_t((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4))] += 1;
            total += 1;
        }
    }
    if (total > 0) {
        for (float& value : color.histogram) {
            value = float(value / total);
        }
    }
    // Stray cells from noise would each pull in unrelated pixels at run time, so a cell has to hold a few pixels to count.
    int least = std::max(2, int(total * 0.0002));
    for (size_t i = 0; i < kExtractorCells; i++) {
        if (cells[i] >= least) {
            color.voxels.push_back(uint32_t(i));
        }
    }
    return color;
}

struct ColorExtractorCache::Impl {
    std::unordered_map<std::string, std::shared_ptr<const std::vector<uint8_t>>> tables;
};

ColorExtractorCache::ColorExtractorCache() : impl(std::make_unique<Impl>()) {}
ColorExtractorCache::~ColorExtractorCache() = default;

std::shared_ptr<const std::vector<uint8_t>> ColorExtractorCache::tableFor(const ColorReference& color) {
    std::string key = cv::format("%.3f,%.3f,%.3f,%.3f,%.3f,", color.dilation, color.softness, color.matteLow, color.matteHigh, color.highlight);
    key.append(reinterpret_cast<const char*>(color.voxels.data()), color.voxels.size() * sizeof(uint32_t));
    auto found = impl->tables.find(key);
    if (found != impl->tables.end()) {
        return found->second;
    }
    if (impl->tables.size() > 32) {
        impl->tables.clear();  // nothing needs them all at once, and a slider's old values shouldn't pile up
    }
    auto table = std::make_shared<const std::vector<uint8_t>>(buildExtractorTable(color));
    impl->tables[key] = table;
    return table;
}

void runColorSegmenter(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    if (input.colors.empty()) {
        out.error = "No colors yet. Draw a region on the color you want, then press Add Color from Region.";
        return;
    }
    bool hsi = input.number("colorSpace", 1) == 1;
    int planesToCheck = hsi && input.number("ignoreBrightness", 0) != 0 ? 2 : 3;  // intensity is the last plane
    cv::Mat crop = bgr(roi);
    cv::Mat region = regionMask(crop.size(), input);
    cv::Mat grey = cv::Mat::zeros(crop.size(), CV_8U);

    struct Range {
        float nominal[3], low[3], high[3], softness;
    };
    std::vector<Range> ranges;
    for (const ColorReference& color : input.colors) {
        Range range;
        for (size_t k = 0; k < 3; k++) {
            range.nominal[k] = float(hsi ? color.meanHSI[k] : color.meanRGB[k]);
            range.low[k] = float(hsi ? color.lowHSI[k] : color.lowRGB[k]);
            range.high[k] = float(hsi ? color.highHSI[k] : color.highRGB[k]);
        }
        range.softness = float(color.softness);
        ranges.push_back(range);
    }

    cv::parallel_for_(cv::Range(0, crop.rows), [&](const cv::Range& rows) {
        for (int y = rows.start; y < rows.end; y++) {
            const cv::Vec3b* row = crop.ptr<cv::Vec3b>(y);
            const uchar* allowed = region.empty() ? nullptr : region.ptr<uchar>(y);
            uchar* output = grey.ptr<uchar>(y);
            for (int x = 0; x < crop.cols; x++) {
                if (allowed && !allowed[x]) {
                    continue;
                }
                float planes[3];
                if (hsi) {
                    cv::Vec3f v = rgbToHsi(row[x][2], row[x][1], row[x][0]);
                    planes[0] = v[0];
                    planes[1] = v[1];
                    planes[2] = v[2];
                } else {
                    planes[0] = row[x][2];
                    planes[1] = row[x][1];
                    planes[2] = row[x][0];
                }
                float strongest = 0;  // Cognex: a logical OR of all the ranges
                for (const Range& range : ranges) {
                    float weakest = 1;  // a pixel is only as much in the range as its least-matching plane
                    for (int k = 0; k < planesToCheck && weakest > 0; k++) {
                        float offset = hsi && k == 0 ? hueOffset(planes[0], range.nominal[0]) : planes[k] - range.nominal[k];
                        weakest = std::min(weakest, planeMembership(offset, range.low[k], range.high[k], range.softness));
                    }
                    strongest = std::max(strongest, weakest);
                }
                output[x] = uchar(strongest * 255 + 0.5f);
            }
        }
    });

    double matched = cv::countNonZero(grey == 255);
    out.measures.push_back({"matched_pixels", matched, ""});
    out.measures.push_back({"matched_share", matched * 100 / std::max(1.0, regionPixels(roi, region)), "%"});
    reportBlobs(grey, roi, 255, input, "", out);
    if (input.number("regionShape", 0) == 1) {
        drawRegion(roi, input, "", OverlayStyle::Info, out);
    }
}

void runColorExtractor(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ColorExtractorCache& cache, ToolOutput& out) {
    if (input.colors.empty()) {
        out.error = "No colors yet. Draw a region on the color you want, then press Add Color from Region.";
        return;
    }
    cv::Mat crop = bgr(roi);
    cv::Mat region = regionMask(crop.size(), input);
    int threshold = std::clamp(int(input.number("softnessThreshold", 255)), 1, 255);

    std::vector<std::shared_ptr<const std::vector<uint8_t>>> tables;
    for (const ColorReference& color : input.colors) {
        tables.push_back(cache.tableFor(color));
    }
    cv::Mat grey = cv::Mat::zeros(crop.size(), CV_8U);
    std::vector<std::vector<double>> counts(size_t(std::max(1, crop.rows)), std::vector<double>(tables.size(), 0.0));
    cv::parallel_for_(cv::Range(0, crop.rows), [&](const cv::Range& rows) {
        for (int y = rows.start; y < rows.end; y++) {
            const cv::Vec3b* row = crop.ptr<cv::Vec3b>(y);
            const uchar* allowed = region.empty() ? nullptr : region.ptr<uchar>(y);
            uchar* output = grey.ptr<uchar>(y);
            auto& rowCounts = counts[size_t(y)];
            for (int x = 0; x < crop.cols; x++) {
                if (allowed && !allowed[x]) {
                    continue;
                }
                uint32_t cell = cellOf(row[x][2], row[x][1], row[x][0]);
                uchar strongest = 0;
                for (size_t t = 0; t < tables.size(); t++) {
                    uchar value = (*tables[t])[cell];
                    strongest = std::max(strongest, value);
                    if (value >= threshold) {
                        rowCounts[t] += 1;
                    }
                }
                output[x] = strongest;
            }
        }
    });
    std::vector<double> totals(tables.size(), 0.0);
    for (const auto& row : counts) {
        for (size_t t = 0; t < totals.size(); t++) {
            totals[t] += row[t];
        }
    }
    size_t best = size_t(std::max_element(totals.begin(), totals.end()) - totals.begin());
    double matched = cv::countNonZero(grey >= threshold);
    out.measures.push_back({"matched_pixels", matched, ""});
    out.measures.push_back({"matched_share", matched * 100 / std::max(1.0, regionPixels(roi, region)), "%"});
    if (totals[best] > 0) {
        // As In-Sight's ExtractColor describes it: the color with the highest pixel count is the best match.
        out.measures.push_back({"best_index", double(best + 1), ""});
        out.measures.push_back({"best_pixels", totals[best], ""});
        out.texts.push_back(input.colors[best].name);
    }
    reportBlobs(grey, roi, threshold, input, totals[best] > 0 ? input.colors[best].name : "", out);
    if (input.number("regionShape", 0) == 1) {
        drawRegion(roi, input, "", OverlayStyle::Info, out);
    }
}

void runColorMatch(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    if (input.colors.empty()) {
        out.error = "No reference colors yet. Draw a region on a known color, then press Add Color from Region.";
        return;
    }
    cv::Mat crop = bgr(roi);
    RegionStats stats = statsOf(crop, regionMask(crop.size(), input));
    bool hsi = input.number("colorSpace", 0) == 1;
    bool ignoreBrightness = input.number("ignoreBrightness", 0) != 0;
    std::vector<double> scores;
    for (const ColorReference& color : input.colors) {
        scores.push_back(hsi ? colorSimilarity(stats.meanHSI, color.meanHSI, true, ignoreBrightness) : colorSimilarity(stats.meanRGB, color.meanRGB, false, ignoreBrightness));
    }
    reportScores(scores, input, roi, out);
    out.measures.push_back({"red", stats.meanRGB[0], ""});
    out.measures.push_back({"green", stats.meanRGB[1], ""});
    out.measures.push_back({"blue", stats.meanRGB[2], ""});
    out.measures.push_back({"hue", stats.meanHSI[0], ""});
    out.measures.push_back({"saturation", stats.meanHSI[1], ""});
    out.measures.push_back({"intensity", stats.meanHSI[2], ""});
}

void runCompositeColorMatch(const cv::Mat& bgr, cv::Rect roi, const ToolInput& input, ToolOutput& out) {
    if (input.colors.empty()) {
        out.error = "No reference colors yet. Draw a region on a known sample, then press Add Color from Region.";
        return;
    }
    ColorReference sample = trainColor(bgr, roi, input);
    bool ignoreBrightness = input.number("ignoreBrightness", 0) != 0;
    std::vector<float> sampleDistribution = ignoreBrightness ? chromaticityOf(sample.histogram) : sample.histogram;
    std::vector<double> scores;
    for (const ColorReference& color : input.colors) {
        std::vector<float> reference = ignoreBrightness ? chromaticityOf(color.histogram) : color.histogram;
        // Cognex compares "the distribution of pixel values" without giving a measure. This is the Bhattacharyya
        // coefficient, which is 1 for identical distributions and 0 for ones that don't overlap.
        double sum = 0;
        for (size_t i = 0; i < sampleDistribution.size() && i < reference.size(); i++) {
            sum += std::sqrt(double(sampleDistribution[i]) * reference[i]);
        }
        scores.push_back(sum);
    }
    reportScores(scores, input, roi, out);
}

}  // namespace mxv
