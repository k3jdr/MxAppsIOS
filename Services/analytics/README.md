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
- `"securities": ["VTI", "BND", …]` (with or without a portfolio / benchmark) adds securities by ticker; VTI, the
  market proxy, is always priced. Each asset's market beta against VTI and rate beta against the daily change in the
  10-year Treasury yield (DGS10, as a decimal: ≈ −duration for a bond fund) come from one regression on the same daily
  returns; the payload adds `betas`, `rateBetas`, `marketProxy`, `marketVol` (VTI's annual volatility), `riskFree` (the
  latest 3-month Treasury yield, DGS3MO), `lastPrices` and `unknown` (tickers not found).
- Prices: one listing and one source per security over the whole window — the one with the most days, an adjusted
  source (FMP) preferred when it covers nearly as many — so the series never switches between adjusted and unadjusted
  closes. A listing abroad (London, Toronto) is converted to dollars at each day's rate (`srm.fx_to_usd`, V021), and
  `lastPrices` are `srm.last_price`'s dollars.
- The full payload (assets, names, sectors, benchmark and current weights, expected returns, covariance) is cached in
  memory (the last 20) under `/inputs/<id>`; the summary lists the universe size, exclusions, shrinkage and the top
  and bottom alpha names.

**`POST /attribution`** `{"portfolio": "DEMO_GROWTH", "benchmark": "SP500", "start": "", "end": "",
"method": "brinson-fachler" | "brinson-hood-beebower"}` (empty dates = the last 12 months to the last price date)

- Monthly periods; per period, by sector: allocation (wₚ − w_b)(R_b,s − R_b), selection w_b(Rₚ,s − R_b,s),
  interaction (wₚ − w_b)(Rₚ,s − R_b,s) (BHB measures allocation against zero).
- Groups: the security's sector; a fund (no sector) by its family's style from `srm.fund_profile` (Stock Funds, Bond
  Funds …, else Unclassified), so a blended benchmark's stock / bond mix shows as allocation; the account's cash
  (`srm.portfolio.cash_balance`, today's — applied to every month) as the group Cash, earning the 3-month Treasury
  yield.
- Carino linking, so the linked effects add up to the compounded active return (`effects.residual` ≈ 0).
- Also: per-period effects, sector table, top and bottom contributors, data gaps, and a `decisionContext`
  (`publish`, or `review` when prices are missing for more than 2% of weight or the residual is not zero).
- Weights per month: the latest portfolio and benchmark snapshots on or before the month's first day (the start date for
  the first month), else the nearest later snapshot; share holdings are valued with prices on the snapshot date.
  `assumptions` lists which months used which snapshot dates, each period row carries `portfolioSnapshot` and
  `benchmarkSnapshot`, and `snapshots` summarises the runs, the months that used a later snapshot and the history
  available. Months on a later snapshot add a `decisionContext` reason (so `review`). `byGroup` and contributor weights
  are the average of the monthly start weights.

Why Python: database queries, aligning price histories, estimating statistics and shaping reports — the parts that
change most often. The heavy optimization loops go to Java (active) and C++ (tracking, risk).
