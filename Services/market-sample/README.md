# Market data sample service

A Layer 3 data service on this Mac: quotes, price history and indicators as JSON over HTTP.
Standard library only (Python 3.9+), so it runs with the `python3` that comes with macOS's developer tools.

```bash
python3 mxjobs_service.py                     # http://127.0.0.1:8765
python3 mxjobs_service.py --port 9000
python3 mxjobs_service.py --token s3cret       # require "Authorization: Bearer s3cret"
```

| Endpoint | Returns |
| -------- | ------- |
| `GET /health` | `{"status": "ok", ...}` |
| `GET /quote?symbol=AAPL` | price, previous close, change, change % |
| `GET /history?symbol=AAPL&days=60` | daily closes, oldest first |
| `GET /indicators?symbol=AAPL&window=14` | `sma`, `ema`, `rsi`, `last` over the history |
| `POST /indicators` `{"prices": [...], "window": 14}` | the same for prices you send |

The prices are **synthetic** — a repeatable random walk per symbol — so jobspaces can be built and tested
without a data subscription. Replace `history()` with a real source (an API, a database, pandas) to make it live;
the endpoints stay the same.

It listens on `127.0.0.1` only. MxJobsMGR reaches it through a **Local Python service** subscription
(API Subscriptions ▸ + ▸ Local Python Service): base URL `http://127.0.0.1:8765`, authentication
"Local service (optional token)" — store a token there only if you start the service with `--token`.
The sample jobspace's **Indicators (local Python)** step calls `/indicators` and feeds **Score signals (Python)**.
