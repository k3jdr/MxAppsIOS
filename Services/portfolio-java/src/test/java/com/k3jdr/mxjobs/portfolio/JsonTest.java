package com.k3jdr.mxjobs.portfolio;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

class JsonTest {
    @Test
    void roundTrips() {
        String text = "{\"a\": [1, 2.5, -3e-2], \"b\": {\"c\": \"x\\\"y\\n\\u00e9\"}, \"d\": true, \"e\": null}";
        Object v = Json.parse(text);
        assertEquals(v, Json.parse(Json.write(v)));
        Map<?, ?> m = (Map<?, ?>) v;
        assertEquals(List.of(1.0, 2.5, -0.03), m.get("a"));
        assertEquals("x\"y\né", ((Map<?, ?>) m.get("b")).get("c"));
    }

    @Test
    void rejectsMalformed() {
        assertThrows(IllegalArgumentException.class, () -> Json.parse("{\"a\": }"));
        assertThrows(IllegalArgumentException.class, () -> Json.parse("[1, 2"));
        assertThrows(IllegalArgumentException.class, () -> Json.parse("{} x"));
    }

    @Test
    void writesWholeNumbersAndNonFinite() {
        assertEquals("[3, 0.5, null]", Json.write(List.of(3.0, 0.5, Double.NaN)));
    }
}
