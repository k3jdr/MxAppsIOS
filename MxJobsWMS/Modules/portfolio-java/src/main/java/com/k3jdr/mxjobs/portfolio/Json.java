package com.k3jdr.mxjobs.portfolio;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Minimal JSON reader and writer, so the service has no dependencies.
 * Objects are {@code Map<String, Object>} (insertion order kept), arrays {@code List<Object>},
 * numbers {@code Double}, plus {@code String}, {@code Boolean} and {@code null}.
 */
public final class Json {
    private final String s;
    private int i;

    private Json(String s) {
        this.s = s;
    }

    /** Parses one JSON value; throws {@link IllegalArgumentException} on malformed input. */
    public static Object parse(String text) {
        Json p = new Json(text);
        p.skip();
        Object v = p.value();
        p.skip();
        if (p.i != p.s.length()) throw p.error("unexpected text after the value");
        return v;
    }

    private Object value() {
        if (i >= s.length()) throw error("unexpected end");
        char c = s.charAt(i);
        switch (c) {
            case '{': return object();
            case '[': return array();
            case '"': return string();
            case 't': return literal("true", Boolean.TRUE);
            case 'f': return literal("false", Boolean.FALSE);
            case 'n': return literal("null", null);
            default:
                if (c == '-' || (c >= '0' && c <= '9')) return number();
                throw error("unexpected '" + c + "'");
        }
    }

    private Map<String, Object> object() {
        Map<String, Object> map = new LinkedHashMap<>();
        i++;
        skip();
        if (peek('}')) { i++; return map; }
        while (true) {
            skip();
            if (!peek('"')) throw error("expected a key");
            String key = string();
            skip();
            expect(':');
            skip();
            map.put(key, value());
            skip();
            if (peek(',')) { i++; continue; }
            expect('}');
            return map;
        }
    }

    private List<Object> array() {
        List<Object> list = new ArrayList<>();
        i++;
        skip();
        if (peek(']')) { i++; return list; }
        while (true) {
            skip();
            list.add(value());
            skip();
            if (peek(',')) { i++; continue; }
            expect(']');
            return list;
        }
    }

    private String string() {
        StringBuilder b = new StringBuilder();
        i++;
        while (i < s.length()) {
            char c = s.charAt(i++);
            if (c == '"') return b.toString();
            if (c != '\\') { b.append(c); continue; }
            if (i >= s.length()) break;
            char e = s.charAt(i++);
            switch (e) {
                case 'n': b.append('\n'); break;
                case 't': b.append('\t'); break;
                case 'r': b.append('\r'); break;
                case 'b': b.append('\b'); break;
                case 'f': b.append('\f'); break;
                case 'u':
                    if (i + 4 > s.length()) throw error("bad \\u escape");
                    b.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                    i += 4;
                    break;
                default: b.append(e);
            }
        }
        throw error("unterminated string");
    }

    private Double number() {
        int start = i;
        while (i < s.length() && "+-0123456789.eE".indexOf(s.charAt(i)) >= 0) i++;
        try {
            return Double.valueOf(s.substring(start, i));
        } catch (NumberFormatException e) {
            throw error("bad number");
        }
    }

    private Object literal(String word, Object value) {
        if (!s.startsWith(word, i)) throw error("unexpected text");
        i += word.length();
        return value;
    }

    private void skip() {
        while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
    }

    private boolean peek(char c) {
        return i < s.length() && s.charAt(i) == c;
    }

    private void expect(char c) {
        if (!peek(c)) throw error("expected '" + c + "'");
        i++;
    }

    private IllegalArgumentException error(String message) {
        return new IllegalArgumentException("JSON: " + message + " at " + i);
    }

    // Writing

    /** Writes a value; doubles that are whole numbers are written without a fraction, NaN/∞ as null. */
    public static String write(Object v) {
        StringBuilder b = new StringBuilder();
        write(v, b, 0);
        return b.toString();
    }

    private static void write(Object v, StringBuilder b, int indent) {
        if (v == null) {
            b.append("null");
        } else if (v instanceof String) {
            quote((String) v, b);
        } else if (v instanceof Boolean) {
            b.append(v);
        } else if (v instanceof Number) {
            double d = ((Number) v).doubleValue();
            if (Double.isNaN(d) || Double.isInfinite(d)) b.append("null");
            else if (d == Math.rint(d) && Math.abs(d) < 1e15) b.append((long) d);
            else b.append(d);
        } else if (v instanceof Map) {
            Map<?, ?> map = (Map<?, ?>) v;
            if (map.isEmpty()) { b.append("{}"); return; }
            b.append("{\n");
            int n = 0;
            for (Map.Entry<?, ?> e : map.entrySet()) {
                pad(b, indent + 2);
                quote(String.valueOf(e.getKey()), b);
                b.append(": ");
                write(e.getValue(), b, indent + 2);
                b.append(++n < map.size() ? ",\n" : "\n");
            }
            pad(b, indent);
            b.append('}');
        } else if (v instanceof List) {
            List<?> list = (List<?>) v;
            if (list.isEmpty()) { b.append("[]"); return; }
            b.append('[');
            for (int k = 0; k < list.size(); k++) {
                if (k > 0) b.append(", ");
                write(list.get(k), b, indent);
            }
            b.append(']');
        } else {
            quote(v.toString(), b);
        }
    }

    private static void pad(StringBuilder b, int n) {
        for (int k = 0; k < n; k++) b.append(' ');
    }

    private static void quote(String s, StringBuilder b) {
        b.append('"');
        for (int k = 0; k < s.length(); k++) {
            char c = s.charAt(k);
            switch (c) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        b.append('"');
    }
}
