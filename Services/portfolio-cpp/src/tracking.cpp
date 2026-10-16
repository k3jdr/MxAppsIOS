#include "tracking.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <map>
#include <numeric>
#include <string>

#include "inputs.hpp"

namespace mxjobs {
namespace {

constexpr int kMaxIterations = 20000;
constexpr double kTolerance = 1e-9;

double number(const json& req, const char* key, double fallback) {
    if (!req.contains(key) || req[key].is_null()) return fallback;
    if (!req[key].is_number()) throw InvalidRequest(std::string(key) + " must be a number");
    return req[key].get<double>();
}

Vector vectorField(const json& req, const char* key, size_t n) {
    if (!req.contains(key) || !req[key].is_array() || req[key].size() != n)
        throw InvalidRequest(std::string(key) + " must have one number per asset (" + std::to_string(n) + ")");
    Vector v(n);
    for (size_t i = 0; i < n; i++) {
        if (!req[key][i].is_number()) throw InvalidRequest(std::string(key) + " must contain numbers");
        v[i] = req[key][i].get<double>();
    }
    return v;
}

// Projection onto {w ≥ 0, w ≤ cap, Σw = 1} for the selected names (others stay 0).
Vector projectOn(const Vector& v, const std::vector<size_t>& names, double cap) {
    double lo = 1e300, hi = -1e300;
    for (size_t i : names) {
        lo = std::min(lo, v[i] - cap);
        hi = std::max(hi, v[i]);
    }
    for (int k = 0; k < 100; k++) {
        double mid = (lo + hi) / 2, sum = 0;
        for (size_t i : names) sum += std::min(cap, std::max(0.0, v[i] - mid));
        if (sum > 1) lo = mid; else hi = mid;
    }
    double tau = (lo + hi) / 2;
    Vector w(v.size(), 0.0);
    for (size_t i : names) w[i] = std::min(cap, std::max(0.0, v[i] - tau));
    return w;
}

}  // namespace

std::vector<size_t> selectNames(const Vector& b, const std::vector<std::string>& sectors, size_t maxNames,
                                bool stratified) {
    size_t n = b.size();
    std::vector<size_t> order(n);
    std::iota(order.begin(), order.end(), 0);
    std::stable_sort(order.begin(), order.end(), [&](size_t x, size_t y) { return b[x] > b[y]; });
    std::vector<size_t> held;
    for (size_t i : order) if (b[i] > 0) held.push_back(i);
    if (maxNames == 0 || maxNames >= held.size()) return held;
    if (!stratified || sectors.size() != n) return std::vector<size_t>(held.begin(), held.begin() + maxNames);

    // Stratified: one name per sector first (the heaviest sectors when there are more sectors than names), then
    // the rest in proportion to sector weight by largest remainder — never more than maxNames in all.
    std::map<std::string, double> weight;
    std::map<std::string, std::vector<size_t>> members;
    for (size_t i : held) {
        weight[sectors[i]] += b[i];
        members[sectors[i]].push_back(i);
    }
    std::vector<std::pair<double, std::string>> bySize;
    for (auto& [s, w] : weight) bySize.push_back({w, s});
    std::sort(bySize.begin(), bySize.end(), std::greater<>());
    std::map<std::string, size_t> quota;
    size_t used = 0;
    for (auto& [w, s] : bySize) {
        if (used == maxNames) break;
        quota[s] = 1;
        used++;
    }
    while (used < maxNames) {
        // The sector furthest below its proportional share that still has names to add.
        std::string pick;
        double gap = -1e300;
        for (auto& [w, s] : bySize) {
            if (quota[s] >= members[s].size()) continue;
            double g = w * maxNames - static_cast<double>(quota[s]);
            if (g > gap) { gap = g; pick = s; }
        }
        if (pick.empty()) break;
        quota[pick]++;
        used++;
    }
    std::vector<size_t> out;
    for (auto& [s, idx] : members) {
        for (size_t k = 0; k < quota[s]; k++) out.push_back(idx[k]);   // members are already largest first
    }
    return out;
}

Solve minTrackingError(const Matrix& cov, const Vector& b, const std::vector<size_t>& names, double cap) {
    size_t n = b.size();
    Vector sb = times(cov, b);                     // Σb, so ∇ = 2(Σw − Σb) only needs Σ on the selected names
    double lmax = 0;
    {
        Matrix sub(names.size(), Vector(names.size()));
        for (size_t r = 0; r < names.size(); r++)
            for (size_t c = 0; c < names.size(); c++) sub[r][c] = cov[names[r]][names[c]];
        lmax = maxEigenvalue(sub);
    }
    double step = 1 / (2 * lmax);
    Vector start(n, 0.0);
    double covered = 0;
    for (size_t i : names) covered += b[i];
    for (size_t i : names) start[i] = covered > 0 ? b[i] / covered : 1.0 / names.size();
    Vector w = projectOn(start, names, cap), y = w;
    double t = 1;
    for (int it = 1; it <= kMaxIterations; it++) {
        Vector v(n, 0.0);
        for (size_t i : names) {
            double g = 0;
            for (size_t j : names) g += cov[i][j] * y[j];
            v[i] = y[i] - step * 2 * (g - sb[i]);
        }
        Vector next = projectOn(v, names, cap);
        double align = 0, diff = 0;
        for (size_t i : names) {
            align += (y[i] - next[i]) * (next[i] - w[i]);
            diff = std::max(diff, std::abs(next[i] - w[i]));
        }
        if (align > 0) t = 1;                       // adaptive restart
        double tNext = (1 + std::sqrt(1 + 4 * t * t)) / 2;
        for (size_t i : names) y[i] = next[i] + ((t - 1) / tNext) * (next[i] - w[i]);
        w = next;
        t = tNext;
        if (diff < kTolerance) return Solve{w, it, true};
    }
    return Solve{w, kMaxIterations, false};
}

json track(const json& request) {
    auto started = std::chrono::steady_clock::now();
    auto ms = [&] {
        return roundTo(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count(), 1);
    };
    try {
        json req = resolveInputs(request);
        if (!req.contains("assets") || !req["assets"].is_array() || req["assets"].empty())
            throw InvalidRequest("assets must be a non-empty array");
        size_t n = req["assets"].size();
        std::vector<std::string> assets, sectors;
        for (auto& a : req["assets"]) assets.push_back(a.get<std::string>());
        if (req.contains("sectors") && req["sectors"].is_array() && req["sectors"].size() == n)
            for (auto& s : req["sectors"]) sectors.push_back(s.get<std::string>());
        Vector b = vectorField(req, "benchmarkWeights", n);
        double bsum = std::accumulate(b.begin(), b.end(), 0.0);
        if (std::abs(bsum - 1) > 1e-6) throw InvalidRequest("benchmarkWeights must add up to 1");
        if (!req.contains("covariance") || !req["covariance"].is_array() || req["covariance"].size() != n)
            throw InvalidRequest("covariance must be " + std::to_string(n) + " × " + std::to_string(n));
        Matrix cov(n, Vector(n));
        for (size_t i = 0; i < n; i++) {
            if (req["covariance"][i].size() != n) throw InvalidRequest("covariance must be square");
            for (size_t j = 0; j < n; j++) cov[i][j] = req["covariance"][i][j].get<double>();
        }
        Vector current(n, 0.0);
        bool hasCurrent = req.contains("currentWeights") && req["currentWeights"].is_object() &&
                          !req["currentWeights"].empty();
        if (hasCurrent) {
            for (size_t i = 0; i < n; i++)
                if (req["currentWeights"].contains(assets[i])) current[i] = req["currentWeights"][assets[i]].get<double>();
        }
        size_t maxNames = static_cast<size_t>(number(req, "maxNames", 0));
        std::string selection = req.value("selection", std::string("stratified"));
        if (selection != "largest" && selection != "stratified") throw InvalidRequest("selection must be largest or stratified");
        double cap = number(req, "maxWeight", 1.0);
        double budget = number(req, "trackingErrorBudget", 0.01);
        bool hasMaxTurnover = req.contains("maxTurnover") && req["maxTurnover"].is_number();
        double maxTurnover = number(req, "maxTurnover", 1.0);
        if (!(cap > 0 && cap <= 1)) throw InvalidRequest("maxWeight must be in (0, 1]");

        auto names = selectNames(b, sectors, maxNames, selection == "stratified");
        if (cap * names.size() < 1 - 1e-12)
            return json{{"schema", kTrackingSchema}, {"solverStatus", "infeasible"},
                        {"error", "maxWeight × names < 1"},
                        {"decisionContext", {{"recommendation", "rerun_relaxed"}, {"confidence", 0.9},
                                             {"alternatives", {"escalate"}},
                                             {"reason", "Too few names for the weight cap: raise maxNames or maxWeight."}}}};
        Solve s = minTrackingError(cov, b, names, cap);

        Vector act(n), cact(n);
        for (size_t i = 0; i < n; i++) {
            act[i] = s.w[i] - b[i];
            cact[i] = current[i] - b[i];
        }
        double te = std::sqrt(std::max(0.0, quad(act, cov)));
        double currentTe = std::sqrt(std::max(0.0, quad(cact, cov)));
        double covered = 0, turnover = 0;
        for (size_t i : names) covered += b[i];
        for (size_t i = 0; i < n; i++) turnover += std::abs(s.w[i] - current[i]) / 2;

        json weights = json::object();
        std::vector<size_t> byWeight(names);
        std::sort(byWeight.begin(), byWeight.end(), [&](size_t x, size_t y) { return s.w[x] > s.w[y]; });
        size_t held = 0;
        for (size_t i : byWeight)
            if (s.w[i] > 1e-7) {
                weights[assets[i]] = roundTo(s.w[i], 7);
                held++;
            }
        json sectorActive = json::object();
        double worstSector = 0;
        if (!sectors.empty()) {
            std::map<std::string, double> sa;
            for (size_t i = 0; i < n; i++) sa[sectors[i]] += act[i];
            for (auto& [k, v] : sa) {
                sectorActive[k] = roundTo(v, 6);
                worstSector = std::max(worstSector, std::abs(v));
            }
        }
        std::vector<size_t> order(n);
        std::iota(order.begin(), order.end(), 0);
        std::sort(order.begin(), order.end(),
                  [&](size_t x, size_t y) { return std::abs(s.w[x] - current[x]) > std::abs(s.w[y] - current[y]); });
        json trades = json::array();
        for (size_t k = 0; k < std::min<size_t>(20, n); k++) {
            size_t i = order[k];
            double d = s.w[i] - current[i];
            if (std::abs(d) < 1e-6) break;
            trades.push_back({{"asset", assets[i]}, {"side", d > 0 ? "buy" : "sell"}, {"from", roundTo(current[i], 6)},
                              {"to", roundTo(s.w[i], 6)}, {"change", roundTo(d, 6)}});
        }

        std::string status = s.converged ? "optimal" : "max_iterations";
        std::string method = static_cast<long>(names.size()) >= std::count_if(b.begin(), b.end(), [](double x) { return x > 0; })
                                 ? "full_replication"
                                 : (selection == "stratified" ? "sampled_stratified" : "sampled_largest");
        json decision;
        if (status != "optimal") {
            decision = {{"recommendation", "escalate"}, {"confidence", 0.4}, {"alternatives", {"rebalance", "hold"}},
                        {"reason", "The solver did not converge; review before acting."}};
        } else if (te > budget) {
            char r[200];
            std::snprintf(r, sizeof r, "Tracking error %.2f%% is above the %.2f%% budget with %zu names: hold more names.",
                          100 * te, 100 * budget, held);
            decision = {{"recommendation", "rerun_relaxed"}, {"confidence", 0.8}, {"alternatives", {"escalate"}}, {"reason", r}};
        } else if (!hasCurrent) {
            char r[200];
            std::snprintf(r, sizeof r, "Initial index portfolio: %zu names, %.2f%% tracking error, %.1f%% of the benchmark weight.",
                          held, 100 * te, 100 * covered);
            decision = {{"recommendation", "rebalance"}, {"confidence", 0.9}, {"alternatives", {"hold"}}, {"reason", r}};
        } else if (currentTe <= budget && turnover < 0.02) {
            char r[200];
            std::snprintf(r, sizeof r, "Current tracking error %.2f%% is within the %.2f%% budget and turnover would be %.1f%%: no rebalance needed.",
                          100 * currentTe, 100 * budget, 100 * turnover);
            decision = {{"recommendation", "hold"}, {"confidence", 0.9}, {"alternatives", {"rebalance"}}, {"reason", r}};
        } else if (hasMaxTurnover && turnover > maxTurnover) {
            char r[200];
            std::snprintf(r, sizeof r, "Turnover %.1f%% exceeds the %.1f%% limit: rebalance part of the way (current tracking error %.2f%%).",
                          100 * turnover, 100 * maxTurnover, 100 * currentTe);
            decision = {{"recommendation", "rebalance_partially"}, {"confidence", 0.75}, {"alternatives", {"rebalance", "hold"}}, {"reason", r}};
        } else {
            char r[200];
            std::snprintf(r, sizeof r, "Current tracking error %.2f%% → %.2f%% after rebalancing, turnover %.1f%%.",
                          100 * currentTe, 100 * te, 100 * turnover);
            decision = {{"recommendation", "rebalance"}, {"confidence", 0.85}, {"alternatives", {"rebalance_partially", "hold"}}, {"reason", r}};
        }
        json source = json::object();
        for (const char* k : {"portfolio", "benchmark", "asOf", "statistics"})
            if (req.contains(k)) source[k] = req[k];
        return json{{"schema", kTrackingSchema},
                    {"solverStatus", status},
                    {"method", method},
                    {"names", held},
                    {"trackingError", roundTo(te, 6)},
                    {"currentTrackingError", hasCurrent ? json(roundTo(currentTe, 6)) : json(nullptr)},
                    {"benchmarkWeightCovered", roundTo(covered, 6)},
                    {"turnover", hasCurrent ? json(roundTo(turnover, 6)) : json(nullptr)},
                    {"maxSectorActive", sectors.empty() ? json(nullptr) : json(roundTo(worstSector, 6))},
                    {"sectorActiveWeights", sectorActive},
                    {"trades", trades},
                    {"weights", weights},
                    {"inputs", source},
                    {"decisionContext", decision},
                    {"diagnostics", {{"engine", kEngine}, {"assets", n}, {"iterations", s.iterations}, {"ms", ms()}}}};
    } catch (const InvalidRequest& e) {
        return json{{"schema", kTrackingSchema}, {"solverStatus", "invalid_input"}, {"error", e.what()},
                    {"decisionContext", {{"recommendation", "escalate"}, {"confidence", 1.0}, {"alternatives", json::array()},
                                         {"reason", std::string("The request was rejected: ") + e.what()}}}};
    }
}

}  // namespace mxjobs
