# portfolio-java

MxJobsWMS Layer 3 optimization service in Java: long-only max-Sharpe / min-variance / mean-variance with a
per-asset cap, returning `mxjobs.optimization/1` with a `decisionContext` for the Layer 2 decision agent.
No runtime dependencies (JDK `HttpServer` and its own small JSON code); JUnit 5 for tests.

```bash
mvn -q package                                   # build + tests → target/portfolio-java.jar
gradle build                                     # or Gradle → build/libs/portfolio-java.jar
java -jar target/portfolio-java.jar              # http://127.0.0.1:8766
java -jar target/portfolio-java.jar --port 9000 --token s3cret
curl -s -X POST --data @../contracts/examples/optimize-request.json http://127.0.0.1:8766/optimize
```

`pom.xml` and `build.gradle.kts` are equivalent (both compile for Java 17 with the installed JDK and run the same
JUnit tests); IntelliJ IDEA opens the folder with either.

| File | |
| ---- | - |
| `src/main/java/.../Optimizer.java` | the algorithm and decision rules of `../contracts/README.md` |
| `src/main/java/.../Server.java` | HTTP: `GET /health`, `POST /optimize` (400 for invalid input, 401 without the token) |
| `src/main/java/.../Json.java` | minimal JSON reader/writer |
| `src/test/java/...` | closed-form and brute-force checks, decision rules, JSON, HTTP |
