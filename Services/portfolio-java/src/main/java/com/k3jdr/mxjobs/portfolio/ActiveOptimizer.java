package com.k3jdr.mxjobs.portfolio;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * Active (benchmark-relative) portfolio construction — mxjobs.active-request/1 → mxjobs.active-optimization/1.
 *
 * <p>Maximises αᵀw − λ/2 · (w − b)ᵀΣ(w − b) − ρ/2 · Σₛ max(0, |aₛ| − m)², the information-ratio form of
 * mean-variance used by active managers: α is the alpha forecast, b the benchmark weights, aₛ the active weight
 * of sector s and m the sector band. Feasible set: long-only, fully invested, wᵢ ≤ maxWeight and
 * |wᵢ − bᵢ| ≤ maxActiveWeight (a box), handled exactly by projection; the sector bands are a penalty
 * (ρ = 200 · λ̄), so they hold to within a few basis points. With {@code trackingErrorTarget} λ is chosen by
 * bisection on log λ so that the ex-ante tracking error meets the target.
 *
 * <p>Solver: accelerated projected gradient (FISTA) with step 1/L, L = λ·λmax(Σ) + ρ·(largest sector size).
 */
final class ActiveOptimizer {
    static final String SCHEMA = "mxjobs.active-optimization/1";
    private static final int MAX_ITERATIONS = 20_000;
    private static final double TOLERANCE = 1e-8;

    private ActiveOptimizer() {
    }

