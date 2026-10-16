#include "optimizer.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <limits>
#include <set>
#include <stdexcept>
#include <string>

namespace mxjobs {
namespace {

constexpr int kMaxIterations = 20000;
constexpr double kTolerance = 1e-10;
constexpr int kSharpeGrid = 80;
constexpr int kGoldenSteps = 30;

struct InvalidInput : std::runtime_error {
    using std::runtime_error::runtime_error;
};

double gridExponent(int k) { return -2 + 5.0 * k / (kSharpeGrid - 1); }

double sharpeOf(const Vector& w, const Vector& mu, const Matrix& cov, double rf) {
    double vol = std::sqrt(quad(w, cov));
    return vol > 0 ? (dot(mu, w) - rf) / vol : -std::numeric_limits<double>::infinity();
}

double number(const json& v, double fallback, const std::string& name, bool required = false) {
    if (v.is_null() && !required) return fallback;
    if (v.is_number()) {
        double x = v.get<double>();
        if (std::isfinite(x)) return x;
    }
    if (v.is_string()) {
        try {
            size_t used = 0;
            double x = std::stod(v.get<std::string>(), &used);
            if (std::isfinite(x)) return x;
        } catch (...) {
        }
    }
    throw InvalidInput(name + " must be a number");
}

std::vector<std::string> assetsOf(const json& v) {
    if (!v.is_array() || v.empty()) throw InvalidInput("assets must be a non-empty array of names");
    std::vector<std::string> names;
    std::set<std::string> seen;
    for (const auto& x : v) {
        if (!x.is_string() || x.get<std::string>().find_first_not_of(" \t") == std::string::npos)
            throw InvalidInput("asset names must be non-empty strings");
        std::string s = x.get<std::string>();
        if (!seen.insert(s).second) throw InvalidInput("duplicate asset " + s);
        names.push_back(s);
    }
    return names;
}

Vector vectorOf(const json& v, size_t n, const std::string& name) {
    if (!v.is_array() || v.size() != n) throw InvalidInput(name + " must be an array of " + std::to_string(n) + " numbers");
    Vector out(n);
    for (size_t i = 0; i < n; i++) out[i] = number(v[i], 0, name, true);
    return out;
}

Matrix matrixOf(const json& v, size_t n) {
    if (!v.is_array() || v.size() != n)
        throw InvalidInput("covariance must be " + std::to_string(n) + " × " + std::to_string(n));
    Matrix m(n);
    for (size_t i = 0; i < n; i++) m[i] = vectorOf(v[i], n, "covariance row " + std::to_string(i + 1));
    for (size_t i = 0; i < n; i++) {
        if (m[i][i] < 0) throw InvalidInput("covariance diagonal must be ≥ 0");
        for (size_t j = 0; j < i; j++)
            if (std::fabs(m[i][j] - m[j][i]) > 1e-9) throw InvalidInput("covariance must be symmetric");
    }
    return m;
}

// Annualised μ and Σ from daily closes.
void estimate(const std::vector<std::string>& assets, const json& prices, Vector& mu, Matrix& cov) {
    size_t n = assets.size();
    std::vector<Vector> returns(n);
    long length = -1;
    for (size_t a = 0; a < n; a++) {
        if (!prices.contains(assets[a]) || !prices[assets[a]].is_array())
            throw InvalidInput("prices for " + assets[a] + " are missing");
        const json& series = prices[assets[a]];
        if (length < 0) length = static_cast<long>(series.size());
        if (static_cast<long>(series.size()) != length) throw InvalidInput("all price series must have the same length");
        if (length < 3) throw InvalidInput("need at least 3 prices per asset");
        Vector p = vectorOf(series, static_cast<size_t>(length), "prices." + assets[a]);
        for (long t = 1; t < length; t++) {
            if (!(p[t - 1] > 0)) throw InvalidInput("prices must be positive");
            returns[a].push_back(p[t] / p[t - 1] - 1);
        }
    }
    size_t m = static_cast<size_t>(length - 1);
    Vector mean(n);
    for (size_t a = 0; a < n; a++) {
        double s = 0;
        for (double r : returns[a]) s += r;
        mean[a] = s / m;
    }
    mu.assign(n, 0);
    cov.assign(n, Vector(n, 0));
    for (size_t a = 0; a < n; a++) mu[a] = mean[a] * 252;
    for (size_t a = 0; a < n; a++)
        for (size_t b = 0; b < n; b++) {
            double s = 0;
            for (size_t t = 0; t < m; t++) s += (returns[a][t] - mean[a]) * (returns[b][t] - mean[b]);
            cov[a][b] = s / (m - 1) * 252;
        }
}

std::string fixed4(double x) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.4f", x);
    return buf;
}

json decision(const std::string& status, const double* sharpe, const double* turnover, const double* maxTurnover,
              const std::string& message) {
    double c = roundTo(std::min(0.95, std::max(0.05, 0.5 + 0.4 * std::tanh(sharpe ? *sharpe : 0))), 4);
    json d;
    if (status == "invalid_input") {
        d = {{"recommendation", "escalate"}, {"confidence", 1.0}, {"alternatives", json::array()},
             {"reason", "The request was rejected: " + message}};
    } else if (status == "infeasible") {
        d = {{"recommendation", "rerun_relaxed"}, {"confidence", 0.9}, {"alternatives", {"escalate"}},
             {"reason", "The constraints cannot be met; relax them and rerun. " + message}};
    } else if (status == "max_iterations") {
        d = {{"recommendation", "escalate"}, {"confidence", 0.4}, {"alternatives", {"rebalance", "hold"}},
             {"reason", "The solver did not converge; review before acting."}};
    } else if (!turnover) {
        d = {{"recommendation", "rebalance"}, {"confidence", c}, {"alternatives", {"hold"}},
             {"reason", "No current weights: this is an initial allocation."}};
    } else if (*turnover < 0.02) {
        d = {{"recommendation", "hold"}, {"confidence", 0.9}, {"alternatives", {"rebalance"}},
             {"reason", "Turnover " + fixed4(*turnover) + " is below 0.02: the portfolio is already close to optimal."}};
    } else if (maxTurnover && *turnover > *maxTurnover) {
        d = {{"recommendation", "rebalance_partially"}, {"confidence", c}, {"alternatives", {"rebalance", "hold"}},
             {"reason", "Turnover " + fixed4(*turnover) + " exceeds the maximum " + fixed4(*maxTurnover) +
                            ": move part of the way."}};
    } else {
        d = {{"recommendation", "rebalance"}, {"confidence", c}, {"alternatives", {"rebalance_partially", "hold"}},
             {"reason", "Turnover " + fixed4(*turnover) + " is within limits."}};
    }
    return d;
}

json emptyOutcome(const std::string& status, const std::string& objective) {
    return json{{"schema", kOptimizationSchema}, {"solverStatus", status}, {"objective", objective},
                {"weights", json::object()}, {"expectedReturn", nullptr}, {"volatility", nullptr},
                {"sharpe", nullptr}, {"bindingConstraints", json::array()}, {"turnover", nullptr}};
}

json diagnostics(int iterations, std::chrono::steady_clock::time_point started, const std::string& message) {
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    json d{{"engine", kEngine}, {"iterations", iterations}, {"ms", roundTo(ms, 3)}};
    if (!message.empty()) d["message"] = message;
    return d;
}

}  // namespace

