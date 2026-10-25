package com.k3jdr.mxjobs.portfolio;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Executors;

/**
 * MxJobsMGR Layer 3 optimization service (Java).
 *
 * <pre>
 *   java -jar target/portfolio-java.jar [--port 8766] [--token TOKEN]
 *
 *   GET  /health
 *   GET  /describe          what the service is for (shown in MxJobsMGR and MxDataHUB)
 *   POST /optimize          mxjobs.optimize-request/1 → mxjobs.optimization/1 (absolute max-Sharpe / mean-variance)
 *   POST /optimize/active   mxjobs.active-request/1 → mxjobs.active-optimization/1 (benchmark-relative, active mandates)
 * </pre>
 *
 * Listens on 127.0.0.1 only. With --token (or MXJOBS_SERVICE_TOKEN) requests need "Authorization: Bearer TOKEN".
 */
public final class Server {
    public static final int DEFAULT_PORT = 8766;
    private static final int MAX_BODY = 20_000_000;

    private final HttpServer http;
    private final String token;

    public Server(int port, String token) throws IOException {
        this.token = token == null || token.isBlank() ? null : token;
        http = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        http.setExecutor(Executors.newFixedThreadPool(4));
        http.createContext("/", this::handle);
    }

    public int port() {
        return http.getAddress().getPort();
    }

    public void start() {
        http.start();
    }

    public void stop() {
        http.stop(0);
    }

    private void handle(HttpExchange ex) throws IOException {
        try (ex) {
            if (token != null && !("Bearer " + token).equals(ex.getRequestHeaders().getFirst("Authorization"))
                    && !token.equals(ex.getRequestHeaders().getFirst("X-API-Key"))) {
                send(ex, 401, error("missing or wrong token"));
                return;
            }
            String path = ex.getRequestURI().getPath();
            String method = ex.getRequestMethod();
            switch (path) {
                case "/health" -> {
                    if (!method.equals("GET")) { send(ex, 405, error("use GET")); return; }
                    Map<String, Object> ok = new LinkedHashMap<>();
                    ok.put("status", "ok");
                    ok.put("service", "portfolio-java");
                    ok.put("engine", Optimizer.ENGINE);
                    ok.put("schemas", java.util.List.of(Optimizer.SCHEMA));
                    send(ex, 200, ok);
                }
                case "/describe" -> send(ex, 200, describe(port()));
                case "/optimize/active" -> {
                    if (!method.equals("POST")) { send(ex, 405, error("use POST")); return; }
                    Object body;
                    try {
                        body = Json.parse(readBody(ex));
                    } catch (IllegalArgumentException e) {
                        send(ex, 400, error(e.getMessage()));
                        return;
                    }
                    if (!(body instanceof Map<?, ?>)) { send(ex, 400, error("the body must be a JSON object")); return; }
                    @SuppressWarnings("unchecked")
                    Map<String, Object> outcome = ActiveOptimizer.optimize((Map<String, Object>) body);
                    send(ex, "invalid_input".equals(outcome.get("solverStatus")) ? 400 : 200, outcome);
                }
                case "/optimize" -> {
                    if (!method.equals("POST")) { send(ex, 405, error("use POST")); return; }
                    Object body;
                    try {
                        body = Json.parse(readBody(ex));
                    } catch (IllegalArgumentException e) {
                        send(ex, 400, error(e.getMessage()));
                        return;
                    }
                    if (!(body instanceof Map<?, ?>)) { send(ex, 400, error("the body must be a JSON object")); return; }
                    @SuppressWarnings("unchecked")
                    Map<String, Object> outcome = Optimizer.optimize((Map<String, Object>) body);
                    send(ex, "invalid_input".equals(outcome.get("solverStatus")) ? 400 : 200, outcome);
                }
                default -> send(ex, 404, error("no such endpoint: " + method + " " + path));
            }
        } catch (RuntimeException e) {
            send(ex, 500, error("internal error: " + e));
        }
    }

    /** What this service is for: shown in the Layer 3 Services view of MxJobsMGR and MxDataHUB. */
    static Map<String, Object> describe(int port) {
        Map<String, Object> d = new LinkedHashMap<>();
        d.put("id", "portfolio-java");
        d.put("name", "Active portfolio construction");
        d.put("language", "Java");
        d.put("port", (double) port);
        d.put("version", Optimizer.ENGINE);
        d.put("purpose", "Builds active (benchmark-relative) portfolios: maximise alpha for a tracking-error budget, "
                + "long-only, with per-name, active-weight and sector-band limits, and a trade list against the current "
                + "holdings. Also absolute max-Sharpe / mean-variance optimization.");
        d.put("whyThisLanguage", "Java suits rule-heavy, long-running services: constraints and business rules stay "
                + "readable and unit-tested (JUnit), it runs for months without restarts, and it connects easily to "
                + "order-management and compliance systems.");
        d.put("useCases", java.util.List.of("active", "absolute"));
        d.put("endpoints", java.util.List.of(
                endpoint("POST", "/optimize/active", "Active mean-variance against a benchmark (inputsUrl from analytics)", "mxjobs.active-optimization/1"),
                endpoint("POST", "/optimize", "Absolute max-Sharpe / mean-variance / min-variance", Optimizer.SCHEMA)));
        d.put("samples", java.util.List.of("active-optimization", "market-refresh"));
        return d;
    }

    private static Map<String, Object> endpoint(String method, String path, String summary, String contract) {
        Map<String, Object> e = new LinkedHashMap<>();
        e.put("method", method);
        e.put("path", path);
        e.put("summary", summary);
        e.put("contract", contract);
        return e;
    }

    private static String readBody(HttpExchange ex) throws IOException {
        try (InputStream in = ex.getRequestBody()) {
            byte[] data = in.readNBytes(MAX_BODY + 1);
            if (data.length > MAX_BODY) throw new IllegalArgumentException("request too large");
            return new String(data, StandardCharsets.UTF_8);
        }
    }

    private static Map<String, Object> error(String message) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("error", message);
        return m;
    }

    private static void send(HttpExchange ex, int status, Object payload) throws IOException {
        byte[] data = Json.write(payload).getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, data.length);
        try (OutputStream out = ex.getResponseBody()) {
            out.write(data);
        }
    }

    public static void main(String[] args) throws IOException {
        int port = DEFAULT_PORT;
        String token = System.getenv("MXJOBS_SERVICE_TOKEN");
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--port" -> port = Integer.parseInt(args[++i]);
                case "--token" -> token = args[++i];
                default -> {
                    System.err.println("usage: java -jar portfolio-java.jar [--port 8766] [--token TOKEN]");
                    System.exit(2);
                }
            }
        }
        Server server = new Server(port, token);
        server.start();
        System.out.println("MxJobsMGR portfolio-java on http://127.0.0.1:" + server.port()
                + (server.token != null ? " (token required)" : ""));
    }
}
