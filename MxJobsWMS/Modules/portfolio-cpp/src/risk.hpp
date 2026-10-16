// Portfolio risk report (mxjobs.risk/1): parametric VaR / expected shortfall, risk contributions,
// diversification ratio and concentration for given weights.
#pragma once

#include "optimizer.hpp"

namespace mxjobs {

inline constexpr const char* kRiskSchema = "mxjobs.risk/1";

// Request {assets, weights, covariance, expectedReturns?, confidence?, horizonDays?, portfolioValue?} → report.
// status "invalid_input" means the request was rejected (serve it with HTTP 400).
json risk(const json& request);

// Inverse standard normal CDF (Acklam's rational approximation, |error| < 1.2e-9).
double inverseNormal(double p);

}  // namespace mxjobs
