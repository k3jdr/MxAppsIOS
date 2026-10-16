# Portfolio analytics service

The **data and statistics** side of portfolio work (Python, numpy, 127.0.0.1:8772). It reads the security master that
MxDataHUB manages (`MxDataHUB/SRM`, schema `srm`) with SRM's own connection settings.

```bash
python3 analytics_service.py            # or: python3 Services/mxservices.py start
```

| Endpoint | What it does |
| -------- | ------------ |
| `GET /health`, `GET /describe` | status; what the service is for (shown in both apps) |
| `GET /portfolios`, `GET /benchmarks` | what can be analysed |
| `POST /inputs` | optimization inputs → a summary with `inputsUrl` (`mxjobs.inputs-summary/1`) |
| `GET /inputs/<id>` | the full inputs (`mxjobs.inputs/1`), fetched by portfolio-java and portfolio-cpp |
| `POST /attribution` | sector attribution (`mxjobs.attribution/1`) |

**`POST /inputs`** `{"mode": "active" | "tracking" | "absolute" | "risk", "portfolio": "DEMO_GROWTH", "benchmark": "SP500",
"alpha": "momentum_12_1" | "historical" | "none", "ic": 0.05, "lookbackDays": 504, "asOf": "YYYY-MM-DD"}`

- Universe: the benchmark's members plus the portfolio's holdings (latest snapshot, valued with the latest prices);
  securities with less than 80% price history are left out and their weight reported.
- Covariance: daily returns of adjusted closes over `lookbackDays`, Ledoit-Wolf shrinkage to a scaled identity,
  annualised ×252.
- Alpha (active mode): Grinold α = IC × σ × z, z the winsorised cross-sectional score of 12-1 month momentum.
- The full payload (assets, names, sectors, benchmark and current weights, expected returns, covariance) is cached in
  memory (the last 20) under `/inputs/<id>`; the summary lists the universe size, exclusions, shrinkage and the top
  and bottom alpha names.

**`POST /attribution`** `{"portfolio": "DEMO_GROWTH", "benchmark": "SP500", "start": "", "end": "",
"method": "brinson-fachler" | "brinson-hood-beebower"}` (empty dates = the last 12 months to the last price date)

- Monthly periods; per period, by sector: allocation (wₚ − w_b)(R_b,s − R_b), selection w_b(Rₚ,s − R_b,s),
  interaction (wₚ − w_b)(Rₚ,s − R_b,s) (BHB measures allocation against zero).
- Carino linking, so the linked effects add up to the compounded active return (`effects.residual` ≈ 0).
- Also: per-period effects, sector table, top and bottom contributors, data gaps, and a `decisionContext`
  (`publish`, or `review` when prices are missing for more than 2% of weight or the residual is not zero).
- Assumption: the security master keeps the current portfolio and benchmark snapshots, so their weights are held
  at the start of every month of the period. This is stated in the result's `assumptions`.

Why Python: database queries, aligning price histories, estimating statistics and shaping reports — the parts that
change most often. The heavy optimization loops go to Java (active) and C++ (tracking, risk).
