#!/usr/bin/env python3
"""Checks the running optimization services against the contracts and against each other.

    python3 check_engines.py [--java http://127.0.0.1:8766] [--cpp http://127.0.0.1:8767] [--cases 25]

For the example request and random price-based requests (all objectives, caps, current weights), every
response must validate against optimization.schema.json (a subset of JSON Schema, checked by this script
with the standard library), and the Java and C++ engines must agree within 1e-5 on weights and metrics and
exactly on status, binding constraints and recommendation. /risk responses are checked against risk.schema.json.
"""

import argparse
import json
import os
import random
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    with open(os.path.join(HERE, name)) as f:
        return json.load(f)


def validate(value, schema, path="$"):
    """Validates the JSON Schema keywords these contracts use; returns a list of problems."""
    problems = []
    if "const" in schema and value != schema["const"]:
        problems.append("%s: expected %r, got %r" % (path, schema["const"], value))
    if "enum" in schema and value not in schema["enum"]:
        problems.append("%s: %r not in %r" % (path, value, schema["enum"]))
    types = schema.get("type")
    if types:
        types = [types] if isinstance(types, str) else types
        ok = {
            "object": isinstance(value, dict), "array": isinstance(value, list), "string": isinstance(value, str),
            "integer": isinstance(value, int) and not isinstance(value, bool),
            "number": isinstance(value, (int, float)) and not isinstance(value, bool),
            "boolean": isinstance(value, bool), "null": value is None,
        }
        if not any(ok[t] for t in types):
            return problems + ["%s: expected %s, got %r" % (path, "/".join(types), value)]
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            problems.append("%s: %r < minimum %r" % (path, value, schema["minimum"]))
        if "maximum" in schema and value > schema["maximum"]:
            problems.append("%s: %r > maximum %r" % (path, value, schema["maximum"]))
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                problems.append("%s: missing %s" % (path, key))
        for key, sub in schema.get("properties", {}).items():
            if key in value:
                problems += validate(value[key], sub, path + "." + key)
        extra = schema.get("additionalProperties")
        if isinstance(extra, dict):
            for key, v in value.items():
                if key not in schema.get("properties", {}):
                    problems += validate(v, extra, path + "." + key)
    if isinstance(value, list) and "items" in schema:
        for i, v in enumerate(value):
            problems += validate(v, schema["items"], "%s[%d]" % (path, i))
    return problems


def post(base, path, body):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def random_request(rng):
    n = rng.randint(2, 7)
    assets = ["A%d" % i for i in range(n)]
    prices = {}
    days = rng.randint(30, 260)
    for a in assets:
        p, series = 100.0, []
        drift, vol = rng.uniform(-0.0005, 0.001), rng.uniform(0.005, 0.03)
        for _ in range(days):
            p *= 1 + rng.gauss(drift, vol)
            series.append(round(p, 4))
        prices[a] = series
    req = {"assets": assets, "prices": prices,
           "objective": rng.choice(["max_sharpe", "min_variance", "mean_variance"]),
           "riskAversion": rng.choice([1, 3, 10]), "riskFreeRate": rng.choice([0, 0.02]),
           "maxWeight": rng.choice([1, 0.5, 0.35, round(1.0 / n, 4) if n > 2 else 0.6, 0.15])}
    if rng.random() < 0.7:
        w = [rng.random() for _ in assets]
        req["currentWeights"] = {a: x / sum(w) for a, x in zip(assets, w)}
        req["maxTurnover"] = rng.choice([0.05, 0.2, 0.5])
    return req


def compare(a, b):
    problems = []
    for key in ["solverStatus", "objective", "bindingConstraints"]:
        if a[key] != b[key]:
            problems.append("%s: java %r vs cpp %r" % (key, a[key], b[key]))
    if a["decisionContext"]["recommendation"] != b["decisionContext"]["recommendation"]:
        problems.append("recommendation: java %r vs cpp %r" % (a["decisionContext"]["recommendation"],
                                                                 b["decisionContext"]["recommendation"]))
    for key in ["expectedReturn", "volatility", "sharpe", "turnover"]:
        x, y = a[key], b[key]
        if (x is None) != (y is None) or (x is not None and abs(x - y) > 1e-5):
            problems.append("%s: java %r vs cpp %r" % (key, x, y))
    for k in set(a["weights"]) | set(b["weights"]):
        if abs(a["weights"].get(k, 0) - b["weights"].get(k, 0)) > 1e-5:
            problems.append("weights.%s: java %r vs cpp %r" % (k, a["weights"].get(k), b["weights"].get(k)))
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--java", default="http://127.0.0.1:8766")
    ap.add_argument("--cpp", default="http://127.0.0.1:8767")
    ap.add_argument("--cases", type=int, default=25)
    ap.add_argument("--seed", type=int, default=11)
    args = ap.parse_args()

    schema, risk_schema = load("optimization.schema.json"), load("risk.schema.json")
    rng = random.Random(args.seed)
    cases = [("example", load("examples/optimize-request.json"))]
    cases += [("random %d" % i, random_request(rng)) for i in range(args.cases)]
    failed = 0
    statuses = {}
    for name, req in cases:
        (sj, j), (sc, c) = post(args.java, "/optimize", req), post(args.cpp, "/optimize", req)
        problems = ["java: " + p for p in validate(j, schema)] + ["cpp: " + p for p in validate(c, schema)]
        if sj != sc:
            problems.append("HTTP status: java %d vs cpp %d" % (sj, sc))
        if not problems:
            problems = compare(j, c)
        statuses[j["solverStatus"]] = statuses.get(j["solverStatus"], 0) + 1
        if problems:
            failed += 1
            print("FAIL %s (%s)" % (name, req.get("objective")))
            for p in problems[:8]:
                print("   ", p)
        if name == "example":
            with open(os.path.join(HERE, "examples", "optimization-outcome.json"), "w") as f:
                j["diagnostics"]["ms"] = 0
                json.dump(j, f, indent=2)
                f.write("\n")

    ex = load("examples/optimize-request.json")
    risk_req = dict(ex, weights=ex["currentWeights"], confidence=0.99, horizonDays=10, portfolioValue=1000000)
    s, r = post(args.cpp, "/risk", risk_req)
    risk_problems = validate(r, risk_schema)
    if risk_problems or s != 200:
        failed += 1
        print("FAIL /risk", s, risk_problems)

    print("%d optimize cases (%s), /risk: %s — %s" % (
        len(cases), ", ".join("%s %d" % kv for kv in sorted(statuses.items())),
        "ok" if not risk_problems else "FAIL", "all agree" if not failed else "%d failed" % failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
