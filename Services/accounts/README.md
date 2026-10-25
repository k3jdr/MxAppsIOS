# accounts — personal accounts in the security master

Python Layer 3 service (port **8774**) that keeps **MxAcctMGR's My Portfolio** in MxDataHUB's security master
(PostgreSQL schema `srm`, migration **V011**), so the sandboxed app needs no database credentials.

| Endpoint | What it does |
| --- | --- |
| `GET /securities?q=&kind=&offset=&limit=&sort=&dir=&facets=` | Search by ticker, name, ISIN or CUSIP; `kind` = `all`, `stocks`, `funds`, `bonds` (bond and other fixed-income funds); a page at a time (`limit` ≤ 500) with the `total`; `sort` = `relevance` (default), `ticker`, `name`, `type`, `sector`, `exchange`, `price`, `asOf`, `marketCap` and `dir` = `asc` / `desc`; column filters `ticker`, `name` (contains), `type`, `sector`, `exchange` (comma-separated, `(none)` for blanks), `priceMin`, `priceMax`, `priced` (1 / 0); `facets=1` adds each filterable column's values with counts. Every price here, in browse, account lots and month-end prices is in dollars (`srm.last_price` / `srm.fx_to_usd`, V021): a London or Toronto line is converted, never shown in pence as dollars |
| `GET /benchmarks` | Benchmarks with members and snapshot date |
| `GET /benchmarks/<code>/weights` | The latest weights with ticker, name, sector and asset class |
| `GET /accounts` | Personal accounts (`srm.v_personal_account`) |
| `GET /accounts/<code>` | An account — type, approach, benchmark, cash — with its open tax lots valued at the latest prices |
| `PUT /accounts/<code>` | Save the account as its next version (`{version, name, accountType, approach, benchmark, cash, settings, by, note, lots: [{securityId, acquired, quantity, costBasis, note}]}`). `version` is the version the edit was made from — 0 for a new account; when the account has moved on (saved elsewhere, or already exists) the answer is **409** with the current `version`, `updatedAt`, `updatedBy` and nothing changes. Rewrites today's holdings snapshot with `srm.sync_holdings_from_lots` and keeps the saved version whole in `srm.portfolio_version` (V022) |
| `GET /accounts/<code>/versions` | Every saved version, newest first: when, by whom, account fields, cash, lots and cost |
| `GET /accounts/<code>/decisions`, `POST` | A portfolio's decisions, newest first; POST `{title, rationale, category, decidedOn, by}` records one with the portfolio's version (append-only, V023) |
| `POST /accounts/<code>/duplicate` | A new portfolio `{code, name}` from this one's saved version (lots, cash, benchmark, settings), version 1, with a decision noting where it came from; 409 when the code exists |
| `GET /benchmarks/policy`, `/benchmarks/policy/<code>` | Policy benchmarks with their dated mixes |
| `PUT /benchmarks/policy/<code>` | Define a policy benchmark: `{name, mixes: [{effectiveFrom, components: [{ticker or securityId, weight}]}], by}`; each mix adds up to 1; replaces the earlier mixes, then has the srm-loader service write the snapshots (`policy-benchmarks`); 409 for a market benchmark's code |
| `POST /securities/resolve` | `{tickers}` → `{securities: {TICKER: security with its latest price}, unknown}`: the current U.S. listing, else any current listing (mutual funds) — Import Holdings |
| `POST /accounts/<code>/close`, `/reopen` | Close a portfolio (kept, not deleted) or open it again; `{version}` checked like a save |
| `POST /accounts/<code>/load-prices` | Asks srm-loader (8770) to run `srm.py load nasdaq-prices --symbols …` (Nasdaq.com, free, no key) for unpriced holdings |
| `GET /bank/accounts`, `PUT /bank/accounts/<code>` | Checking accounts (V027) with register, cleared and PNC balances; PUT `{name, institution, last4, openingDate, openingBalance}` creates or changes one (last four digits only, never the whole number) |
| `GET /bank/accounts/<code>/register` | The shared check register, oldest first with the running balance, and the bank's lines no entry matches |
| `POST /bank/accounts/<code>/transactions` | Add an entry `{date, kind (check, debit, deposit, transfer, fee, interest), checkNo, payeeId or payee, expenseAccountId, memo, amount, by}`; a check number already in the register is **409**; then matches the bank's lines |
| `PUT /bank/transactions/<id>` | Change an entry `{version, …, status (open, cleared, reconciled, void)}`: **409** when someone changed it since. Entries are voided, never deleted |
| `POST /bank/lines/<id>/accept`, `/match` | Add the bank's line to the register (cleared; its payee found by the bank's name for it, which is remembered), or match it to an entry `{txnId}` |
| `POST /bank/accounts/<code>/import` | Asks srm-loader (8770) to run `srm.py load pnc-bank` (the PNC downloads in the drop folders) and answers with the register |
| `GET /expense-accounts`, `PUT /expense-accounts/<id>`, `PUT /payees/<id>`, `PUT /payees/<id>/note` | Expense accounts with their payees, this year's totals (`yearTotal`) and every year's (`totalPaid`); create (id 0) or change an expense account or a payee (a target account: `{version, name, nickname, description, status (active / inactive / closed), reference (its identifier), institution, last4, expenseAccountId, defaultAmount, nextPaymentDate, nextPaymentAmount, logonUrl, userName, address1, address2, city, state, zipCode, phone, notes, bankNames, fundingSources (checking and / or card: the registers whose target lists offer it)}`, V033; version-checked; a change keeps what it doesn't send, and a name another target account has (in any case) is refused with 409, and the names an older MxAcctMGR sends — address, website, active — still work; never a password: MxAcctMGR keeps those in the Keychain; `/note` changes only the note the register shows on hover, V028) |
| `GET /cards/targets`, `POST /cards/targets` | The names card entries carry without a target account, as the card company gives them (entries, total, first and last date, kinds; `merchant` false for the card company's own lines); POST `{names, by}` makes each a target account with the card funding source, in the category its entries mostly have, and links those entries to it (a name an account already has just gains the card source) |
| `PUT /payees/<id>/link`, `DELETE /payees/<id>/link` | A target account's link (`srm.payee_link`, V032): `{address, text, hoverText, hoverRtf, title, by}` — a web page, an email address or a page in MxNoteONE, with words of its own and formatted hover text. It comes with the account wherever it is a target: each register entry's `payeeLink` (checking and card registers) and each payee's `link`, `{address, text, tip, title}` or null |
| `GET /earnings/calendar?from=&to=` | FMP's earnings calendar for up to 62 days: `rows` of `{symbol, date, epsEstimated, epsActual, revenueEstimated, revenueActual, lastUpdated}`. Fetched a week per call (a call returns at most 4,000 rows, latest first, and is split further if it hits that). The plan reaches back 12 months: an earlier `from` is cut at `planStart`, and `notOnPlan` gives the range left out |
| `POST /links/query` | Links on securities' tickers and names (`srm.security_link`, V014) for `{securityIds: [...], tickers: [...]}`: `links` of `{securityId, field: ticker\|name, address, text, hoverText, hoverRtf, title, updatedAt, updatedBy}`; tickers resolve to their current U.S. listing (`srm.us_security`) and come back in `resolved` |
| `PUT /links/<securityId>/<ticker\|name>` | Add or change a link: `{address, text, hoverText, hoverRtf, title, by}` |
| `DELETE /links/<securityId>/<ticker\|name>` | Take it off |
| `GET /earnings/history?symbol=&limit=` | One company's reports from FMP (`earnings`), newest first, back decades; `limit` ≤ 200 (default 40) |
| `GET /fundamentals/quarters?symbol=&limit=&source=` | A company's quarterly revenue, operating cash flow, capex, depreciation and free cash flow, newest first — MxAcctMGR's Compute screen. From the security master (`srm.fundamental_quarter`, V015) when `srm.py load fmp-fundamentals` loaded the company in the last 14 days, else from FMP (`source=fmp` asks FMP); `source` in the answer says which. When the database can't be reached it goes to FMP for 5 minutes without trying again |
| `POST /securities/lookup` | `{tickers: [...]}` → `securities` by ticker: the security master's security (current U.S. listing, OTC included) with `securityId`, `name`, `securityType`, `mic`, `country`, `marketCap` — Earnings by Day names the companies only FMP's calendar lists with it |
| `GET /market/series` | The market series in the security master (V015: VIX9D, VIX, VIX3M, VIX6M; DGS1MO … DGS30; USREC) with source, count, first and last date and last value |
| `GET /market/series?ids=&from=&format=` | Their values as CSV in the sources' own layouts, so MxAcctMGR parses them as it parses the files: `format=csv` (default) as FRED's `fredgraph.csv` (`observation_date`, one column per id, blank when missing); `format=ohlc` with one id as Cboe's history file (`DATE,OPEN,HIGH,LOW,CLOSE`, MM/DD/YYYY). MxAcctMGR's VIX and Yield Curve screens use them when the last value is recent, else read Cboe and FRED |
| `POST /securities/browse` | MxDataHUB's Securities search for MxAcctMGR's Library ▸ Securities: `{q, type, benchmark, activeOnly, offset, limit ≤ 1000, sort {column, ascending}, filters {column: {values: […]} or {op, v1, v2}}}` → `securities` (with `price`, `priceDate`, `marketCap`; Price, As of and Market value sort and filter as numbers / dates), `total`; priced and largest first after the identifier matches |
| `POST /securities/browse/values` | A column's distinct values with their counts under the search and the other filters (`{…, column}`), for its filter panel |
| `GET /securities/<id>/detail` | A security's facts, identifiers, listings, classification, benchmark membership, corporate actions and last 400 days of closes (of the listing `srm.last_price` prices it from, in dollars) |
| `GET /security-types` | The security types, for the Type filter |

```bash
python3 Services/mxservices.py start accounts     # or: python3 accounts_service.py --port 8774
curl -s 'http://127.0.0.1:8774/securities?q=AGG&kind=bonds'
```

Needs `psycopg2`; the connection comes from SRM's own configuration (`MxDataHUB/SRM/README.md`). The earnings
endpoints don't touch the database (the fundamentals endpoint reads it when it can): they use SRM's FMP key (`FMP_API_KEY`, Keychain `SRM-api` / `fmp`, or
`config.local.json`), so the sandboxed MxAcctMGR needs no key of its own. Answers are cached in the process (15
minutes for recent weeks, 12 hours for older ones). Listens on
127.0.0.1 only; `--token` (or `MXJOBS_SERVICE_TOKEN`) requires `Authorization: Bearer <token>`.
