package com.k3jdr.mxjobs.portfolio;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Long-only portfolio optimization with a per-asset cap, as specified in Services/contracts/README.md
 * (portfolio-cpp implements the same algorithm, so both engines agree).
 */
public final class Optimizer {
    public static final String ENGINE = "portfolio-java/1";
    public static final String SCHEMA = "mxjobs.optimization/1";

    static final int MAX_ITERATIONS = 20_000;
    static final double TOLERANCE = 1e-10;
    static final int SHARPE_GRID = 80;
    static final int GOLDEN_STEPS = 30;

    static double gridExponent(int k) {
        return -2 + 5.0 * k / (SHARPE_GRID - 1);
    }

    static double sharpe(double[] w, double[] mu, double[][] cov, double rf) {
        double vol = Math.sqrt(quad(w, cov));
        return vol > 0 ? (dot(mu, w) - rf) / vol : Double.NEGATIVE_INFINITY;
    }

    private Optimizer() {}

    /** Raised for requests the service rejects (HTTP 400, solverStatus invalid_input). */
    public static final class InvalidInput extends RuntimeException {
        InvalidInput(String message) {
            super(message);
        }
    }

    /** One mean-variance solve. */
    record Solve(double[] w, int iterations, boolean converged) {}

    // ------------------------------------------------------------------ request → outcome

    /** Optimizes a request (see optimize-request.schema.json) into an mxjobs.optimization/1 outcome. */
    public static Map<String, Object> optimize(Map<String, Object> req) {
        long started = System.nanoTime();
        String objective = "max_sharpe";
        try {
            List<String> assets = assets(req.get("assets"));
            int n = assets.size();
            double[] mu;
            double[][] cov;
            if (req.get("expectedReturns") != null || req.get("covariance") != null) {
                mu = vector(req.get("expectedReturns"), n, "expectedReturns");
                cov = matrix(req.get("covariance"), n);
            } else if (req.get("prices") instanceof Map<?, ?> prices) {
                double[][] est = estimate(assets, prices);
                mu = est[0];
                cov = new double[n][];
                System.arraycopy(est, 1, cov, 0, n);
            } else {
                throw new InvalidInput("send expectedReturns and covariance, or prices");
            }
            objective = text(req.get("objective"), "max_sharpe");
            if (!objective.equals("max_sharpe") && !objective.equals("min_variance") && !objective.equals("mean_variance")) {
                throw new InvalidInput("objective must be max_sharpe, min_variance or mean_variance");
            }
            double riskAversion = number(req.get("riskAversion"), 3, "riskAversion");
            if (!(riskAversion > 0)) throw new InvalidInput("riskAversion must be > 0");
            double rf = number(req.get("riskFreeRate"), 0, "riskFreeRate");
            double cap = number(req.get("maxWeight"), 1, "maxWeight");
            if (!(cap > 0 && cap <= 1)) throw new InvalidInput("maxWeight must be in (0, 1]");
            Map<String, Double> current = weightsMap(req.get("currentWeights"));
            Double maxTurnover = req.get("maxTurnover") == null ? null : number(req.get("maxTurnover"), 0, "maxTurnover");

            if (cap * n < 1 - 1e-12) {
                return infeasible(objective, started,
                        String.format("maxWeight %.4g × %d assets < 1: no fully invested portfolio fits the cap", cap, n));
            }

            double lipschitz = maxEigenvalue(cov);
            Solve best;
            int iterations;
            boolean converged;
            switch (objective) {
                case "min_variance" -> {
                    best = meanVariance(new double[n], cov, 1, cap, lipschitz);
                    iterations = best.iterations();
                    converged = best.converged();
                }
                case "mean_variance" -> {
                    best = meanVariance(mu, cov, riskAversion, cap, lipschitz);
                    iterations = best.iterations();
                    converged = best.converged();
                }
                default -> {
                    // Grid over λ, then golden-section refinement of log10 λ around the best grid point.
                    best = null;
                    double bestSharpe = Double.NEGATIVE_INFINITY;
                    int bestK = 0;
                    iterations = 0;
                    converged = true;
                    for (int k = 0; k < SHARPE_GRID; k++) {
                        Solve s = meanVariance(mu, cov, Math.pow(10, gridExponent(k)), cap, lipschitz);
                        iterations += s.iterations();
                        converged &= s.converged();
                        double sharpe = sharpe(s.w(), mu, cov, rf);
                        if (best == null || sharpe > bestSharpe) {
                            best = s;
                            bestSharpe = sharpe;
                            bestK = k;
                        }
                    }
                    double a = gridExponent(Math.max(bestK - 1, 0));
                    double b = gridExponent(Math.min(bestK + 1, SHARPE_GRID - 1));
                    final double phi = (Math.sqrt(5) - 1) / 2;
                    for (int g = 0; g < GOLDEN_STEPS; g++) {
                        double x1 = b - phi * (b - a), x2 = a + phi * (b - a);
                        Solve s1 = meanVariance(mu, cov, Math.pow(10, x1), cap, lipschitz);
                        Solve s2 = meanVariance(mu, cov, Math.pow(10, x2), cap, lipschitz);
                        iterations += s1.iterations() + s2.iterations();
                        converged &= s1.converged() && s2.converged();
                        double f1 = sharpe(s1.w(), mu, cov, rf), f2 = sharpe(s2.w(), mu, cov, rf);
                        if (f1 > bestSharpe) { best = s1; bestSharpe = f1; }
                        if (f2 > bestSharpe) { best = s2; bestSharpe = f2; }
                        if (f1 >= f2) b = x2; else a = x1;
                    }
                }
            }

            double[] w = best.w();
            double ret = dot(mu, w);
            double vol = Math.sqrt(quad(w, cov));
            Double sharpe = vol > 0 ? (ret - rf) / vol : null;

            Map<String, Object> weights = new LinkedHashMap<>();
            for (int i = 0; i < n; i++) weights.put(assets.get(i), round(w[i], 6));

            Double turnover = null;
            if (current != null) {
                Set<String> all = new LinkedHashSet<>(assets);
                all.addAll(current.keySet());
                double sum = 0;
                for (String a : all) {
                    int i = assets.indexOf(a);
                    sum += Math.abs((i >= 0 ? w[i] : 0) - current.getOrDefault(a, 0.0));
                }
                turnover = round(sum / 2, 6);
            }

            List<Object> binding = new ArrayList<>();
            boolean atCap = false, atZero = false;
            for (double x : w) {
                if (cap < 1 && x >= cap - 1e-6) atCap = true;
                if (x <= 1e-6) atZero = true;
            }
            if (atCap) binding.add("max_weight");
            if (atZero) binding.add("long_only");
            if (maxTurnover != null && turnover != null && turnover > maxTurnover) binding.add("max_turnover");

            String status = converged ? "optimal" : "max_iterations";
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("schema", SCHEMA);
            out.put("solverStatus", status);
            out.put("objective", objective);
            out.put("weights", weights);
            out.put("expectedReturn", ret);
            out.put("volatility", vol);
            out.put("sharpe", sharpe);
            out.put("bindingConstraints", binding);
            out.put("turnover", turnover);
            out.put("diagnostics", diagnostics(iterations, started, null));
            out.put("decisionContext", decision(status, sharpe, turnover, maxTurnover, null));
            return out;
        } catch (InvalidInput e) {
            Map<String, Object> out = empty("invalid_input", objective);
            out.put("diagnostics", diagnostics(0, started, e.getMessage()));
            out.put("decisionContext", decision("invalid_input", null, null, null, e.getMessage()));
            return out;
        }
    }

