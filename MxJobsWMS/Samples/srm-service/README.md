# MxJobsWMS SRM loader service

A Layer 3 service that lets an MxJobsWMS jobspace run **MxDataSRM's daily securities-master refresh**
(`MxDataSRM/SRM/srm.py`) one loader at a time and read its data-quality status.

```bash
python3 srm_service.py                       # http://127.0.0.1:8770; finds ../../../MxDataSRM/SRM
python3 srm_service.py --srm-dir /path/to/MxDataSRM/SRM --port 8770 --stale-days 2
```

Needs what `srm.py` needs: Python 3.9+ with `psycopg2` (Apple's `python3` has it here), and srm.py's own
database and API-key configuration (environment, Keychain `SRM-postgres` / `SRM-api`, or `config.local.json`).

| Endpoint | What it does |
| -------- | ------------ |
| `GET /health` | service status, SRM folder, whether a load is running |
| `GET /loaders` | the 12 loaders in `srm.py`'s dependency order |
| `POST /load/<loader>` | runs `srm.py load <loader>` and returns its `srm.load_run` rows, the worst status (`succeeded` / `partial` / `failed`), totals and the output tail |
| `GET /status` | read-only: migrations, row counts, identifier coverage, benchmarks, price freshness, recent loads, and data-quality `checks` with a `summary` |

`/load` options (query parameters, only srm.py's own): `max`, `since` (YYYY-MM-DD), `months`, `force=1`,
`history=1`, `allSecurities=1`, `includeOtc=1`, `symbols=AAPL,MSFT`, `benchmarks=SP500 DJIA`.

**Dry run:** with the header `X-SRM-Dry-Run: 1` a load returns `{"status": "dry-run", "command": "srm.py load …"}`
without running. The sample jobspace's subscription sends it; remove the header there to load for real.

Safety: unknown loaders and options are refused, symbols are validated, loads run one at a time (409 while busy),
it listens on 127.0.0.1 only, and `--token` (or `MXJOBS_SERVICE_TOKEN`) requires `Authorization: Bearer …`.

Data-quality checks in `/status` (`fail` blocks the jobspace's status step until the data steward decides,
`warn` is informational):

| Check | Fails when |
| ----- | ---------- |
| benchmark *X* fresh | constituents older than `--stale-days` business days |
| benchmark *X* weights sum to 1 | weight sum off by more than 0.001 |
| prices fresh | last price date older than `--stale-days` business days |
| benchmark members with ISIN / CUSIP / composite FIGI ≥ 95% | coverage below 95% (warning) |
| no failed loads among the last 12 | any of them failed |