    static Map<String, Object> optimize(Map<String, Object> req) {
        long started = System.nanoTime();
        Inputs in;
        try {
            in = Inputs.from(req);
        } catch (Optimizer.InvalidInput e) {
            return invalid(started, e.getMessage());
        }
        int n = in.assets.size();
        double cap = Inputs.number(req, "maxWeight", 0.05);
        double maxActive = Inputs.number(req, "maxActiveWeight", 0.03);
        Double sectorBand = Inputs.optionalNumber(req, "maxSectorActive");
        Double teTarget = Inputs.optionalNumber(req, "trackingErrorTarget");
        Double maxTurnover = Inputs.optionalNumber(req, "maxTurnover");
        double lambda = Inputs.number(req, "riskAversion", 10);
        if (cap <= 0 || cap > 1 || maxActive <= 0 || lambda <= 0) {
            return invalid(started, "maxWeight must be in (0, 1], maxActiveWeight and riskAversion positive");
        }
        double bsum = Arrays.stream(in.benchmark).sum();
        if (Math.abs(bsum - 1) > 1e-6) return invalid(started, "benchmarkWeights must add up to 1 (they add up to " + bsum + ")");

        double[] lo = new double[n], hi = new double[n];
        double sumLo = 0, sumHi = 0;
        for (int i = 0; i < n; i++) {
            lo[i] = Math.max(0, in.benchmark[i] - maxActive);
            hi[i] = Math.min(cap, in.benchmark[i] + maxActive);
            if (hi[i] < lo[i]) hi[i] = lo[i];          // a benchmark weight above the cap: hold at least b − d
            sumLo += lo[i];
            sumHi += hi[i];
        }
        if (sumLo > 1 + 1e-12 || sumHi < 1 - 1e-12) {
            return infeasible(started, String.format("bounds add up to [%.4f, %.4f], which excludes 1: relax maxWeight or maxActiveWeight", sumLo, sumHi));
        }

        int[] sectorOf = new int[n];
        List<String> sectorNames = new ArrayList<>();
        int largestSector = 1;
        if (in.sectors != null) {
            Map<String, Integer> idx = new TreeMap<>();
            for (String s : in.sectors) idx.putIfAbsent(s, 0);
            int k = 0;
            for (String s : idx.keySet()) idx.put(s, k++);
            sectorNames.addAll(idx.keySet());
            int[] sizes = new int[sectorNames.size()];
            for (int i = 0; i < n; i++) {
                sectorOf[i] = idx.get(in.sectors.get(i));
                sizes[sectorOf[i]]++;
            }
            largestSector = Arrays.stream(sizes).max().orElse(1);
        }
        boolean useBands = sectorBand != null && in.sectors != null;
        double lmax = Optimizer.maxEigenvalue(in.cov);
        Problem p = new Problem(in, lo, hi, useBands ? sectorBand : Double.NaN, sectorOf, sectorNames.size(), lmax, largestSector);

        Solve s;
        int solves = 1;
        long totalIterations = 0;
        if (teTarget != null) {
            // TE falls as λ rises: 14 warm-started bisection steps on log10 λ in [−1, 3] (λ to within 0.07%).
            double a = -1, b = 3;
            Solve best = null;
            double[] warm = null;
            for (int k = 0; k < 14; k++) {
                double mid = (a + b) / 2;
                Solve t = p.solve(Math.pow(10, mid), warm);
                warm = t.w;
                solves++;
                totalIterations += t.iterations;
                double te = Math.sqrt(Optimizer.quad(diff(t.w, in.benchmark), in.cov));
                if (te > teTarget) a = mid; else { b = mid; best = t; }
            }
            s = best != null ? best : p.solve(Math.pow(10, b), warm);
            lambda = s.lambda;
        } else {
            s = p.solve(lambda, null);
        }
        totalIterations += s.iterations;

        // ------------------------------------------------------------------ outcome
        double[] w = s.w;
        double[] act = diff(w, in.benchmark);
        double te = Math.sqrt(Math.max(0, Optimizer.quad(act, in.cov)));
        double activeAlpha = Optimizer.dot(in.alpha, act);
        double activeShare = 0;
        for (double x : act) activeShare += Math.abs(x) / 2;
        Double turnover = null;
        if (in.hasCurrent) {
            double t = 0;
            for (int i = 0; i < n; i++) t += Math.abs(w[i] - in.current[i]) / 2;
            turnover = t;
        }
        int held = 0;
        Map<String, Object> weights = new LinkedHashMap<>();
        Integer[] order = new Integer[n];
        for (int i = 0; i < n; i++) order[i] = i;
        Arrays.sort(order, Comparator.comparingDouble(i -> -w[i]));
        for (int i : order) {
            if (w[i] > 1e-6) {
                weights.put(in.assets.get(i), Optimizer.round(w[i], 6));
                held++;
            }
        }
        Map<String, Object> sectorActive = new LinkedHashMap<>();
        double worstBand = 0;
        if (in.sectors != null) {
            double[] a = sectorSums(act, sectorOf, sectorNames.size());
            for (int k = 0; k < a.length; k++) {
                sectorActive.put(sectorNames.get(k), Optimizer.round(a[k], 6));
                worstBand = Math.max(worstBand, Math.abs(a[k]));
            }
        }
        List<Object> binding = new ArrayList<>();
        boolean capBinds = false, activeBinds = false;
        for (int i = 0; i < n; i++) {
            if (w[i] >= cap - 1e-6 && cap < 1) capBinds = true;
            if (Math.abs(act[i]) >= maxActive - 1e-6) activeBinds = true;
        }
        if (capBinds) binding.add("max_weight");
        if (activeBinds) binding.add("max_active_weight");
        if (useBands && worstBand >= sectorBand - 5e-4) binding.add("max_sector_active");
        if (teTarget != null && te >= teTarget - 1e-4) binding.add("tracking_error_target");
        if (maxTurnover != null && turnover != null && turnover > maxTurnover) binding.add("max_turnover");

        String status = s.converged ? "optimal" : "max_iterations";
        double ir = te > 1e-9 ? activeAlpha / te : 0;

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("schema", SCHEMA);
        out.put("solverStatus", status);
        out.put("objective", "active_mean_variance");
        out.put("riskAversion", Optimizer.round(lambda, 6));
        out.put("activeAlpha", Optimizer.round(activeAlpha, 6));
        out.put("trackingError", Optimizer.round(te, 6));
        out.put("informationRatio", Optimizer.round(ir, 4));
        out.put("activeShare", Optimizer.round(activeShare, 6));
        out.put("holdings", (double) held);
        out.put("turnover", turnover == null ? null : Optimizer.round(turnover, 6));
        out.put("bindingConstraints", binding);
        out.put("sectorActiveWeights", sectorActive);
        out.put("maxSectorActive", in.sectors == null ? null : Optimizer.round(worstBand, 6));
        out.put("topActiveWeights", ranked(in, act, true));
        out.put("bottomActiveWeights", ranked(in, act, false));
        out.put("trades", trades(in, w));
        out.put("weights", weights);
        out.put("inputs", in.source);
        out.put("decisionContext", decision(status, ir, te, teTarget, turnover, maxTurnover, worstBand, sectorBand));
        Map<String, Object> d = new LinkedHashMap<>();
        d.put("engine", Optimizer.ENGINE);
        d.put("assets", (double) n);
        d.put("iterations", (double) totalIterations);
        d.put("solves", (double) solves);
        d.put("ms", Optimizer.round((System.nanoTime() - started) / 1e6, 1));
        out.put("diagnostics", d);
        return out;
    }

