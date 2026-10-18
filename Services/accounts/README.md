# accounts — personal accounts in the security master

Python Layer 3 service (port **8774**) that keeps **MxPortMGR's My Portfolio** in MxDataHUB's security master
(PostgreSQL schema `srm`, migration **V011**), so the sandboxed app needs no database credentials.

| Endpoint | What it does |
| --- | --- |
| `GET /securities?q=&kind=&offset=&limit=&sort=&dir=&facets=` | Search by ticker, name, ISIN or CUSIP; `kind` = `all`, `stocks`, `funds`, `bonds` (bond and other fixed-income funds); a page at a time (`limit` ≤ 500) with the `total`; `sort` = `relevance` (default), `ticker`, `name`, `type`, `sector`, `exchange`, `price`, `asOf`, `marketCap` and `dir` = `asc` / `desc`; column filters `ticker`, `name` (contains), `type`, `sector`, `exchange` (comma-separated, `(none)` for blanks), `priceMin`, `priceMax`, `priced` (1 / 0); `facets=1` adds each filterable column's values with counts |
| `GET /benchmarks` | Benchmarks with members and snapshot date |
| `GET /benchmarks/<code>/weights` | The latest weights with ticker, name, sector and asset class |
| `GET /accounts` | Personal accounts (`srm.v_personal_account`) |
| `GET /accounts/<code>` | An account — type, approach, benchmark, cash — with its open tax lots valued at the latest prices |
| `PUT /accounts/<code>` | Create or replace the account and its lots (`{name, accountType, approach, benchmark, cash, lots: [{securityId, acquired, quantity, costBasis}]}`); rewrites today's holdings snapshot with `srm.sync_holdings_from_lots` |
| `POST /accounts/<code>/load-prices` | Asks srm-loader (8770) to run `srm.py load nasdaq-prices --symbols …` (Nasdaq.com, free, no key) for unpriced holdings |

```bash
python3 Services/mxservices.py start accounts     # or: python3 accounts_service.py --port 8774
curl -s 'http://127.0.0.1:8774/securities?q=AGG&kind=bonds'
```

Needs `psycopg2`; the connection comes from SRM's own configuration (`MxDataHUB/SRM/README.md`). Listens on
127.0.0.1 only; `--token` (or `MXJOBS_SERVICE_TOKEN`) requires `Authorization: Bearer <token>`.
