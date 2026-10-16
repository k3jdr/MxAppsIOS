package com.k3jdr.mxjobs.portfolio;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Optimization inputs (mxjobs.inputs/1): inline in the request, or fetched from the analytics service by
 * {@code inputsUrl} so the covariance of a 500-name universe never passes through the workflow.
 * Request fields override fetched ones.
 */
final class Inputs {
    final List<String> assets;
    final List<String> sectors;
    final double[] benchmark;
    final double[] alpha;
    final double[][] cov;
    final double[] current;
    final boolean hasCurrent;
    final Map<String, Object> source;

    private Inputs(Map<String, Object> m) {
        assets = strings(m.get("assets"), "assets");
        int n = assets.size();
        if (n == 0) throw new Optimizer.InvalidInput("assets must not be empty");
        List<String> s = m.get("sectors") == null ? null : strings(m.get("sectors"), "sectors");
        if (s != null && s.size() != n) throw new Optimizer.InvalidInput("sectors must have one entry per asset");
        sectors = s;
        benchmark = m.get("benchmarkWeights") == null ? new double[n] : vector(m.get("benchmarkWeights"), n, "benchmarkWeights");
        alpha = m.get("expectedReturns") == null ? new double[n] : vector(m.get("expectedReturns"), n, "expectedReturns");
        cov = matrix(m.get("covariance"), n);
        current = new double[n];
        Object cw = m.get("currentWeights");
        hasCurrent = cw instanceof Map<?, ?> cm && !cm.isEmpty();
        if (hasCurrent) {
            Map<String, Integer> index = new LinkedHashMap<>();
            for (int i = 0; i < n; i++) index.put(assets.get(i), i);
            for (Map.Entry<?, ?> e : ((Map<?, ?>) cw).entrySet()) {
                Integer i = index.get(String.valueOf(e.getKey()));
                if (i != null && e.getValue() instanceof Number num) current[i] = num.doubleValue();
            }
        }
        source = new LinkedHashMap<>();
        for (String key : List.of("portfolio", "benchmark", "asOf", "statistics", "alpha")) {
            if (m.get(key) != null) source.put(key, m.get(key));
        }
    }

    /** Inline inputs, or those at {@code inputsUrl} merged with the request (request wins). */
    @SuppressWarnings("unchecked")
    static Inputs from(Map<String, Object> req) {
        Map<String, Object> merged = new LinkedHashMap<>();
        Object url = req.get("inputsUrl");
        if (url instanceof String u && !u.isBlank()) {
            Object fetched = Json.parse(fetch(u));
            if (!(fetched instanceof Map<?, ?>)) throw new Optimizer.InvalidInput("inputsUrl did not return a JSON object");
            merged.putAll((Map<String, Object>) fetched);
        }
        for (Map.Entry<String, Object> e : req.entrySet()) {
            if (!e.getKey().equals("inputsUrl")) merged.put(e.getKey(), e.getValue());
        }
        return new Inputs(merged);
    }

    /** GET from a service on this Mac only. */
    static String fetch(String url) {
        URI uri;
        try {
            uri = URI.create(url);
        } catch (IllegalArgumentException e) {
            throw new Optimizer.InvalidInput("inputsUrl is not a URL: " + url);
        }
        String host = uri.getHost();
        if (!"http".equals(uri.getScheme()) || !("127.0.0.1".equals(host) || "localhost".equals(host))) {
            throw new Optimizer.InvalidInput("inputsUrl must be http://127.0.0.1:… (a service on this Mac)");
        }
        try {
            HttpResponse<String> r = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build()
                    .send(HttpRequest.newBuilder(uri).timeout(Duration.ofSeconds(60)).GET().build(),
                          HttpResponse.BodyHandlers.ofString());
            if (r.statusCode() != 200) {
                throw new Optimizer.InvalidInput("inputsUrl answered HTTP " + r.statusCode() + ": "
                        + r.body().substring(0, Math.min(200, r.body().length())));
            }
            return r.body();
        } catch (java.io.IOException e) {
            throw new Optimizer.InvalidInput("could not fetch inputsUrl (is the analytics service running?): " + e.getMessage());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new Optimizer.InvalidInput("interrupted while fetching inputsUrl");
        }
    }

    // ------------------------------------------------------------------ parsing

    static List<String> strings(Object o, String name) {
        if (!(o instanceof List<?> list)) throw new Optimizer.InvalidInput(name + " must be an array of strings");
        List<String> out = new ArrayList<>();
        for (Object x : list) out.add(String.valueOf(x));
        return out;
    }

    static double[] vector(Object o, int n, String name) {
        if (!(o instanceof List<?> list) || list.size() != n) {
            throw new Optimizer.InvalidInput(name + " must have one number per asset (" + n + ")");
        }
        double[] v = new double[n];
        for (int i = 0; i < n; i++) {
            if (!(list.get(i) instanceof Number num)) throw new Optimizer.InvalidInput(name + " must contain numbers");
            v[i] = num.doubleValue();
        }
        return v;
    }

    static double[][] matrix(Object o, int n) {
        if (!(o instanceof List<?> rows) || rows.size() != n) {
            throw new Optimizer.InvalidInput("covariance must be a " + n + "×" + n + " matrix");
        }
        double[][] m = new double[n][];
        for (int i = 0; i < n; i++) m[i] = vector(rows.get(i), n, "covariance row");
        return m;
    }

    static double number(Map<String, Object> req, String key, double fallback) {
        Object o = req.get(key);
        if (o == null) return fallback;
        if (!(o instanceof Number num)) throw new Optimizer.InvalidInput(key + " must be a number");
        return num.doubleValue();
    }

    static Double optionalNumber(Map<String, Object> req, String key) {
        Object o = req.get(key);
        if (o == null) return null;
        if (!(o instanceof Number num)) throw new Optimizer.InvalidInput(key + " must be a number");
        return num.doubleValue();
    }
}