// ---------------------------------------------------------------------------- math

Vector times(const Matrix& m, const Vector& x) {
    Vector y(x.size());
    for (size_t i = 0; i < x.size(); i++) {
        double s = 0;
        for (size_t j = 0; j < x.size(); j++) s += m[i][j] * x[j];
        y[i] = s;
    }
    return y;
}

double dot(const Vector& a, const Vector& b) {
    double s = 0;
    for (size_t i = 0; i < a.size(); i++) s += a[i] * b[i];
    return s;
}

double quad(const Vector& w, const Matrix& m) { return dot(w, times(m, w)); }

double roundTo(double x, int places) {
    double f = std::pow(10.0, places);
    return std::floor(x * f + 0.5) / f;  // same as Java's Math.round
}

Vector project(const Vector& v, double cap) {
    double lo = *std::min_element(v.begin(), v.end()) - 1;
    double hi = *std::max_element(v.begin(), v.end());
    for (int k = 0; k < 100; k++) {
        double mid = (lo + hi) / 2, sum = 0;
        for (double x : v) sum += std::min(cap, std::max(0.0, x - mid));
        if (sum > 1) lo = mid; else hi = mid;
    }
    double tau = (lo + hi) / 2;
    Vector w(v.size());
    for (size_t i = 0; i < v.size(); i++) w[i] = std::min(cap, std::max(0.0, v[i] - tau));
    return w;
}

