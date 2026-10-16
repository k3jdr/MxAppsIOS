#include "inputs.hpp"

#include <httplib.h>

namespace mxjobs {

std::string fetchLocal(const std::string& url) {
    const std::string prefixes[] = {"http://127.0.0.1:", "http://localhost:"};
    std::string rest;
    for (const auto& p : prefixes) {
        if (url.rfind(p, 0) == 0) rest = url.substr(p.size());
    }
    if (rest.empty()) throw InvalidRequest("inputsUrl must be http://127.0.0.1:… (a service on this Mac)");
    size_t slash = rest.find('/');
    int port = 0;
    try {
        port = std::stoi(rest.substr(0, slash));
    } catch (...) {
        throw InvalidRequest("inputsUrl has no port: " + url);
    }
    std::string path = slash == std::string::npos ? "/" : rest.substr(slash);
    httplib::Client client("127.0.0.1", port);
    client.set_connection_timeout(5);
    client.set_read_timeout(60);
    auto res = client.Get(path);
    if (!res) throw InvalidRequest("could not fetch inputsUrl (is the analytics service running?): " + url);
    if (res->status != 200) {
        throw InvalidRequest("inputsUrl answered HTTP " + std::to_string(res->status) + ": " + res->body.substr(0, 200));
    }
    return res->body;
}

json resolveInputs(const json& request) {
    if (!request.is_object()) throw InvalidRequest("the body must be a JSON object");
    if (!request.contains("inputsUrl") || !request["inputsUrl"].is_string() ||
        request["inputsUrl"].get<std::string>().empty())
        return request;
    json merged = json::parse(fetchLocal(request["inputsUrl"].get<std::string>()), nullptr, false);
    if (merged.is_discarded() || !merged.is_object()) throw InvalidRequest("inputsUrl did not return a JSON object");
    for (auto it = request.begin(); it != request.end(); ++it) {
        if (it.key() != "inputsUrl") merged[it.key()] = it.value();
    }
    return merged;
}

}  // namespace mxjobs
