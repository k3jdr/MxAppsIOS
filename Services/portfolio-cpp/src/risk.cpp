#include "risk.hpp"

#include <chrono>
#include <cmath>
#include <stdexcept>
#include <algorithm>
#include <map>
#include <numeric>
#include <string>

#include "inputs.hpp"

namespace mxjobs {
namespace {

struct Invalid : std::runtime_error {
    using std::runtime_error::runtime_error;
};

double num(const json& v, double fallback, const std::string& name) {
    if (v.is_null()) return fallback;
    if (v.is_number() && std::isfinite(v.get<double>())) return v.get<double>();
    if (v.is_string()) {
        try {
            return std::stod(v.get<std::string>());
        } catch (...) {
        }
    }
    throw Invalid(name + " must be a number");
}

}  // namespace

double inverseNormal(double p) {
    static const double a[] = {-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                               1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00};
    static const double b[] = {-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                               6.680131188771972e+01, -1.328068155288572e+01};
    static const double c[] = {-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                               -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00};
    static const double d[] = {7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                               3.754408661907416e+00};
    const double low = 0.02425, high = 1 - low;
    if (p < low) {
        double q = std::sqrt(-2 * std::log(p));
        return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
               ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
    }
    if (p <= high) {
        double q = p - 0.5, r = q * q;
        return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
               (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
    }
    double q = std::sqrt(-2 * std::log(1 - p));
    return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
           ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
}

json risk(const json& request) {
    auto started = std::chrono::steady_clock::now();
    auto diagnostics = [&](const std::string& message) {
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
        json d{{"engine", kEngine}, {"ms", roundTo(ms, 3)}};
        if (!message.empty()) d["message"] = message;
        return d;
    };
    try {
        if (!request.is_object()) throw Invalid("the body must be a JSON object");
        // With inputsUrl the analytics inputs supply assets and covariance, and the current weights by default.
        json req = resolveInputs(request);
        if (!req.contains("weights") && req.contains("currentWeights")) req["weights"] = req["currentWeights"];
        auto field = [&](const char* k) -> json { return req.contains(k) ? req[k] : json(); };
        const json assets = field("assets");
        if (!assets.is_array() || assets.empty()) throw Invalid("assets must be a non-empty array of names");
        size_t n = assets.size();
        const json weights = field("weights");
        if (!weights.is_object()) throw Invalid("weights must be an object of asset → weight");
        Vector w(n, 0.0), mu(n, 0.0);
        for (size_t i = 0; i < n; i++) {
            if (!assets[i].is_string()) throw Invalid("asset names must be strings");
            std::string a = assets[i].get<std::string>();
            w[i] = weights.contains(a) ? num(weights[a], 0, "weights." + a) : 0.0;
        }
        const json cv = field("covariance");
        if (!cv.is_array() || cv.size() != n) throw Invalid("covariance must be " + std::to_string(n) + " × " + std::to_string(n));
        Matrix cov(n, Vector(n));
        for (size_t i = 0; i < n; i++) {
            if (!cv[i].is_array() || cv[i].size() != n) throw Invalid("covariance must be square");
            for (size_t j = 0; j < n; j++) cov[i][j] = num(cv[i][j], 0, "covariance");
        }
        bool hasReturns = !field("expectedReturns").is_null();
        if (hasReturns) {
            const json er = field("expectedReturns");
            if (!er.is_array() || er.size() != n) throw Invalid("expectedReturns must have one number per asset");
            for (size_t i = 0; i < n; i++) mu[i] = num(er[i], 0, "expectedReturns");
        }
        double confidence = num(field("confidence"), 0.95, "confidence");
        if (!(confidence > 0.5 && confidence < 1)) throw Invalid("confidence must be in (0.5, 1)");
        double horizon = num(field("horizonDays"), 1, "horizonDays");
        if (!(horizon > 0)) throw Invalid("horizonDays must be > 0");
        double value = num(field("portfolioValue"), 1, "portfolioValue");

        double variance = quad(w, cov);
        double vol = std::sqrt(std::max(variance, 0.0));
        double sigmaH = vol * std::sqrt(horizon / 252);
        double muH = dot(mu, w) * horizon / 252;
        double z = inverseNormal(confidence);
        double pdf = std::exp(-z * z / 2) / std::sqrt(2 * M_PI);
        double var = value * (z * sigmaH - muH);
        double es = value * (sigmaH * pdf / (1 - confidence) - muH);

        Vector sw = times(cov, w);
        json contributions = json::object();
        double weighted = 0, hhi = 0;
        for (size_t i = 0; i < n; i++) {
            if (w[i] == 0) continue;                    // a 500-name universe: report the holdings only
            contributions[assets[i].get<std::string>()] = variance > 0 ? roundTo(w[i] * sw[i] / variance, 6) : 0.0;
            weighted += w[i] * std::sqrt(std::max(cov[i][i], 0.0));
            hhi += w[i] * w[i];
        }
        json out{{"schema", kRiskSchema}, {"status", "ok"}, {"volatility", vol}, {"valueAtRisk", roundTo(var, 8)},
                 {"expectedShortfall", roundTo(es, 8)}, {"riskContributions", contributions}};
        out["diversificationRatio"] = vol > 0 ? json(weighted / vol) : json(nullptr);
        out["concentration"] = roundTo(hhi, 6);
        out["confidence"] = confidence;
        out["horizonDays"] = horizon;

        // Against the benchmark: tracking error, beta, and where the active risk comes from.
        const json bw = field("benchmarkWeights");
        if (bw.is_array() && bw.size() == n) {
            Vector b(n), a(n);
            for (size_t i = 0; i < n; i++) {
                b[i] = num(bw[i], 0, "benchmarkWeights");
                a[i] = w[i] - b[i];
            }
            double activeVar = quad(a, cov), benchVar = quad(b, cov);
            Vector sa = times(cov, a);
            double te = std::sqrt(std::max(activeVar, 0.0));
            out["trackingError"] = roundTo(te, 6);
            out["beta"] = benchVar > 0 ? json(roundTo(dot(w, times(cov, b)) / benchVar, 4)) : json(nullptr);
            out["benchmarkVolatility"] = roundTo(std::sqrt(std::max(benchVar, 0.0)), 6);
            std::vector<size_t> order(n);
            std::iota(order.begin(), order.end(), 0);
            std::sort(order.begin(), order.end(),
                      [&](size_t x, size_t y) { return std::abs(a[x] * sa[x]) > std::abs(a[y] * sa[y]); });
            json top = json::array();
            for (size_t k = 0; k < std::min<size_t>(10, n); k++) {
                size_t i = order[k];
                top.push_back({{"asset", assets[i]}, {"active", roundTo(a[i], 6)},
                               {"share", activeVar > 0 ? roundTo(a[i] * sa[i] / activeVar, 4) : 0.0}});
            }
            out["activeRiskContributions"] = top;
            const json sectors = field("sectors");
            if (sectors.is_array() && sectors.size() == n) {
                std::map<std::string, double> share;
                for (size_t i = 0; i < n; i++)
                    share[sectors[i].get<std::string>()] += activeVar > 0 ? a[i] * sa[i] / activeVar : 0.0;
                json bySector = json::object();
                for (auto& [k, v] : share) bySector[k] = roundTo(v, 4);
                out["sectorActiveRisk"] = bySector;
            }
            double maxTe = num(field("maxTrackingError"), 0, "maxTrackingError");
            if (maxTe > 0) out["withinTrackingErrorLimit"] = te <= maxTe;
        }
        out["diagnostics"] = diagnostics("");
        return out;
    } catch (const InvalidRequest& e) {
        return json{{"schema", kRiskSchema}, {"status", "invalid_input"}, {"volatility", nullptr},
                    {"valueAtRisk", nullptr}, {"expectedShortfall", nullptr}, {"riskContributions", json::object()},
                    {"diversificationRatio", nullptr}, {"concentration", nullptr}, {"diagnostics", diagnostics(e.what())}};
    } catch (const Invalid& e) {
        return json{{"schema", kRiskSchema}, {"status", "invalid_input"}, {"volatility", nullptr},
                    {"valueAtRisk", nullptr}, {"expectedShortfall", nullptr}, {"riskContributions", json::object()},
                    {"diversificationRatio", nullptr}, {"concentration", nullptr}, {"diagnostics", diagnostics(e.what())}};
    }
}

}  // namespace mxjobs
