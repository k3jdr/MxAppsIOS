# portfolio-java

Layer 3 **active portfolio construction** in Java (used by MxJobsWMS's Active Portfolio Optimization sample):

- `POST /optimize/active` → `mxjobs.active-optimization/1` — benchmark-relative mean-variance: maximise
  αᵀw − λ/2 (w − b)ᵀΣ(w − b), long-only, per-name cap, ±`maxActiveWeight` around the benchmark, sector bands
  (`maxSectorActive`), and an optional `trackingErrorTarget` (λ found by bisection). Inputs inline or by
  `inputsUrl` from the analytics service. Returns weights, active alpha, tracking error, information ratio,
  active share, sector actives, the 20 largest trades, binding constraints and a `decisionContext`.
- `POST /optimize` → `mxjobs.optimization/1` — absolute long-only max-Sharpe / min-variance / mean-variance with
  a per-asset cap (the same algorithm as portfolio-cpp, so they agree).
- `GET /describe` — what the service is for, shown in MxJobsWMS and MxDataHUB.

Why Java: constraint-heavy business rules stay readable and unit-tested in a long-running service.
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
| `src/main/java/.../ActiveOptimizer.java` | active optimization: accelerated projected gradient (FISTA with adaptive restart), box + simplex projection, sector-band penalty, TE-target bisection, decision rules |
| `src/main/java/.../Inputs.java` | `mxjobs.inputs/1` inline or fetched from `inputsUrl` (127.0.0.1 only) |
| `src/main/java/.../Optimizer.java` | the absolute algorithm and decision rules of `../contracts/README.md` |
| `src/main/java/.../Server.java` | HTTP: `/health`, `/describe`, `POST /optimize`, `POST /optimize/active` (400 for invalid input, 401 without the token) |
| `src/main/java/.../Json.java` | minimal JSON reader/writer |
| `src/test/java/...` | closed-form and brute-force checks, decision rules, JSON, HTTP |
