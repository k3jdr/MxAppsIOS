# MxJobsWMS Layer 3 modules

Compute services that Layer 3 steps call over HTTP on this Mac, and the contracts they share. They run outside
MxJobsWMS's sandbox, so they can use any libraries, solver licences and data you give them.

| Module | Language | Port | Endpoints | Develop in |
| ------ | -------- | ---- | --------- | ---------- |
| [contracts](contracts/) | JSON Schema | — | `mxjobs.optimize-request/1`, `mxjobs.optimization/1`, `mxjobs.risk/1` | any |
| [portfolio-java](portfolio-java/) | Java 17+ (JDK only) | 8766 | `/health`, `POST /optimize` | IntelliJ IDEA (or VS Code + Java extensions) |
| [portfolio-cpp](portfolio-cpp/) | C++17 | 8767 | `/health`, `POST /optimize`, `POST /risk` | CLion (or VS Code + clangd / CMake Tools) |
| [../Samples/python-service](../Samples/python-service/) | Python 3.9+ | 8765 | `/quote`, `/history`, `/indicators` | any |

```bash
cd portfolio-java && mvn -q package && java -jar target/portfolio-java.jar     # 127.0.0.1:8766
cd portfolio-cpp && make run                                                   # 127.0.0.1:8767
python3 contracts/check_engines.py     # both running: schema checks + Java/C++ agreement
```

Both engines implement the same optimization (see [contracts/README.md](contracts/README.md)), so their weights,
metrics and recommendations agree within 1e-5; `check_engines.py` verifies that on the example and random requests.

In MxJobsWMS each service is a **Local service** subscription (API Subscriptions ▸ +) whose **Source Project**
points here, so its steps get **Open Project in …** (VS Code, IntelliJ IDEA, CLion, Xcode or Finder).
