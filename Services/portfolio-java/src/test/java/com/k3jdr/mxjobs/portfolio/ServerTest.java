package com.k3jdr.mxjobs.portfolio;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class ServerTest {
    private Server server;
    private final HttpClient client = HttpClient.newHttpClient();

    @BeforeEach
    void start() throws Exception {
        server = new Server(0, "t0ken");
        server.start();
    }

    @AfterEach
    void stop() {
        server.stop();
    }

    private HttpResponse<String> send(String method, String path, String body, String token) throws Exception {
        HttpRequest.Builder b = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + server.port() + path));
        if (token != null) b.header("Authorization", "Bearer " + token);
        b.method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body));
        return client.send(b.build(), HttpResponse.BodyHandlers.ofString());
    }

    @Test
    void healthNeedsTheToken() throws Exception {
        assertEquals(401, send("GET", "/health", null, null).statusCode());
        HttpResponse<String> ok = send("GET", "/health", null, "t0ken");
        assertEquals(200, ok.statusCode());
        assertEquals("ok", ((Map<?, ?>) Json.parse(ok.body())).get("status"));
    }

    @Test
    void optimizesOverHttp() throws Exception {
        HttpResponse<String> r = send("POST", "/optimize", Json.write(OptimizerTest.example()), "t0ken");
        assertEquals(200, r.statusCode());
        Map<?, ?> out = (Map<?, ?>) Json.parse(r.body());
        assertEquals("optimal", out.get("solverStatus"));
    }

    @Test
    void badRequestsAre400And404() throws Exception {
        assertEquals(400, send("POST", "/optimize", "{not json", "t0ken").statusCode());
        assertEquals(400, send("POST", "/optimize", "{\"assets\": []}", "t0ken").statusCode());
        assertEquals(404, send("GET", "/nope", null, "t0ken").statusCode());
        assertEquals(405, send("GET", "/optimize", null, "t0ken").statusCode());
    }
}
