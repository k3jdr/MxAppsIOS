// Unit tests for portfolio-cpp (no framework: `make test`, or ctest with CMake).
#include <cmath>
#include <cstdio>
#include <string>

#include "optimizer.hpp"
#include "risk.hpp"
#include "tracking.hpp"

using mxjobs::json;

static int failures = 0, checks = 0;

#define CHECK(cond)                                                                 \
    do {                                                                            \
        checks++;                                                                   \
        if (!(cond)) {                                                              \
            failures++;                                                             \
            std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);             \
        }                                                                           \
    } while (0)
#define CHECK_NEAR(a, b, tol) CHECK(std::fabs((a) - (b)) <= (tol))

static json example() {
    return json::parse(R"({
      "assets": ["AAPL", "MSFT", "NVDA", "TLT"],
      "expectedReturns": [0.11, 0.10, 0.16, 0.04],
      "covariance": [[0.0625, 0.0300, 0.0450, -0.0040], [0.0300, 0.0484, 0.0400, -0.0030],
                     [0.0450, 0.0400, 0.1600, -0.0050], [-0.0040, -0.0030, -0.0050, 0.0196]],
      "objective": "max_sharpe", "riskFreeRate": 0.02, "maxWeight": 0.4,
      "currentWeights": {"AAPL": 0.25, "MSFT": 0.25, "NVDA": 0.25, "TLT": 0.25}, "maxTurnover": 0.2})");
}