    /** The decisionContext of an active rebalance. */
    static Map<String, Object> decision(String status, double ir, double te, Double teTarget, Double turnover,
                                       Double maxTurnover, double worstBand, Double band) {
        String rec;
        double conf = Optimizer.round(Math.min(0.95, Math.max(0.05, 0.5 + 0.4 * Math.tanh(ir))), 4);
        List<Object> alt;
        String reason;
        if (!status.equals("optimal")) {
            rec = "escalate"; conf = 0.4; alt = List.of("rebalance", "hold");
            reason = "The solver did not converge; review before acting.";
        } else if (band != null && worstBand > band + 0.002) {
            rec = "rerun_relaxed"; conf = 0.7; alt = List.of("escalate");
            reason = String.format("A sector is %.2f%% active, beyond the %.2f%% band: widen the band or the active-weight limit.", 100 * worstBand, 100 * band);
        } else if (teTarget != null && te > teTarget * 1.05) {
            rec = "rerun_relaxed"; conf = 0.7; alt = List.of("escalate");
            reason = String.format("Tracking error %.2f%% cannot be brought down to %.2f%% within the limits.", 100 * te, 100 * teTarget);
        } else if (turnover == null) {
            rec = "rebalance"; alt = List.of("hold");
            reason = String.format("Initial active portfolio: information ratio %.2f at %.2f%% tracking error.", ir, 100 * te);
        } else if (turnover < 0.02) {
            rec = "hold"; conf = 0.9; alt = List.of("rebalance");
            reason = String.format("Turnover %.2f%% is below 2%%: already close to the optimal active portfolio.", 100 * turnover);
        } else if (maxTurnover != null && turnover > maxTurnover) {
            rec = "rebalance_partially"; alt = List.of("rebalance", "hold");
            reason = String.format("Turnover %.1f%% exceeds the %.1f%% limit: trade part of the way this period.", 100 * turnover, 100 * maxTurnover);
        } else {
            rec = "rebalance"; alt = List.of("rebalance_partially", "hold");
            reason = String.format("Information ratio %.2f at %.2f%% tracking error, turnover %.1f%% within limits.", ir, 100 * te, 100 * turnover);
        }
        Map<String, Object> d = new LinkedHashMap<>();
        d.put("recommendation", rec);
        d.put("confidence", conf);
        d.put("alternatives", alt);
        d.put("reason", reason);
        return d;
    }

    // ------------------------------------------------------------------ solver

    record Solve(double[] w, int iterations, boolean converged, double lambda) {
    }

    private static final class Problem {
        final Inputs in;
        final double[] lo, hi;
        final double band;
        final int[] sectorOf;
        final int sectors;
        final double lmax;
        final int largest;

        Problem(Inputs in, double[] lo, double[] hi, double band, int[] sectorOf, int sectors, double lmax, int largest) {
            this.in = in;
            this.lo = lo;
            this.hi = hi;
            this.band = band;
            this.sectorOf = sectorOf;
            this.sectors = sectors;
            this.lmax = lmax;
            this.largest = largest;
        }

        Solve solve(double lambda, double[] warm) {
            int n = lo.length;
            double rho = Double.isNaN(band) ? 0 : 200 * Math.max(lambda, 1);
            double step = 1 / (lambda * lmax + rho * largest);
            double[] w = project(warm != null ? warm.clone() : in.benchmark.clone());
            double[] y = w.clone();
            double t = 1;
            for (int it = 1; it <= MAX_ITERATIONS; it++) {
                double[] g = gradient(y, lambda, rho);
                double[] v = new double[n];
                for (int i = 0; i < n; i++) v[i] = y[i] + step * g[i];
                double[] next = project(v);
                // Adaptive restart (O'Donoghue & Candès): drop the momentum when it points against the step.
                double align = 0;
                for (int i = 0; i < n; i++) align += (y[i] - next[i]) * (next[i] - w[i]);
                if (align > 0) t = 1;
                double tNext = (1 + Math.sqrt(1 + 4 * t * t)) / 2;
                double diff = 0;
                for (int i = 0; i < n; i++) {
                    diff = Math.max(diff, Math.abs(next[i] - w[i]));
                    y[i] = next[i] + ((t - 1) / tNext) * (next[i] - w[i]);
                }
                w = next;
                t = tNext;
                if (diff < TOLERANCE) return new Solve(w, it, true, lambda);
            }
            return new Solve(w, MAX_ITERATIONS, false, lambda);
        }

        /** ∇ of αᵀw − λ/2 (w−b)ᵀΣ(w−b) − ρ/2 Σ max(0,|aₛ|−m)². */
        double[] gradient(double[] w, double lambda, double rho) {
            int n = w.length;
            double[] a = diff(w, in.benchmark);
            double[] sa = Optimizer.times(in.cov, a);
            double[] g = new double[n];
            double[] pen = new double[sectors];
            if (rho > 0) {
                double[] s = sectorSums(a, sectorOf, sectors);
                for (int k = 0; k < sectors; k++) {
                    double excess = Math.abs(s[k]) - band;
                    pen[k] = excess > 0 ? Math.signum(s[k]) * excess : 0;
                }
            }
            for (int i = 0; i < n; i++) g[i] = in.alpha[i] - lambda * sa[i] - (rho > 0 ? rho * pen[sectorOf[i]] : 0);
            return g;
        }

