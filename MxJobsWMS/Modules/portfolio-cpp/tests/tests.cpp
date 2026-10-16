// Unit tests for portfolio-cpp (no framework: `make test`, or ctest with CMake).
#include <cmath>
#include <cstdio>
#include <string>

#include "optimizer.hpp"
#include "risk.hpp"

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
    std::printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
