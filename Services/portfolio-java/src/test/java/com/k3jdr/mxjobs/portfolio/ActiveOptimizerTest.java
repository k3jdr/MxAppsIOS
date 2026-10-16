package com.k3jdr.mxjobs.portfolio;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class ActiveOptimizerTest {

    /** Five assets in two sectors, inline inputs (mxjobs.inputs/1 fields). */
    static Map<String, Object> request(List<Double> alpha) {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("assets", List.of("A", "B", "C", "D", "E"));
        r.put("sectors", List.of("Tech", "Tech", "Tech", "Energy", "Energy"));
        r.put("benchmarkWeights", List.of(0.30, 0.25, 0.15, 0.20, 0.10));
        r.put("expectedReturns", alpha);
        r.put("covariance", List.of(
                List.of(0.0625, 0.0300, 0.0250, 0.0100, 0.0080),
                List.of(0.0300, 0.0484, 0.0200, 0.0090, 0.0070),
                List.of(0.0250, 0.0200, 0.0900, 0.0110, 0.0100),
                List.of(0.0100, 0.0090, 0.0110, 0.0400, 0.0200),
                List.of(0.0080, 0.0070, 0.0100, 0.0200, 0.0500)));
        r.put("maxWeight", 0.5);
        r.put("maxActiveWeight", 0.05);
        return r;
    }

    @SuppressWarnings("unchecked")
    static Map<String, Double> weights(Map<String, Object> out) {
        return (Map<String, Double>) out.get("weights");
    }

    @Test
    void withoutAlphaTheBenchmarkIsOptimal() {
        Map<String, Object> out = ActiveOptimizer.optimize(request(List.of(0.0, 0.0, 0.0, 0.0, 0.0)));
        assertEquals("optimal", out.get("solverStatus"));
        assertEquals(0.30, weights(out).get("A"), 1e-5);
        assertEquals(0.0, (Double) out.get("trackingError"), 1e-5);
    }

    @Test
    void activeWeightsStayWithinTheirBounds() {
        Map<String, Object> out = ActiveOptimizer.optimize(request(List.of(0.20, -0.10, 0.0, 0.05, -0.05)));
        assertEquals("optimal", out.get("solverStatus"));
        Map<String, Double> w = weights(out);
        double[] b = {0.30, 0.25, 0.15, 0.20, 0.10};
        String[] names = {"A", "B", "C", "D", "E"};
        double sum = 0;
        for (int i = 0; i < 5; i++) {
            double wi = w.getOrDefault(names[i], 0.0);
            sum += wi;
            assertTrue(Math.abs(wi - b[i]) <= 0.05 + 1e-6, names[i] + " active weight " + (wi - b[i]));
        }
        assertEquals(1.0, sum, 1e-5);
        assertTrue(w.get("A") > 0.30, "A has the highest alpha and is overweight");
        assertTrue((Double) out.get("activeAlpha") > 0);
    }

    @Test
    void trackingErrorTargetIsMet() {
        Map<String, Object> req = request(List.of(0.20, -0.10, 0.0, 0.05, -0.05));
        req.put("riskAversion", 0.5);
        req.put("trackingErrorTarget", 0.01);
        Map<String, Object> out = ActiveOptimizer.optimize(req);
        assertEquals("optimal", out.get("solverStatus"));
        assertTrue((Double) out.get("trackingError") <= 0.01 + 1e-4, "TE " + out.get("trackingError"));
    }

    @Test
    void sectorBandIsRespected() {
        Map<String, Object> req = request(List.of(0.20, 0.20, 0.20, -0.20, -0.20));
        req.put("maxActiveWeight", 0.10);
        req.put("maxSectorActive", 0.02);
        Map<String, Object> out = ActiveOptimizer.optimize(req);
        assertTrue((Double) out.get("maxSectorActive") <= 0.02 + 0.002, "sector active " + out.get("maxSectorActive"));
    }

    @Test
    void impossibleBoundsAreInfeasible() {
        Map<String, Object> req = request(List.of(0.0, 0.0, 0.0, 0.0, 0.0));
        req.put("maxWeight", 0.1);
        Map<String, Object> out = ActiveOptimizer.optimize(req);
        assertEquals("infeasible", out.get("solverStatus"));
        assertEquals("rerun_relaxed", ((Map<?, ?>) out.get("decisionContext")).get("recommendation"));
    }
}
