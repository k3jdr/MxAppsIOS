# portfolio-cpp

MxJobsWMS Layer 3 optimization and risk service in C++17: the same optimization as portfolio-java
(`mxjobs.optimization/1`) plus `POST /risk` (`mxjobs.risk/1`: parametric VaR and expected shortfall, risk
contributions, diversification ratio, concentration). Header-only dependencies, pinned:
[cpp-httplib](https://github.com/yhirose/cpp-httplib) v0.18.3 and [nlohmann/json](https://github.com/nlohmann/json) v3.11.3.

```bash
make            # fetches the two headers into third_party/ (once), builds build/portfolio-cpp
make test       # unit tests
make run        # http://127.0.0.1:8767   (or ./build/portfolio-cpp --port 9000 --token s3cret)
```

With CMake (CLion, VS Code CMake Tools): `cmake -S . -B cmake-build && cmake --build cmake-build && ctest --test-dir cmake-build`
— `CMakeLists.txt` fetches the same versions with FetchContent. Make and CMake builds are equivalent.

```bash
curl -s -X POST --data @../contracts/examples/optimize-request.json http://127.0.0.1:8767/optimize
curl -s -X POST -d '{"assets":["A","B"],"weights":{"A":0.6,"B":0.4},"covariance":[[0.04,0.01],[0.01,0.09]],"confidence":0.99,"horizonDays":10,"portfolioValue":1000000}' http://127.0.0.1:8767/risk
```
