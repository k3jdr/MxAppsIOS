// Optimization inputs (mxjobs.inputs/1): inline in a request, or fetched from the analytics service by
// "inputsUrl" (http://127.0.0.1:…) so a 500-name covariance never passes through the workflow.
#pragma once

#include <stdexcept>
#include <string>

#include "optimizer.hpp"

namespace mxjobs {

struct InvalidRequest : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// The request merged over the inputs at its inputsUrl (request fields win); the request itself without one.
json resolveInputs(const json& request);

// GET from a service on this Mac (127.0.0.1 / localhost only).
std::string fetchLocal(const std::string& url);

}  // namespace mxjobs