double maxEigenvalue(const Matrix& m) {
    Vector x(m.size(), 1.0);
    for (int k = 0; k < 60; k++) {
        Vector y = times(m, x);
        double norm = std::sqrt(dot(y, y));
        if (norm == 0) return 1e-12;
        for (size_t i = 0; i < x.size(); i++) x[i] = y[i] / norm;
    }
    return std::max(quad(x, m), 1e-12);
}

Solve meanVariance(const Vector& mu, const Matrix& cov, double lambda, double cap, double lipschitz) {
    size_t n = mu.size();
    Vector w = project(Vector(n, 1.0 / n), cap);
    double step = 1 / (lambda * lipschitz);
    for (int it = 1; it <= kMaxIterations; it++) {
        Vector sw = times(cov, w), v(n);
        for (size_t i = 0; i < n; i++) v[i] = w[i] + step * (mu[i] - lambda * sw[i]);
        Vector next = project(v, cap);
        double diff = 0;
        for (size_t i = 0; i < n; i++) diff = std::max(diff, std::fabs(next[i] - w[i]));
        w = next;
        if (diff < kTolerance) return {w, it, true};
    }
    return {w, kMaxIterations, false};
}

// ---------------------------------------------------------------------------- request → outcome

json optimize(const json& req) {
    auto started = std::chrono::steady_clock::now();
    std::string objective = "max_sharpe";
    try {
        if (!req.is_object()) throw InvalidInput("the body must be a JSON object");
        auto field = [&](const char* k) -> json { return req.contains(k) ? req[k] : json(); };
        std::vector<std::string> assets = assetsOf(field("assets"));
        size_t n = assets.size();
        Vector mu;
        Matrix cov;
        if (!field("expectedReturns").is_null() || !field("covariance").is_null()) {
            mu = vectorOf(field("expectedReturns"), n, "expectedReturns");
            cov = matrixOf(field("covariance"), n);
        } else if (field("prices").is_object()) {
            estimate(assets, field("prices"), mu, cov);
        } else {
            throw InvalidInput("send expectedReturns and covariance, or prices");
        }
        if (field("objective").is_string() && !field("objective").get<std::string>().empty())
            objective = field("objective").get<std::string>();
        if (objective != "max_sharpe" && objective != "min_variance" && objective != "mean_variance")
            throw InvalidInput("objective must be max_sharpe, min_variance or mean_variance");
        double riskAversion = number(field("riskAversion"), 3, "riskAversion");
        if (!(riskAversion > 0)) throw InvalidInput("riskAversion must be > 0");
        double rf = number(field("riskFreeRate"), 0, "riskFreeRate");
        double cap = number(field("maxWeight"), 1, "maxWeight");
        if (!(cap > 0 && cap <= 1)) throw InvalidInput("maxWeight must be in (0, 1]");
        const json currentWeights = field("currentWeights");  // kept alive: items() below refers into it
        bool hasCurrent = !currentWeights.is_null();
        std::vector<std::pair<std::string, double>> current;
        if (hasCurrent) {
            if (!currentWeights.is_object()) throw InvalidInput("currentWeights must be an object of asset → weight");
            for (auto& [k, v] : currentWeights.items()) current.emplace_back(k, number(v, 0, "currentWeights", true));
        }
        bool hasMaxTurnover = !field("maxTurnover").is_null();
        double maxTurnover = hasMaxTurnover ? number(field("maxTurnover"), 0, "maxTurnover") : 0;

        if (cap * n < 1 - 1e-12) {
            char msg[160];
            std::snprintf(msg, sizeof msg, "maxWeight %.4g × %zu assets < 1: no fully invested portfolio fits the cap", cap, n);
            json out = emptyOutcome("infeasible", objective);
            out["diagnostics"] = diagnostics(0, started, msg);
            out["decisionContext"] = decision("infeasible", nullptr, nullptr, nullptr, msg);
            return out;
        }

        double lipschitz = maxEigenvalue(cov);
        Solve best{};
        int iterations = 0;
        bool converged = true;
        if (objective == "min_variance") {
            best = meanVariance(Vector(n, 0.0), cov, 1, cap, lipschitz);
            iterations = best.iterations;
            converged = best.converged;
        } else if (objective == "mean_variance") {
            best = meanVariance(mu, cov, riskAversion, cap, lipschitz);
            iterations = best.iterations;
            converged = best.converged;
        } else {
            double bestSharpe = -std::numeric_limits<double>::infinity();
            bool have = false;
            int bestK = 0;
            for (int k = 0; k < kSharpeGrid; k++) {
                Solve s = meanVariance(mu, cov, std::pow(10.0, gridExponent(k)), cap, lipschitz);
                iterations += s.iterations;
                converged = converged && s.converged;
                double sh = sharpeOf(s.w, mu, cov, rf);
                if (!have || sh > bestSharpe) {
                    best = s;
                    bestSharpe = sh;
                    bestK = k;
                    have = true;
                }
            }
            double a = gridExponent(std::max(bestK - 1, 0));
            double b = gridExponent(std::min(bestK + 1, kSharpeGrid - 1));
            const double phi = (std::sqrt(5.0) - 1) / 2;
            for (int g = 0; g < kGoldenSteps; g++) {
                double x1 = b - phi * (b - a), x2 = a + phi * (b - a);
                Solve s1 = meanVariance(mu, cov, std::pow(10.0, x1), cap, lipschitz);
                Solve s2 = meanVariance(mu, cov, std::pow(10.0, x2), cap, lipschitz);
                iterations += s1.iterations + s2.iterations;
                converged = converged && s1.converged && s2.converged;
                double f1 = sharpeOf(s1.w, mu, cov, rf), f2 = sharpeOf(s2.w, mu, cov, rf);
                if (f1 > bestSharpe) { best = s1; bestSharpe = f1; }
                if (f2 > bestSharpe) { best = s2; bestSharpe = f2; }
                if (f1 >= f2) b = x2; else a = x1;
            }
        }

        const Vector& w = best.w;
        double ret = dot(mu, w), vol = std::sqrt(quad(w, cov));
        bool hasSharpe = vol > 0;
        double sharpe = hasSharpe ? (ret - rf) / vol : 0;

        json weights = json::object();
        for (size_t i = 0; i < n; i++) weights[assets[i]] = roundTo(w[i], 6);

        bool hasTurnover = hasCurrent;
        double turnover = 0;
        if (hasCurrent) {
            std::vector<std::string> all = assets;
            for (auto& [k, v] : current)
                if (std::find(all.begin(), all.end(), k) == all.end()) all.push_back(k);
            double sum = 0;
            for (const auto& a : all) {
                auto it = std::find(assets.begin(), assets.end(), a);
                double mine = it == assets.end() ? 0 : w[static_cast<size_t>(it - assets.begin())];
                double theirs = 0;
                for (auto& [k, v] : current) if (k == a) theirs = v;
                sum += std::fabs(mine - theirs);
            }
            turnover = roundTo(sum / 2, 6);
        }

        json binding = json::array();
        bool atCap = false, atZero = false;
        for (double x : w) {
            if (cap < 1 && x >= cap - 1e-6) atCap = true;
            if (x <= 1e-6) atZero = true;
        }
        if (atCap) binding.push_back("max_weight");
        if (atZero) binding.push_back("long_only");
        if (hasMaxTurnover && hasTurnover && turnover > maxTurnover) binding.push_back("max_turnover");

        std::string status = converged ? "optimal" : "max_iterations";
        json out{{"schema", kOptimizationSchema}, {"solverStatus", status}, {"objective", objective},
                 {"weights", weights}, {"expectedReturn", ret}, {"volatility", vol}};
        out["sharpe"] = hasSharpe ? json(sharpe) : json(nullptr);
        out["bindingConstraints"] = binding;
        out["turnover"] = hasTurnover ? json(turnover) : json(nullptr);
        out["diagnostics"] = diagnostics(iterations, started, "");
        out["decisionContext"] = decision(status, hasSharpe ? &sharpe : nullptr, hasTurnover ? &turnover : nullptr,
                                          hasMaxTurnover ? &maxTurnover : nullptr, "");
        return out;
    } catch (const InvalidInput& e) {
        json out = emptyOutcome("invalid_input", objective);
        out["diagnostics"] = diagnostics(0, started, e.what());
        out["decisionContext"] = decision("invalid_input", nullptr, nullptr, nullptr, e.what());
        return out;
    }
}

}  // namespace mxjobs