        /** Projection onto {lo ≤ w ≤ hi, Σw = 1}: wᵢ = clip(vᵢ − τ, loᵢ, hiᵢ), τ by bisection. */
        double[] project(double[] v) {
            int n = v.length;
            double a = Double.POSITIVE_INFINITY, b = Double.NEGATIVE_INFINITY;
            for (int i = 0; i < n; i++) {
                a = Math.min(a, v[i] - hi[i]);
                b = Math.max(b, v[i] - lo[i]);
            }
            for (int k = 0; k < 100; k++) {
                double mid = (a + b) / 2, sum = 0;
                for (int i = 0; i < n; i++) sum += Math.min(hi[i], Math.max(lo[i], v[i] - mid));
                if (sum > 1) a = mid; else b = mid;
            }
            double tau = (a + b) / 2;
            double[] w = new double[n];
            for (int i = 0; i < n; i++) w[i] = Math.min(hi[i], Math.max(lo[i], v[i] - tau));
            return w;
        }
    }

    // ------------------------------------------------------------------ helpers

    static double[] diff(double[] a, double[] b) {
        double[] d = new double[a.length];
        for (int i = 0; i < a.length; i++) d[i] = a[i] - b[i];
        return d;
    }

    static double[] sectorSums(double[] a, int[] sectorOf, int sectors) {
        double[] s = new double[sectors];
        for (int i = 0; i < a.length; i++) s[sectorOf[i]] += a[i];
        return s;
    }

    private static List<Object> ranked(Inputs in, double[] act, boolean top) {
        Integer[] order = new Integer[act.length];
        for (int i = 0; i < act.length; i++) order[i] = i;
        Arrays.sort(order, Comparator.comparingDouble(i -> top ? -act[i] : act[i]));
        List<Object> out = new ArrayList<>();
        for (int k = 0; k < Math.min(10, act.length); k++) {
            int i = order[k];
            Map<String, Object> r = new LinkedHashMap<>();
            r.put("asset", in.assets.get(i));
            if (in.sectors != null) r.put("sector", in.sectors.get(i));
            r.put("benchmark", Optimizer.round(in.benchmark[i], 6));
            r.put("active", Optimizer.round(act[i], 6));
            r.put("alpha", Optimizer.round(in.alpha[i], 6));
            out.add(r);
        }
        return out;
    }

    /** The 20 largest trades from the current weights (from zero without them). */
    private static List<Object> trades(Inputs in, double[] w) {
        Integer[] order = new Integer[w.length];
        for (int i = 0; i < w.length; i++) order[i] = i;
        Arrays.sort(order, Comparator.comparingDouble(i -> -Math.abs(w[i] - in.current[i])));
        List<Object> out = new ArrayList<>();
        for (int k = 0; k < Math.min(20, w.length); k++) {
            int i = order[k];
            double d = w[i] - in.current[i];
            if (Math.abs(d) < 1e-6) break;
            Map<String, Object> r = new LinkedHashMap<>();
            r.put("asset", in.assets.get(i));
            r.put("side", d > 0 ? "buy" : "sell");
            r.put("from", Optimizer.round(in.current[i], 6));
            r.put("to", Optimizer.round(w[i], 6));
            r.put("change", Optimizer.round(d, 6));
            out.add(r);
        }
        return out;
    }

    private static Map<String, Object> invalid(long started, String message) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("schema", SCHEMA);
        out.put("solverStatus", "invalid_input");
        out.put("error", message);
        Map<String, Object> d = new LinkedHashMap<>();
        d.put("recommendation", "escalate");
        d.put("confidence", 1.0);
        d.put("alternatives", List.of());
        d.put("reason", "The request was rejected: " + message);
        out.put("decisionContext", d);
        return out;
    }

    private static Map<String, Object> infeasible(long started, String message) {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("schema", SCHEMA);
        out.put("solverStatus", "infeasible");
        out.put("error", message);
        Map<String, Object> d = new LinkedHashMap<>();
        d.put("recommendation", "rerun_relaxed");
        d.put("confidence", 0.9);
        d.put("alternatives", List.of("escalate"));
        d.put("reason", "The constraints cannot be met: " + message);
        out.put("decisionContext", d);
        return out;
    }
}
