// Long-only, capped portfolio optimization — the algorithm of Services/contracts/README.md
// (portfolio-java implements the same one, so both engines agree).
#pragma once

#include <nlohmann/json.hpp>
#include <vector>

namespace mxjobs {

using json = nlohmann::ordered_json;
using Vector = std::vector<double>;
using Matrix = std::vector<Vector>;

inline constexpr const char* kEngine = "portfolio-cpp/1";
inline constexpr const char* kOptimizationSchema = "mxjobs.optimization/1";

struct Solve {
    Vector w;
    int iterations;
    bool converged;
};

// Request (mxjobs.optimize-request/1) → outcome (mxjobs.optimization/1).
// solverStatus "invalid_input" means the request was rejected (serve it with HTTP 400).
json optimize(const json& request);

// Building blocks, exposed for the tests.
Vector project(const Vector& v, double cap);
double maxEigenvalue(const Matrix& m);
Solve meanVariance(const Vector& mu, const Matrix& cov, double lambda, double cap, double lipschitz);

Vector times(const Matrix& m, const Vector& x);
double dot(const Vector& a, const Vector& b);
double quad(const Vector& w, const Matrix& m);
double roundTo(double x, int places);

}  // namespace mxjobs
