# SRM loader service

The Layer 3 service behind **MxDataHUB ▸ Data Refresh** and MxJobsWMS's **SRM Daily Refresh** workflow: it refreshes
the security master (`MxDataHUB/SRM/srm.py`) by data category or one loader at a time, and reports freshness and
data quality. Start it with the others: `python3 Services/mxservices.py start`.

```bash
python3 srm_service.py                       # http://127.0.0.1:8770; finds ../../MxDataHUB/SRM
python3 srm_service.py --srm-dir /path/to/MxDataHUB/SRM --port 8770 --stale-days 2
```

Needs what `srm.py` needs: Python 3.9+ with `psycopg2` (Apple's `python3` has it here), and srm.py's own
database and API-key configuration (environment, Keychain `SRM-postgres` / `SRM-api`, or `config.local.json`).

| Endpoint | What it does |
| -------- | ------------ |
| `GET /health`, `GET /describe` | service status, SRM folder, whether a load is running; what the service is for |
| `GET /categories` | the data categories (reference data, listed universe & issuers, benchmark constituents, identifiers & issuer data, prices & index levels, corporate actions, bonds — U.S. Treasuries —, market series — VIX & Treasury yields, company fundamentals — and the optional portfolio snapshots) with their loaders, last load, data date, `optional` and a state: `fresh`, `due`, `stale`, `failed`, `never` — daily categories are fresh up to 1 business day old by their data date (benchmark constituents 2: SPDR files are published the next business morning; custom benchmarks don't count) |
| `POST /refresh/<category>` | runs the category's loaders in order (stops at the first failure); honours `X-SRM-Dry-Run` |
| `GET /loaders` | the loaders in `srm.py`'s dependency order (19, with the optional `mutual-funds` and `portfolio-snapshots`) |
| `POST /load/<loader>` | runs `srm.py load <loader>` and returns its `srm.load_run` rows, the worst status (`succeeded` / `partial` / `failed`), totals and the output tail |
| `GET /status` | read-only: migrations, row counts, identifier coverage, benchmarks, `snapshotHistory` (dated weight snapshots per benchmark and portfolio, from `srm.v_snapshot_coverage`), price freshness, recent loads, and data-quality `checks` with a `summary` |
| `GET /log?after=<seq>&limit=` | live activity: every line `srm.py` prints while a load runs (sent as it is printed), and `run-start` / `loader-start` / `loader-end` / `run-end` events with status, time and row counts; each entry has `seq`, `time`, `level` (`info` / `warning` / `error` / `debug`), `loader`, `run`, `event`, `text`, and on run events `name`, on `-end` events `status` and `seconds`. Poll with the last `seq` seen; `running` is the refresh or load running now. In memory, the last 20,000 lines (MxDataHUB ▸ Data Refresh ▸ Activity) |

`/load` options (query parameters, only srm.py's own): `max`, `since` (YYYY-MM-DD), `months`, `force=1`,
`history=1`, `allSecurities=1`, `includeOtc=1`, `symbols=AAPL,MSFT`, `benchmarks=SP500 DJIA`, and `verbosity=1` or `2`
(on `/refresh` too): srm.py's `-v` / `-vv`, whose detail lines come back in `/log` with level `debug`.

**Dry run:** with the header `X-SRM-Dry-Run: 1` a load returns `{"status": "dry-run", "command": "srm.py load …"}`
without running. The sample jobspace's subscription sends it; remove the header there to load for real.

Safety: unknown loaders and options are refused, symbols are validated, loads run one at a time (409 while busy),
it listens on 127.0.0.1 only, and `--token` (or `MXJOBS_SERVICE_TOKEN`) requires `Authorization: Bearer …`.

Data-quality checks in `/status` (`fail` blocks the jobspace's status step until the data steward decides,
`warn` is informational):

| Check | Fails when |
| ----- | ---------- |
| benchmark *X* fresh | constituents older than `--stale-days` business days (the Vanguard funds' month-end holdings, VTSM VTBM VTISM VTIB: older than 45) |
| benchmark *X* weights sum to 1 | weight sum off by more than 0.001 |
| prices fresh | last price date older than `--stale-days` business days |
| benchmark members with ISIN / CUSIP / composite FIGI ≥ 95% | coverage below 95% (warning) |
| no failed loads among the last 12 | any of them failed |
| snapshot history | a benchmark or portfolio has fewer than 2 weight snapshots, or more than 35 days between two (warning: attribution then uses a later or older snapshot for some months) |
