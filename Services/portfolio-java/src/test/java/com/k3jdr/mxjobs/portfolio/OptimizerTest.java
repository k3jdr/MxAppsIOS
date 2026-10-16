package com.k3jdr.mxjobs.portfolio;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import org.junit.jupiter.api.Test;

class OptimizerTest {

    /** The request in Services/contracts/examples/optimize-request.json. */
    static Map<String, Object> example() {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("assets", List.of("AAPL", "MSFT", "NVDA", "TLT"));
        r.put("expectedReturns", List.of(0.11, 0.10, 0.16, 0.04));
        r.put("covariance", List.of(
                List.of(0.0625, 0.0300, 0.0450, -0.0040),
                List.of(0.0300, 0.0484, 0.0400, -0.0030),
                List.of(0.0450, 0.0400, 0.1600, -0.0050),
                List.of(-0.0040, -0.0030, -0.0050, 0.0196)));
        r.put("objective", "max_sharpe");
        r.put("riskFreeRate", 0.02);
        r.put("maxWeight", 0.4);
        r.put("currentWeights", Map.of("AAPL", 0.25, "MSFT", 0.25, "NVDA", 0.25, "TLT", 0.25));
        r.put("maxTurnover", 0.2);
        return r;
    }

    @SuppressWarnings("unchecked")
    static Map<String, Double> weights(Map<String, Object> out) {
        return (Map<String, Double>) out.get("weights");
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> decision(Map<String, Object> out) {
        return (Map<String, Object>) out.get("decisionContext");
    }

    @Test
    void exampleIsFeasibleCappedAndFullyInvested() {
        Map<String, Object> out = Optimizer.optimize(example());
        assertEquals("mxjobs.optimization/1", out.get("schema"));
        assertEquals("optimal", out.get("solverStatus"));
        double sum = 0;
        for (double w : weights(out).values()) {
            assertTrue(w >= 0 && w <= 0.4 + 1e-9, "weight in [0, cap]: " + w);
            sum += w;
        }
        assertEquals(1.0, sum, 1e-5);
        // Brute-force search over the capped simplex gives 0.484807 with TLT at the cap.
        assertEquals(0.484807, (Double) out.get("sharpe"), 2e-5);
        assertEquals(0.4, weights(out).get("TLT"), 1e-4);
        assertTrue(((List<?>) out.get("bindingConstraints")).contains("max_weight"));
        assertTrue((Double) out.get("turnover") > 0);
    }

    @Test
    void minVarianceMatchesClosedForm() {
        // Uncorrelated: w ∝ 1/σ² → σ² = (0.04, 0.01) gives (0.2, 0.8).
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("assets", List.of("A", "B"));
        r.put("expectedReturns", List.of(0.1, 0.05));
        r.put("covariance", List.of(List.of(0.04, 0.0), List.of(0.0, 0.01)));
        r.put("objective", "min_variance");
        Map<String, Object> out = Optimizer.optimize(r);
        assertEquals("optimal", out.get("solverStatus"));
        assertEquals(0.2, weights(out).get("A"), 1e-5);
        assertEquals(0.8, weights(out).get("B"), 1e-5);
    }

    @Test
    void maxSharpeIsCloseToTangencyPortfolio() {
        // Tangency w ∝ Σ⁻¹μ = (2.5, 5) → (1/3, 2/3), Sharpe √(μᵀΣ⁻¹μ) = √0.5.
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("assets", List.of("A", "B"));
        r.put("expectedReturns", List.of(0.1, 0.05));
        r.put("covariance", List.of(List.of(0.04, 0.0), List.of(0.0, 0.01)));
        Map<String, Object> out = Optimizer.optimize(r);
        assertEquals(Math.sqrt(0.5), (Double) out.get("sharpe"), 0.005);
        assertEquals(1.0 / 3, weights(out).get("A"), 0.03);
    }

    @Test
    void capTooSmallIsInfeasible() {
        Map<String, Object> r = example();
        r.put("maxWeight", 0.2); // 4 × 0.2 < 1
        Map<String, Object> out = Optimizer.optimize(r);
        assertEquals("infeasible", out.get("solverStatus"));
        assertEquals("rerun_relaxed", decision(out).get("recommendation"));
        assertTrue(weights(out).isEmpty());
    }

    @Test
    void estimatesFromPrices() {
        Random rng = new Random(7);
        Map<String, Object> prices = new LinkedHashMap<>();
        for (String a : List.of("X", "Y", "Z")) {
            List<Object> p = new ArrayList<>();
            double v = 100;
            for (int t = 0; t < 250; t++) {
                v *= 1 + 0.0005 + 0.015 * rng.nextGaussian();
                p.add(v);
            }
            prices.put(a, p);
        }
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("assets", List.of("X", "Y", "Z"));
        r.put("prices", prices);
        r.put("objective", "mean_variance");
        r.put("maxWeight", 0.6);
        Map<String, Object> out = Optimizer.optimize(r);
        assertEquals("optimal", out.get("solverStatus"));
        assertNull(out.get("turnover"));
        assertEquals("rebalance", decision(out).get("recommendation"));
    }

    @Test
    void holdsWhenAlreadyOptimal() {
        Map<String, Object> first = Optimizer.optimize(example());
        Map<String, Object> r = example();
        r.put("currentWeights", new LinkedHashMap<>(weights(first)));
        Map<String, Object> out = Optimizer.optimize(r);
        assertEquals("hold", decision(out).get("recommendation"));
    }

    @Test
    void largeTurnoverRebalancesPartially() {
        Map<String, Object> r = example();
        r.put("currentWeights", Map.of("TLT", 1.0));
        r.put("maxTurnover", 0.1);
        Map<String, Object> out = Optimizer.optimize(r);
        assertEquals("rebalance_partially", decision(out).get("recommendation"));
        assertTrue(((List<?>) out.get("bindingConstraints")).contains("max_turnover"));
    }

    @Test
    void invalidInputEscalates() {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("assets", List.of("A", "B"));
        r.put("expectedReturns", List.of(0.1));
        Map<String, Object> out = Optimizer.optimize(r);
        assertEquals("invalid_input", out.get("solverStatus"));
        assertEquals("escalate", decision(out).get("recommendation"));
    }

    @Test
    void projectionStaysOnCappedSimplex() {
        double[] w = Optimizer.project(new double[] {5, -3, 0.2, 0.1}, 0.5);
        double sum = 0;
        for (double x : w) {
            assertTrue(x >= 0 && x <= 0.5 + 1e-12);
            sum += x;
        }
        assertEquals(1.0, sum, 1e-12);
    }
}