    private static Map<String, Object> infeasible(String objective, long started, String message) {
        Map<String, Object> out = empty("infeasible", objective);
        out.put("diagnostics", diagnostics(0, started, message));
        out.put("decisionContext", decision("infeasible", null, null, null, message));
        return out;
    }

    private static Map<String, Object> empty(String status, String objective) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("schema", SCHEMA);
        out.put("solverStatus", status);
        out.put("objective", objective);
        out.put("weights", new LinkedHashMap<>());
        out.put("expectedReturn", null);
        out.put("volatility", null);
        out.put("sharpe", null);
        out.put("bindingConstraints", new ArrayList<>());
        out.put("turnover", null);
        return out;
    }

    private static Map<String, Object> diagnostics(int iterations, long started, String message) {
        Map<String, Object> d = new LinkedHashMap<>();
        d.put("engine", ENGINE);
        d.put("iterations", (double) iterations);
        d.put("ms", round((System.nanoTime() - started) / 1e6, 3));
        if (message != null) d.put("message", message);
        return d;
    }

    /** The decisionContext rules of the contract. */
    static Map<String, Object> decision(String status, Double sharpe, Double turnover, Double maxTurnover, String message) {
        String recommendation;
        double confidence;
        List<Object> alternatives;
        String reason;
        double c = round(Math.min(0.95, Math.max(0.05, 0.5 + 0.4 * Math.tanh(sharpe == null ? 0 : sharpe))), 4);
        switch (status) {
            case "invalid_input" -> {
                recommendation = "escalate"; confidence = 1.0; alternatives = List.of();
                reason = "The request was rejected: " + message;
            }
            case "infeasible" -> {
                recommendation = "rerun_relaxed"; confidence = 0.9; alternatives = List.of("escalate");
                reason = "The constraints cannot be met; relax them and rerun. " + message;
            }
            case "max_iterations" -> {
                recommendation = "escalate"; confidence = 0.4; alternatives = List.of("rebalance", "hold");
                reason = "The solver did not converge; review before acting.";
            }
            default -> {
                if (turnover == null) {
                    recommendation = "rebalance"; confidence = c; alternatives = List.of("hold");
                    reason = "No current weights: this is an initial allocation.";
                } else if (turnover < 0.02) {
                    recommendation = "hold"; confidence = 0.9; alternatives = List.of("rebalance");
                    reason = String.format("Turnover %.4f is below 0.02: the portfolio is already close to optimal.", turnover);
                } else if (maxTurnover != null && turnover > maxTurnover) {
                    recommendation = "rebalance_partially"; confidence = c; alternatives = List.of("rebalance", "hold");
                    reason = String.format("Turnover %.4f exceeds the maximum %.4f: move part of the way.", turnover, maxTurnover);
                } else {
                    recommendation = "rebalance"; confidence = c; alternatives = List.of("rebalance_partially", "hold");
                    reason = String.format("Turnover %.4f is within limits.", turnover);
                }
            }
        }
        Map<String, Object> d = new LinkedHashMap<>();
        d.put("recommendation", recommendation);
        d.put("confidence", confidence);
        d.put("alternatives", alternatives);
        d.put("reason", reason);
        return d;
    }

    // ------------------------------------------------------------------ math

    /** Maximises μᵀw − λ/2 wᵀΣw over the capped simplex by projected gradient ascent. */
    static Solve meanVariance(double[] mu, double[][] cov, double lambda, double cap, double lipschitz) {
        int n = mu.length;
        double[] w = new double[n];
        java.util.Arrays.fill(w, 1.0 / n);
        w = project(w, cap);
        double step = 1 / (lambda * lipschitz);
        for (int it = 1; it <= MAX_ITERATIONS; it++) {
            double[] sw = times(cov, w);
            double[] v = new double[n];
            for (int i = 0; i < n; i++) v[i] = w[i] + step * (mu[i] - lambda * sw[i]);
            double[] next = project(v, cap);
            double diff = 0;
            for (int i = 0; i < n; i++) diff = Math.max(diff, Math.abs(next[i] - w[i]));
            w = next;
            if (diff < TOLERANCE) return new Solve(w, it, true);
        }
        return new Solve(w, MAX_ITERATIONS, false);
    }

    /** Euclidean projection onto {w ≥ 0, Σw = 1, w ≤ cap}: wᵢ = clip(vᵢ − τ, 0, cap). */
    static double[] project(double[] v, double cap) {
        double lo = Double.POSITIVE_INFINITY, hi = Double.NEGATIVE_INFINITY;
        for (double x : v) {
            lo = Math.min(lo, x);
            hi = Math.max(hi, x);
        }
        lo -= 1;
        for (int k = 0; k < 100; k++) {
            double mid = (lo + hi) / 2;
            double sum = 0;
            for (double x : v) sum += Math.min(cap, Math.max(0, x - mid));
            if (sum > 1) lo = mid; else hi = mid;
        }
        double tau = (lo + hi) / 2;
        double[] w = new double[v.length];
        for (int i = 0; i < v.length; i++) w[i] = Math.min(cap, Math.max(0, v[i] - tau));
        return w;
    }

    /** Largest eigenvalue of a symmetric PSD matrix: 60 power iterations from the ones vector. */
    static double maxEigenvalue(double[][] m) {
        int n = m.length;
        double[] x = new double[n];
        java.util.Arrays.fill(x, 1.0);
        for (int k = 0; k < 60; k++) {
            double[] y = times(m, x);
            double norm = Math.sqrt(dot(y, y));
            if (norm == 0) return 1e-12;
            for (int i = 0; i < n; i++) x[i] = y[i] / norm;
        }
        return Math.max(quad(x, m), 1e-12);
    }

    /** Annualised mean returns and covariance from daily closes. Row 0 = μ, rows 1… = Σ. */
    static double[][] estimate(List<String> assets, Map<?, ?> prices) {
        int n = assets.size();
        double[][] returns = new double[n][];
        int length = -1;
        for (int a = 0; a < n; a++) {
            Object series = prices.get(assets.get(a));
            if (!(series instanceof List<?> list)) throw new InvalidInput("prices for " + assets.get(a) + " are missing");
            if (length < 0) length = list.size();
            if (list.size() != length) throw new InvalidInput("all price series must have the same length");
            if (length < 3) throw new InvalidInput("need at least 3 prices per asset");
            double[] p = vector(list, length, "prices." + assets.get(a));
            returns[a] = new double[length - 1];
            for (int t = 1; t < length; t++) {
                if (!(p[t - 1] > 0)) throw new InvalidInput("prices must be positive");
                returns[a][t - 1] = p[t] / p[t - 1] - 1;
            }
        }
        int m = length - 1;
        double[] mean = new double[n];
        for (int a = 0; a < n; a++) {
            double s = 0;
            for (double r : returns[a]) s += r;
            mean[a] = s / m;
        }
        double[][] out = new double[n + 1][n];
        for (int a = 0; a < n; a++) out[0][a] = mean[a] * 252;
        for (int a = 0; a < n; a++) {
            for (int b = 0; b < n; b++) {
                double s = 0;
                for (int t = 0; t < m; t++) s += (returns[a][t] - mean[a]) * (returns[b][t] - mean[b]);
                out[a + 1][b] = s / (m - 1) * 252;
            }
        }
        return out;
    }

    static double[] times(double[][] m, double[] x) {
        double[] y = new double[x.length];
        for (int i = 0; i < x.length; i++) {
            double s = 0;
            for (int j = 0; j < x.length; j++) s += m[i][j] * x[j];
            y[i] = s;
        }
        return y;
    }

    static double dot(double[] a, double[] b) {
        double s = 0;
        for (int i = 0; i < a.length; i++) s += a[i] * b[i];
        return s;
    }

    static double quad(double[] w, double[][] m) {
        return dot(w, times(m, w));
    }

    static double round(double x, int places) {
        double f = Math.pow(10, places);
        return Math.round(x * f) / f;
    }

    // ------------------------------------------------------------------ input

    private static List<String> assets(Object o) {
        if (!(o instanceof List<?> list) || list.isEmpty()) throw new InvalidInput("assets must be a non-empty array of names");
        List<String> names = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (Object x : list) {
            if (!(x instanceof String s) || s.isBlank()) throw new InvalidInput("asset names must be non-empty strings");
            if (!seen.add(s)) throw new InvalidInput("duplicate asset " + s);
            names.add(s);
        }
        return names;
    }

    private static double[] vector(Object o, int n, String name) {
        if (!(o instanceof List<?> list) || list.size() != n) throw new InvalidInput(name + " must be an array of " + n + " numbers");
        double[] v = new double[n];
        for (int i = 0; i < n; i++) v[i] = number(list.get(i), Double.NaN, name);
        return v;
    }

    private static double[][] matrix(Object o, int n) {
        if (!(o instanceof List<?> rows) || rows.size() != n) throw new InvalidInput("covariance must be " + n + " × " + n);
        double[][] m = new double[n][];
        for (int i = 0; i < n; i++) m[i] = vector(rows.get(i), n, "covariance row " + (i + 1));
        for (int i = 0; i < n; i++) {
            if (m[i][i] < 0) throw new InvalidInput("covariance diagonal must be ≥ 0");
            for (int j = 0; j < i; j++) {
                if (Math.abs(m[i][j] - m[j][i]) > 1e-9) throw new InvalidInput("covariance must be symmetric");
            }
        }
        return m;
    }

    private static Map<String, Double> weightsMap(Object o) {
        if (o == null) return null;
        if (!(o instanceof Map<?, ?> map)) throw new InvalidInput("currentWeights must be an object of asset → weight");
        Map<String, Double> w = new LinkedHashMap<>();
        for (Map.Entry<?, ?> e : map.entrySet()) w.put(String.valueOf(e.getKey()), number(e.getValue(), Double.NaN, "currentWeights"));
        return w;
    }

    private static double number(Object o, double fallback, String name) {
        if (o == null && !Double.isNaN(fallback)) return fallback;
        if (o instanceof Number x && Double.isFinite(x.doubleValue())) return x.doubleValue();
        if (o instanceof String s) {
            try {
                return Double.parseDouble(s.trim());
            } catch (NumberFormatException e) {
                // fall through
            }
        }
        throw new InvalidInput(name + " must be a number");
    }

    private static String text(Object o, String fallback) {
        return o instanceof String s && !s.isBlank() ? s : fallback;
    }
}
