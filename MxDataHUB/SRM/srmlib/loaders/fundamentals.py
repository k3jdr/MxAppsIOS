"""Company quarterly fundamentals from FMP's statements (srm.fundamental_quarter, V015): revenue and operating income
(income statement), operating cash flow, capital expenditure, depreciation and amortisation, and free cash flow
(cash-flow statement), joined by the quarter's end date. Capex is stored as a positive amount.

Work set: srm.fundamental_watch (the Compute theme's hyperscalers and suppliers), or --symbols. Two calls a company;
the first load reads 40 quarters (10 years), later ones the last 8 — enough to pick up restatements — unless --force.
"""

import datetime

from ..common import HTTPError, LoadRun, log
from ..model import fmp_symbol, source_id
from .fmp import FMP, PlanLimit

FIRST_QUARTERS = 40
RECENT_QUARTERS = 8


def _date(text):
    try:
        return datetime.date.fromisoformat((text or "")[:10])
    except ValueError:
        return None


def _amount(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def quarters(cash, income):
    """FMP's cash-flow and income statements (lists of quarter dicts) joined by date, newest first."""
    by_date = {r.get("date"): r for r in income if isinstance(r, dict)}
    out = []
    for r in cash:
        if not isinstance(r, dict) or not _date(r.get("date")):
            continue
        i = by_date.get(r["date"], {})
        capex = _amount(r.get("capitalExpenditure"))
        out.append({
            "period_end": _date(r["date"]), "fiscal_year": r.get("fiscalYear") or i.get("fiscalYear"),
            "fiscal_period": r.get("period") or i.get("period"),
            "filing_date": _date(r.get("filingDate") or i.get("filingDate")),
            "currency": (r.get("reportedCurrency") or i.get("reportedCurrency") or "")[:3] or None,
            "revenue": _amount(i.get("revenue")), "operating_income": _amount(i.get("operatingIncome")),
            "operating_cash_flow": _amount(r.get("operatingCashFlow")),
            "capex": -capex if capex is not None else None,
            "depreciation": _amount(r.get("depreciationAndAmortization")),
            "free_cash_flow": _amount(r.get("freeCashFlow")),
        })
    return sorted(out, key=lambda q: q["period_end"], reverse=True)


def run(conn, cfg, args):
    with LoadRun(conn, "FMP", "fmp_fundamentals", {"symbols": args.symbols, "force": args.force}) as run, \
            conn.cursor() as cur:
        api = FMP(cfg, run)
        fmp = source_id(cur, "FMP")
        if args.symbols:
            symbols = [s.upper() for s in args.symbols]
        else:
            cur.execute("SELECT symbol FROM srm.fundamental_watch WHERE is_active ORDER BY sort_order, symbol")
            symbols = [r[0] for r in cur.fetchall()]
        symbols = symbols[: args.max or None]
        cur.execute("SELECT DISTINCT symbol FROM srm.fundamental_quarter WHERE symbol = ANY(%s)", (symbols,))
        loaded = {r[0] for r in cur.fetchall()}
        log(f"  {len(symbols)} companies: {', '.join(symbols)}")
        for symbol in symbols:
            limit = RECENT_QUARTERS if symbol in loaded and not args.force else FIRST_QUARTERS
            try:
                cash = api.get("cash-flow-statement", symbol=fmp_symbol(symbol), period="quarter", limit=limit)
                income = api.get("income-statement", symbol=fmp_symbol(symbol), period="quarter", limit=limit)
            except PlanLimit as e:
                run.status, run.message = "partial", str(e)
                log("  " + str(e))
                break
            except HTTPError as e:
                run.reject(symbol, str(e))
                continue
            rows = quarters(cash if isinstance(cash, list) else [], income if isinstance(income, list) else [])
            if not rows:
                run.reject(symbol, "FMP has no quarterly statements for this symbol")
                continue
            run.read += len(rows)
            inserted = updated = 0
            for q in rows:
                cur.execute("""
                    INSERT INTO srm.fundamental_quarter (symbol, period_end, security_id, fiscal_year, fiscal_period,
                           filing_date, reported_currency, revenue, operating_income, operating_cash_flow, capex,
                           depreciation, free_cash_flow, source_id, load_id)
                    VALUES (%(symbol)s, %(period_end)s, srm.us_security(%(symbol)s), %(fiscal_year)s, %(fiscal_period)s,
                            %(filing_date)s, %(currency)s, %(revenue)s, %(operating_income)s, %(operating_cash_flow)s,
                            %(capex)s, %(depreciation)s, %(free_cash_flow)s, %(source)s, %(load)s)
                    ON CONFLICT (symbol, period_end) DO UPDATE SET
                        security_id = coalesce(excluded.security_id, srm.fundamental_quarter.security_id),
                        fiscal_year = excluded.fiscal_year, fiscal_period = excluded.fiscal_period,
                        filing_date = excluded.filing_date, reported_currency = excluded.reported_currency,
                        revenue = excluded.revenue, operating_income = excluded.operating_income,
                        operating_cash_flow = excluded.operating_cash_flow, capex = excluded.capex,
                        depreciation = excluded.depreciation, free_cash_flow = excluded.free_cash_flow,
                        source_id = excluded.source_id, load_id = excluded.load_id, updated_at = now()
                     WHERE (srm.fundamental_quarter.revenue, srm.fundamental_quarter.operating_income,
                            srm.fundamental_quarter.operating_cash_flow, srm.fundamental_quarter.capex,
                            srm.fundamental_quarter.depreciation, srm.fundamental_quarter.free_cash_flow,
                            srm.fundamental_quarter.filing_date, srm.fundamental_quarter.fiscal_period,
                            srm.fundamental_quarter.fiscal_year)
                           IS DISTINCT FROM
                           (excluded.revenue, excluded.operating_income, excluded.operating_cash_flow, excluded.capex,
                            excluded.depreciation, excluded.free_cash_flow, excluded.filing_date,
                            excluded.fiscal_period, excluded.fiscal_year)
                    RETURNING (xmax = 0)""", dict(q, symbol=symbol, source=fmp, load=run.load_id))
                result = cur.fetchone()
                if result:
                    inserted += result[0]
                    updated += not result[0]
            run.inserted += inserted
            run.updated += updated
            conn.commit()
            latest = rows[0]
            log(f"  {symbol}: {len(rows)} quarters to {latest['period_end']} ({latest['fiscal_period']} "
                f"FY{latest['fiscal_year']}), {inserted} new, {updated} changed")
        if run.rejected and not run.read:
            raise RuntimeError("FMP returned no statements for any company")
