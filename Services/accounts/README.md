# accounts — personal accounts in the security master

Python Layer 3 service (port **8774**) that keeps **MxPortMGR's My Portfolio** in MxDataHUB's security master
(PostgreSQL schema `srm`, migration **V011**), so the sandboxed app needs no database credentials.

| Endpoint | What it does |
| --- | --- |
| `GET /securities?q=&kind=&limit=` | Search by ticker, name, ISIN or CUSIP; `kind` = `all`, `stocks`, `funds`, `bonds` (bond and other fixed-income funds); with the latest price, beta and market cap |
| `GET /benchmarks` | Benchmarks with members and snapshot date |
| `GET /benchmarks/<code>/weights` | The latest weights with ticker, name, sector and asset class |
| `GET /accounts` | Personal accounts (`srm.v_personal_account`) |
| `GET /accounts/<code>` | An account — type, approach, benchmark, cash — with its open tax lots valued at the latest prices |
| `PUT /accounts/<code>` | Create or replace the account and its lots (`{name, accountType, approach, benchmark, cash, lots: [{securityId, acquired, quantity, costBasis}]}`); rewrites today's holdings snapshot with `srm.sync_holdings_from_lots` |
| `POST /accounts/<code>/load-prices` | Asks srm-loader (8770) to run `srm.py load fmp-prices --symbols …` for unpriced holdings |

```bash
python3 Services/mxservices.py start accounts     # or: python3 accounts_service.py --port 8774
curl -s 'http://127.0.0.1:8774/securities?q=AGG&kind=bonds'
```

Needs `psycopg2`; the connection comes from SRM's own configuration (`MxDataHUB/SRM/README.md`). Listens on
127.0.0.1 only; `--token` (or `MXJOBS_SERVICE_TOKEN`) requires `Authorization: Bearer <token>`.
