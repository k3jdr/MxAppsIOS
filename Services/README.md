# Layer 3 services

The compute and data services that **MxDataHUB** and **MxJobsWMS** both use. Each is a small HTTP service on this
Mac (127.0.0.1 only), outside the apps' sandboxes, so it can use any libraries, solver licences, databases and
credentials you give it.

## How the pieces fit

| | Role | Where you work |
| --- | --- | --- |
| **MxDataHUB** | **The data.** Securities, benchmarks, portfolios in the security master (PostgreSQL schema `srm`), and keeping each category of market data fresh. | Data Refresh, Portfolios, Benchmarks, Load History |
| **MxJobsWMS** | **The processes.** Repeatable, scheduled, approved workflows over that data, in three layers: business operations, agents, Layer 3 data reads and computations. | Jobspaces built from the samples |
| **Services/** (here) | **The Layer 3 tools** both apps call: loaders, analytics, optimizers, risk. | Your IDE (IntelliJ IDEA, CLion, VS Code) |

They link both ways: MxDataHUB's **Portfolios ▸ Workflows** (Optimize, Track, Attribution), **Benchmarks ▸ Track…**
and **Data Refresh ▸ Automate in MxJobsWMS…** open the matching MxJobsWMS workflow for that portfolio or benchmark
(`mxjobswms://sample/<id>?portfolio=&benchmark=`); MxJobsWMS's **Window ▸ Open MxDataHUB** goes the other way
(`mxdatahub://…`). Both apps show these services, their state and their purpose under **Layer 3 Services**
(MxJobsWMS: Window ▸ Layer 3 Services, ⌥⌘L, and the palette; MxDataHUB: Services & Workflows).

## Run them

```bash
python3 Services/mxservices.py start      # builds Java / C++ the first time, starts all five
python3 Services/mxservices.py status     # which run, on which port, what each is for
python3 Services/mxservices.py stop
python3 Services/mxservices.py install-agents   # optional: start them at login (launchd)
```

Logs: `~/Library/Logs/MxServices/<id>.log`. Python services need `numpy` and `psycopg2` (the analytics and SRM
loader services read the security master with SRM's own connection settings — see `MxDataHUB/SRM/README.md`).

## The services

| Service | Language | Port | What it is for | Use it for |
| --- | --- | --- | --- | --- |
| [srm-loader](srm-loader/) | Python | 8770 | Refresh the security master **by data category** (runs `MxDataHUB/SRM/srm.py` loaders); freshness and data-quality checks | Data refresh, data quality |
| [analytics](analytics/) | Python | 8772 | **Optimization inputs** from the security master (universe, sectors, benchmark and current weights, Ledoit-Wolf covariance, momentum alpha) and **performance attribution** (Brinson-Fachler, monthly, Carino-linked) | Active, passive, attribution, risk |
| [portfolio-java](portfolio-java/) | Java | 8766 | **Active portfolio construction**: alpha vs active risk at a tracking-error target, name / active-weight / sector limits, trade list; absolute max-Sharpe | Active management |
| [portfolio-cpp](portfolio-cpp/) | C++ | 8767 | **Index tracking**: the ≤ N-name portfolio with the smallest tracking error (full, largest-weight or sector-stratified); **risk**: VaR, ES, tracking error, beta, active-risk contributions | Passive / index, risk |
| [market-sample](market-sample/) | Python | 8765 | Synthetic quotes and indicators; the template for wrapping a new data source | Templates, testing |
| [contracts](contracts/) | JSON | — | The versioned request / outcome contracts between the services and the agents | — |

Every service answers `GET /health` and `GET /describe` (its purpose, language rationale, use cases, endpoints and
the samples built on it — what the apps display).

## Choosing a language for a Layer 3 tool

| Language | Use it for | Examples here |
| --- | --- | --- |
| **Python** | Data work: loading and cleaning sources, database queries, statistics (numpy, pandas), reports. Quickest to write and change; slower in tight numeric loops. | srm-loader, analytics |
| **Java** | Long-running business services with many rules: portfolio-construction constraints, compliance, order-management integration. Typed, unit-tested, stable for months. | portfolio-java |
| **C++** | Numerically heavy, latency-sensitive loops: large covariance matrices, tracking and risk recomputed for every scenario or rebalance. | portfolio-cpp |

The usual chain: **Python prepares** the data and statistics → **Java or C++ optimizes / measures** → the result's
`decisionContext` feeds a **Layer 2 decision** → **Layer 1 approval** before anything is sent. Large matrices stay in
the services: `POST /inputs` returns an `inputsUrl` that the Java and C++ endpoints fetch, so megabytes of covariance
never pass through the workflow (in a jobspace: `"inputsUrl": "{{in:optInputs.inputsUrl}}"`).

## Use cases and their sample workflows

Open them in MxJobsWMS (**File ▸ New from Sample…**) or from a portfolio in MxDataHUB.

| Use case | Sample | Layer 3 chain | Typical decision |
| --- | --- | --- | --- |
| **Data refresh** | SRM Daily Refresh | srm-loader: 12 loaders in dependency order, then status / quality | Approve the report; schedule backfills |
| **Active management** — beat a benchmark within a risk budget | Active Portfolio Optimization | analytics `/inputs` (momentum alpha) → portfolio-java `/optimize/active` (3% tracking error, ±3% per name, ±5% per sector) → portfolio-cpp `/risk` | rebalance / rebalance partially (turnover) / hold |
| **Passive / index** — match a benchmark with fewer names | Passive Index Tracking | analytics `/inputs` (covariance) → portfolio-cpp `/optimize/tracking` (100 names, stratified) and full replication for comparison | rebalance when drift exceeds the tracking-error budget, else hold |
| **Attribution** — explain past active return | Performance & Risk Attribution | analytics `/attribution` (sector Brinson-Fachler, monthly, Carino) + analytics `/inputs` → portfolio-cpp `/risk` (ex-ante active risk by sector) | publish, or review when data gaps or residuals appear |
| Templates | Daily Market Data Refresh | market-sample, public APIs, absolute optimizers | — |

Results on the demo data (`DEMO_GROWTH` against the S&P 500, prices to 2026-10-15): the active optimizer reaches
a 3.0% tracking error at an information ratio of 0.49 with 118 names; a 100-name stratified S&P 500 tracker has a
0.83% tracking error (50 names: 1.69%, 200: 0.40%); attribution over 12 months shows −9.5% active return —
allocation +3.7%, selection −7.1%, interaction −6.1%, led by Technology.

**Assumption to know:** the security master keeps the *current* benchmark and portfolio snapshots, not their history,
so attribution holds today's weights through the period (stated in each result's `assumptions`). Daily snapshots build
history from now on.

## Develop

| Service | Open in | Build / test |
| --- | --- | --- |
| srm-loader, analytics, market-sample | VS Code or PyCharm | run the `.py` file; `curl` the endpoints |
| portfolio-java | IntelliJ IDEA | `mvn -q package` (`mvn -q test`: 20 JUnit tests) |
| portfolio-cpp | CLion or VS Code (CMake Tools, clangd) | `make`, `make test` (52 checks) |
| contracts | any | `python3 contracts/check_engines.py` (Java and C++ `/optimize` agree) |

In MxJobsWMS each service is a **Local service** subscription whose **Source Project** points here, so its steps have
**Open Project in …**; the Layer 3 Services window's **Add Step** creates the subscription and a step for an endpoint.
