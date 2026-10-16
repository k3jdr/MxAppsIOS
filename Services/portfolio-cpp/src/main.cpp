// MxJobsWMS Layer 3 optimization and risk service (C++).
//
//   ./build/portfolio-cpp [--port 8767] [--token TOKEN]
//
//   GET  /health
//   GET  /describe            what the service is for (shown in MxJobsWMS and MxDataHUB)
//   POST /optimize            mxjobs.optimize-request/1 → mxjobs.optimization/1 (absolute max-Sharpe / mean-variance)
//   POST /optimize/tracking   inputs + maxNames         → mxjobs.tracking/1 (passive index tracking)
//   POST /risk                weights + covariance (or inputsUrl) → mxjobs.risk/1, with active risk vs a benchmark
//
// Listens on 127.0.0.1 only. With --token (or MXJOBS_SERVICE_TOKEN) requests need "Authorization: Bearer TOKEN".

#include <httplib.h>

#include <cstdio>
#include <cstdlib>
#include <string>

#include "optimizer.hpp"
#include "risk.hpp"
#include "tracking.hpp"

using mxjobs::json;

namespace {

void send(httplib::Response& res, int status, const json& body) {
    res.status = status;
    res.set_content(body.dump(2), "application/json");
}

json error(const std::string& message) { return json{{"error", message}}; }

}  // namespace

int main(int argc, char** argv) {
    int port = 8767;
    std::string token = std::getenv("MXJOBS_SERVICE_TOKEN") ? std::getenv("MXJOBS_SERVICE_TOKEN") : "";
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--port" && i + 1 < argc) {
            port = std::atoi(argv[++i]);
        } else if (arg == "--token" && i + 1 < argc) {
            token = argv[++i];
        } else {
            std::fprintf(stderr, "usage: portfolio-cpp [--port 8767] [--token TOKEN]\n");
            return 2;
        }
    }

    httplib::Server server;
    server.set_payload_max_length(20'000'000);
    server.set_pre_routing_handler([&](const httplib::Request& req, httplib::Response& res) {
        if (token.empty() || req.get_header_value("Authorization") == "Bearer " + token ||
            req.get_header_value("X-API-Key") == token)
            return httplib::Server::HandlerResponse::Unhandled;
        send(res, 401, error("missing or wrong token"));
        return httplib::Server::HandlerResponse::Handled;
    });

    server.Get("/health", [](const httplib::Request&, httplib::Response& res) {
        send(res, 200, json{{"status", "ok"}, {"service", "portfolio-cpp"}, {"engine", mxjobs::kEngine},
                            {"schemas", {mxjobs::kOptimizationSchema, mxjobs::kRiskSchema}}});
    });

    auto post = [&](const char* path, json (*handler)(const json&), const char* statusKey) {
        server.Post(path, [handler, statusKey](const httplib::Request& req, httplib::Response& res) {
            json body = json::parse(req.body, nullptr, false);
            if (body.is_discarded()) return send(res, 400, error("the body is not valid JSON"));
            json out = handler(body);
            send(res, out[statusKey] == "invalid_input" ? 400 : 200, out);
        });
    };
    server.Get("/describe", [port](const httplib::Request&, httplib::Response& res) {
        send(res, 200, json{
            {"id", "portfolio-cpp"},
            {"name", "Index tracking & risk"},
            {"language", "C++"},
            {"port", port},
            {"version", mxjobs::kEngine},
            {"purpose", "Passive index tracking — the long-only portfolio of at most N names with the smallest ex-ante "
                        "tracking error against a benchmark (full replication or sampling by largest weights or sector "
                        "strata) — and portfolio risk: VaR, expected shortfall, risk contributions, and tracking error, "
                        "beta and active-risk contributions against a benchmark."},
            {"whyThisLanguage", "C++ is for the numerically heavy loops: thousands of iterations over a 500 × 500 "
                                "covariance finish in milliseconds, so tracking portfolios and risk can be recomputed "
                                "for every rebalance, scenario or intraday check."},
            {"useCases", {"passive", "risk", "absolute"}},
            {"endpoints", json::array({
                {{"method", "POST"}, {"path", "/optimize/tracking"}, {"summary", "Minimum tracking error with at most maxNames securities"}, {"contract", mxjobs::kTrackingSchema}},
                {{"method", "POST"}, {"path", "/risk"}, {"summary", "VaR / ES / risk contributions; tracking error and active risk vs a benchmark"}, {"contract", mxjobs::kRiskSchema}},
                {{"method", "POST"}, {"path", "/optimize"}, {"summary", "Absolute max-Sharpe / mean-variance / min-variance"}, {"contract", mxjobs::kOptimizationSchema}}})},
            {"samples", {"passive-tracking", "attribution", "market-refresh"}}});
    });

    post("/optimize", mxjobs::optimize, "solverStatus");
    post("/optimize/tracking", mxjobs::track, "solverStatus");
    post("/risk", mxjobs::risk, "status");

    server.set_error_handler([](const httplib::Request& req, httplib::Response& res) {
        if (res.body.empty()) send(res, res.status, error("no such endpoint: " + req.method + " " + req.path));
    });
    server.set_exception_handler([](const httplib::Request&, httplib::Response& res, std::exception_ptr ep) {
        std::string what = "internal error";
        try {
            std::rethrow_exception(ep);
        } catch (const std::exception& e) {
            what += std::string(": ") + e.what();
        } catch (...) {
        }
        send(res, 500, error(what));
    });

    std::printf("MxJobsWMS portfolio-cpp on http://127.0.0.1:%d%s\n", port, token.empty() ? "" : " (token required)");
    std::fflush(stdout);
    if (!server.listen("127.0.0.1", port)) {
        std::fprintf(stderr, "could not listen on 127.0.0.1:%d\n", port);
        return 1;
    }
    return 0;
}