int main() {
    {  // example: feasible, capped, fully invested; brute force gives Sharpe 0.484807 with TLT at the cap
        json out = mxjobs::optimize(example());
        CHECK(out["schema"] == "mxjobs.optimization/1");
        CHECK(out["solverStatus"] == "optimal");
        double sum = 0;
        for (auto& [k, v] : out["weights"].items()) {
            CHECK(v.get<double>() >= 0 && v.get<double>() <= 0.4 + 1e-9);
            sum += v.get<double>();
        }
        CHECK_NEAR(sum, 1.0, 1e-5);
        CHECK_NEAR(out["sharpe"].get<double>(), 0.484807, 2e-5);
        CHECK_NEAR(out["weights"]["TLT"].get<double>(), 0.4, 1e-4);
        bool capBinding = false;
        for (auto& c : out["bindingConstraints"]) capBinding = capBinding || c == "max_weight";
        CHECK(capBinding);
    }
    {  // min variance, uncorrelated: w ∝ 1/σ² → (0.2, 0.8)
        json r = {{"assets", {"A", "B"}}, {"expectedReturns", {0.1, 0.05}},
                  {"covariance", {{0.04, 0.0}, {0.0, 0.01}}}, {"objective", "min_variance"}};
        json out = mxjobs::optimize(r);
        CHECK_NEAR(out["weights"]["A"].get<double>(), 0.2, 1e-5);
        CHECK_NEAR(out["weights"]["B"].get<double>(), 0.8, 1e-5);
    }
    {  // max Sharpe ≈ tangency (1/3, 2/3), Sharpe √0.5
        json r = {{"assets", {"A", "B"}}, {"expectedReturns", {0.1, 0.05}}, {"covariance", {{0.04, 0.0}, {0.0, 0.01}}}};
        json out = mxjobs::optimize(r);
        CHECK_NEAR(out["sharpe"].get<double>(), std::sqrt(0.5), 1e-4);
        CHECK_NEAR(out["weights"]["A"].get<double>(), 1.0 / 3, 1e-3);
    }
    {  // infeasible cap
        json r = example();
        r["maxWeight"] = 0.2;
        json out = mxjobs::optimize(r);
        CHECK(out["solverStatus"] == "infeasible");
        CHECK(out["decisionContext"]["recommendation"] == "rerun_relaxed");
    }
    {  // hold when already optimal; partial rebalance above maxTurnover
        json first = mxjobs::optimize(example());
        json r = example();
        r["currentWeights"] = first["weights"];
        CHECK(mxjobs::optimize(r)["decisionContext"]["recommendation"] == "hold");
        r["currentWeights"] = {{"TLT", 1.0}};
        r["maxTurnover"] = 0.1;
        CHECK(mxjobs::optimize(r)["decisionContext"]["recommendation"] == "rebalance_partially");
    }
    {  // invalid input
        json out = mxjobs::optimize(json{{"assets", {"A", "B"}}, {"expectedReturns", {0.1}}});
        CHECK(out["solverStatus"] == "invalid_input");
        CHECK(out["decisionContext"]["recommendation"] == "escalate");
    }
    {  // projection stays on the capped simplex
        mxjobs::Vector w = mxjobs::project({5, -3, 0.2, 0.1}, 0.5);
        double sum = 0;
        for (double x : w) {
            CHECK(x >= 0 && x <= 0.5 + 1e-12);
            sum += x;
        }
        CHECK_NEAR(sum, 1.0, 1e-12);
    }
    {  // inverse normal
        CHECK_NEAR(mxjobs::inverseNormal(0.95), 1.6448536, 1e-6);
        CHECK_NEAR(mxjobs::inverseNormal(0.99), 2.3263479, 1e-6);
        CHECK_NEAR(mxjobs::inverseNormal(0.5), 0.0, 1e-9);
    }
    {  // risk: one asset, σ = 20%, 1 day, 95%: VaR = 1.6449 × 0.2 / √252
        json r = {{"assets", {"A"}}, {"weights", {{"A", 1.0}}}, {"covariance", {{0.04}}}};
        json out = mxjobs::risk(r);
        CHECK(out["status"] == "ok");
        CHECK_NEAR(out["valueAtRisk"].get<double>(), 1.6448536 * 0.2 / std::sqrt(252.0), 1e-6);
        CHECK_NEAR(out["riskContributions"]["A"].get<double>(), 1.0, 1e-9);
        CHECK_NEAR(out["diversificationRatio"].get<double>(), 1.0, 1e-9);
    }
    {  // risk: contributions sum to 1, diversification > 1 for a mixed portfolio
        json r = example();
        r["weights"] = {{"AAPL", 0.25}, {"MSFT", 0.25}, {"NVDA", 0.25}, {"TLT", 0.25}};
        json out = mxjobs::risk(r);
        double sum = 0;
        for (auto& [k, v] : out["riskContributions"].items()) sum += v.get<double>();
        CHECK_NEAR(sum, 1.0, 1e-5);
        CHECK(out["diversificationRatio"].get<double>() > 1);
        CHECK(out["expectedShortfall"].get<double>() > out["valueAtRisk"].get<double>());
    }
    {  // tracking: full replication reproduces the benchmark (tracking error 0)
        json r = example();
        r["benchmarkWeights"] = {0.4, 0.3, 0.2, 0.1};
        r["currentWeights"] = json::object();
        json out = mxjobs::track(r);
        CHECK(out["solverStatus"] == "optimal");
        CHECK(out["method"] == "full_replication");
        CHECK_NEAR(out["trackingError"].get<double>(), 0.0, 1e-5);
        CHECK_NEAR(out["weights"]["AAPL"].get<double>(), 0.4, 1e-5);
        CHECK(out["decisionContext"]["recommendation"] == "rebalance");
    }
    {  // tracking: three of four names — weights add up to 1, TE > 0, the dropped name is the smallest
        json r = example();
        r["benchmarkWeights"] = {0.4, 0.3, 0.2, 0.1};
        r["maxNames"] = 3;
        r["selection"] = "largest";
        json out = mxjobs::track(r);
        CHECK(out["method"] == "sampled_largest");
        CHECK(out["names"] == 3);
        CHECK(!out["weights"].contains("TLT"));
        double sum = 0;
        for (auto& [k, v] : out["weights"].items()) sum += v.get<double>();
        CHECK_NEAR(sum, 1.0, 1e-5);
        CHECK(out["trackingError"].get<double>() > 0);
        CHECK_NEAR(out["benchmarkWeightCovered"].get<double>(), 0.9, 1e-9);
    }
    {  // stratified selection keeps every sector
        mxjobs::Vector b = {0.30, 0.25, 0.20, 0.15, 0.10};
        std::vector<std::string> sectors = {"Tech", "Tech", "Tech", "Energy", "Health"};
        auto names = mxjobs::selectNames(b, sectors, 3, true);
        CHECK(names.size() == 3);
        bool energy = false, health = false;
        for (size_t i : names) { energy |= sectors[i] == "Energy"; health |= sectors[i] == "Health"; }
        CHECK(energy && health);
    }
    {  // tracking: a cap too small for the names is infeasible
        json r = example();
        r["benchmarkWeights"] = {0.4, 0.3, 0.2, 0.1};
        r["maxWeight"] = 0.2;
        CHECK(mxjobs::track(r)["solverStatus"] == "infeasible");
    }
    {  // risk against a benchmark: holding the benchmark has no tracking error and beta 1
        json r = example();
        r["weights"] = {{"AAPL", 0.4}, {"MSFT", 0.3}, {"NVDA", 0.2}, {"TLT", 0.1}};
        r["benchmarkWeights"] = {0.4, 0.3, 0.2, 0.1};
        json out = mxjobs::risk(r);
        CHECK_NEAR(out["trackingError"].get<double>(), 0.0, 1e-9);
        CHECK_NEAR(out["beta"].get<double>(), 1.0, 1e-4);
    }
    {  // inputsUrl must point at this Mac
        json r = example();
        r["inputsUrl"] = "http://example.com/inputs/1";
        CHECK(mxjobs::track(r)["solverStatus"] == "invalid_input");
    }
    std::printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
