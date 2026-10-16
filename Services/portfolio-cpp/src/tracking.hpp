// Passive index tracking (mxjobs.tracking/1): the long-only portfolio of at most maxNames securities with the
// smallest ex-ante tracking error against a benchmark — full replication, or sampling by largest weights or by
// sector strata — and the trades to get there from the current holdings.
#pragma once

#include "optimizer.hpp"

namespace mxjobs {

inline constexpr const char* kTrackingSchema = "mxjobs.tracking/1";

// Request {inputsUrl | assets, sectors?, benchmarkWeights, covariance, currentWeights?,
//          maxNames?, selection? ("largest" | "stratified"), maxWeight?, trackingErrorBudget?, maxTurnover?}.
// solverStatus "invalid_input" means the request was rejected (serve it with HTTP 400).
json track(const json& request);

// Building blocks, exposed for the tests.
std::vector<size_t> selectNames(const Vector& benchmark, const std::vector<std::string>& sectors, size_t maxNames,
                                bool stratified);
Solve minTrackingError(const Matrix& cov, const Vector& benchmark, const std::vector<size_t>& names, double cap);

}  // namespace mxjobs
