"""MxAcctMGR's sample accounts as security-master portfolios, built only from real securities and their prices.

Each sample teaches one edge case a personal investor meets (a concentrated employer stock, a sector bet, income,
idle cash, frequent trading, a drifted index tracker, tax lots at gains and losses, a 60/40 outside its band,
missing data, core and satellite). It is stored like My Portfolio — an srm.portfolio with account type, approach,
benchmark, cash and open tax lots (managed_by 'MxAcctMGR samples'), its holdings snapshot written from the lots —
so the accounts service, the analytics service (inputs, attribution) and MxDataHUB see it like any other account.

How the numbers are made: each holding has a target share of the account's value today; its quantity is that value
at the latest price, split across its lots; a lot's cost is its quantity at the security's close on the purchase date
(FMP's split-adjusted closes, or a mutual fund's NAV; history before the security master's is loaded from FMP first).
So gains, losses, holding periods and drift are what the market really did. The lessons' words live in MxAcctMGR.

Also two blended benchmarks for the balanced samples, BAL6040 (VTI 60%, BND 40%) and BAL3070 (30/70), with a month-end
snapshot for the last two years so attribution can use them.

Rerunning replaces each sample's lots (never touching other portfolios).
"""

import argparse
import datetime

import psycopg2.extras

from ..common import LoadRun, log
from ..model import source_id
from . import fmp as fmp_loader

MANAGED_BY = "MxAcctMGR samples"
TODAY = datetime.date.today()

BLENDS = [("BAL6040", "Balanced 60/40 (VTI / BND)", {"VTI": 0.6, "BND": 0.4}),
          ("BAL3070", "Income 30/70 (VTI / BND)", {"VTI": 0.3, "BND": 0.7})]


def recent(months_back):
    """A purchase date about this many months ago (a weekday)."""
    d = TODAY - datetime.timedelta(days=int(months_back * 30.44))
    while d.weekday() >= 5:
        d -= datetime.timedelta(days=1)
    return d.isoformat()


# code, name, account type, approach, benchmark, value today, cash share,
# holdings: (ticker, share of value, [(purchase date, share of the holding)]) — one lot a year ago when not given.
SAMPLES = [
    ("SAMPLE_CORE_SATELLITE", "Core & Satellite (active)", "retirement", "active", "SP500", 180_000, 0.0, [
        ("VTI", 0.70, [("2024-11-04", 1)]),
        ("MSFT", 0.04, None), ("NVDA", 0.04, None), ("LLY", 0.04, None), ("JPM", 0.035, None),
        ("CAT", 0.035, None), ("GOOGL", 0.04, None), ("ISRG", 0.035, None), ("COST", 0.035, None)]),
    ("SAMPLE_EMPLOYER_STOCK", "Concentrated Employer Stock", "taxable", None, "SP500", 420_000, 0.05, [
        ("MSFT", 0.48, [("2012-06-15", 0.55), ("2017-03-01", 0.30), (recent(7), 0.15)]),
        ("VTSAX", 0.37, [("2019-01-10", 1)]), ("VBTLX", 0.10, [("2021-08-02", 1)])]),
    ("SAMPLE_TECH_HEAVY", "Sector-Heavy Technology", "taxable", "active", "SP500", 150_000, 0.0, [
        ("XLK", 0.25, [("2020-02-03", 1)]), ("NVDA", 0.12, [("2021-11-08", 1)]), ("MSFT", 0.12, [("2019-05-20", 1)]),
        ("AVGO", 0.12, [("2023-01-12", 1)]), ("AMD", 0.08, [("2024-03-04", 1)]), ("META", 0.07, [("2022-09-14", 1)]),
        ("GOOGL", 0.07, [("2020-07-01", 1)]), ("VTI", 0.17, [("2018-04-02", 1)])]),
    ("SAMPLE_INCOME", "Retiree Income (bond-heavy)", "retirement", None, "BAL3070", 900_000, 0.06, [
        ("BND", 0.25, None), ("LQD", 0.14, None), ("MUB", 0.06, None), ("TLT", 0.10, None), ("TIP", 0.06, None),
        ("SHY", 0.05, None), ("NEE", 0.04, None), ("DUK", 0.03, None), ("PG", 0.04, None), ("KO", 0.03, None),
        ("VZ", 0.04, None), ("KMI", 0.04, None), ("O", 0.03, None), ("AMT", 0.03, None)]),
    ("SAMPLE_CASH_HEAVY", "Cash-Heavy, Waiting to Invest", "taxable", "passive", "BAL6040", 240_000, 0.45, [
        ("VTSAX", 0.35, [("2016-09-12", 1)]), ("VBTLX", 0.20, [("2020-03-23", 1)])]),
    ("SAMPLE_TRADER", "High-Turnover Trader", "taxable", "active", "SP500", 85_000, 0.12, [
        ("TSLA", 0.12, [(recent(2), 1)]), ("PLTR", 0.12, [(recent(1.5), 1)]), ("SMCI", 0.10, [(recent(3), 1)]),
        ("COIN", 0.10, [(recent(1), 1)]), ("MSTR", 0.10, [(recent(4), 1)]), ("RIVN", 0.08, [(recent(1.5), 1)]),
        ("AMD", 0.08, [(recent(0.7), 1)]), ("NFLX", 0.10, [(recent(5), 1)]), ("FCX", 0.08, [(recent(2.5), 1)])]),
    ("SAMPLE_TAX_LOTS", "Tax-Lot Harvesting Case", "taxable", None, "BAL6040", 520_000, 0.06, [
        ("VTSAX", 0.42, [("2013-02-11", 0.40), ("2020-03-20", 0.25), (recent(9), 0.35)]),
        ("NFLX", 0.08, [("2021-11-01", 0.6), ("2024-02-01", 0.4)]),
        ("INTC", 0.05, [("2022-01-04", 1)]),
        ("MSFT", 0.06, [("2015-07-01", 1)]),
        ("VBTLX", 0.25, [("2021-06-01", 0.7), (recent(10), 0.3)]),
        ("TLT", 0.08, [("2020-07-15", 1)])]),
    ("SAMPLE_6040_DRIFT", "60/40 Outside Its Band", "retirement", "passive", "BAL6040", 640_000, 0.03, [
        ("VTI", 0.71, [("2023-01-03", 1)]), ("BND", 0.26, [("2023-01-03", 1)])]),
    ("SAMPLE_MISSING_DATA", "Missing & Messy Data", "taxable", "active", "SP500", 95_000, 0.0, [
        ("MSFT", 0.14, [("2019-03-01", 1)]), ("ACVA", 0.06, [("2024-11-01", 1)]), ("ALUB.U", 0.08, [("2025-11-14", 1)]),
        ("NFLX", 0.10, [("2021-04-01", 1)]), ("KO", 0.10, [("2020-06-01", 1)]), ("RIVN", 0.10, [("2024-11-01", 1)]),
        ("VTI", 0.42, [("2017-01-03", 1)])]),
]
DRIFTED = ("SAMPLE_DRIFTED_TRACKER", "Direct-Index Tracker, Drifted", "taxable", "passive", "SP500", 310_000,
           "2024-10-21", 22)


def security(cur, ticker):
    """The security for a ticker: its current U.S. listing, else the latest one it had (a delisted security)."""
    cur.execute("""SELECT coalesce(srm.us_security(%s),
                                   (SELECT l.security_id FROM srm.listing l WHERE l.ticker = %s
                                     ORDER BY l.valid_to DESC, l.is_primary DESC LIMIT 1))""", (ticker, ticker))
    return cur.fetchone()[0]


def price_on(cur, security_id, day):
    """The close on or before a day: FMP's (split-adjusted) first, else any source (a fund's NAV, Massive)."""
    cur.execute("""SELECT p.close FROM srm.price p JOIN srm.listing l USING (listing_id) JOIN srm.data_source d USING (source_id)
                    WHERE l.security_id = %s AND p.price_date <= %s AND p.price_date >= %s::date - 10
                    ORDER BY (d.code = 'FMP') DESC, p.price_date DESC LIMIT 1""", (security_id, day, day))
    row = cur.fetchone()
    return float(row[0]) if row else None


def last_price(cur, security_id):
    cur.execute("SELECT close FROM srm.last_price(%s)", (security_id,))
    row = cur.fetchone()
    return float(row[0]) if row else None


def ensure_history(conn, cfg, cur, needs):
    """FMP history back to each security's earliest purchase date, where the security master's starts later."""
    work = []
    for security_id, earliest in needs.items():
        cur.execute("""SELECT min(p.price_date), max(v.fmp_symbol), max(v.security_type)
                         FROM srm.v_security v LEFT JOIN srm.listing l USING (security_id)
                         LEFT JOIN srm.price p USING (listing_id) WHERE v.security_id = %s""", (security_id,))
        first, symbol, sec_type = cur.fetchone()
        if sec_type != "Mutual Fund" and symbol and (first is None or first > earliest):
            work.append((security_id, symbol, earliest))
    if not work:
        return
    since = min(w[2] for w in work).isoformat()
    log(f"  FMP history from {since} for {len(work)} securities: {', '.join(w[1] for w in work)}")
    fmp_loader.load_prices(conn, cfg, argparse.Namespace(symbols=None, security_symbols=[(w[0], w[1]) for w in work],
                                                         since=since, max=None, force=True, backfill=True,
                                                         all_securities=False))


def write_blends(cur, run, src):
    for code, name, parts in BLENDS:
        cur.execute("""INSERT INTO srm.benchmark (code, name, provider, weighting_method, currency_code, constituent_source,
                                                  description)
                       VALUES (%s, %s, 'MxAcctMGR', 'custom', 'USD', 'Fixed blend of index ETFs, rebalanced monthly', %s)
                       ON CONFLICT (code) DO UPDATE SET name = excluded.name, description = excluded.description
                       RETURNING benchmark_id""",
                    (code, name, " + ".join(f"{w:.0%} {t}" for t, w in parts.items())))
        benchmark_id = cur.fetchone()[0]
        ids = {t: security(cur, t) for t in parts}
        months = sorted({(TODAY.replace(day=1) - datetime.timedelta(days=30 * m)).replace(day=1) for m in range(25)})
        dates = [m - datetime.timedelta(days=1) for m in months] + [TODAY]
        cur.execute("DELETE FROM srm.benchmark_weight WHERE benchmark_id = %s", (benchmark_id,))
        psycopg2.extras.execute_values(cur, """INSERT INTO srm.benchmark_weight
                (benchmark_id, as_of_date, security_id, weight, source_id, load_id) VALUES %s""",
                [(benchmark_id, d, ids[t], w, src, run.load_id) for d in dates for t, w in parts.items()])
        cur.execute("CALL srm.apply_benchmark_snapshot(%s, %s)", (benchmark_id, TODAY))
        log(f"  benchmark {code}: {name}, {len(dates)} month-end snapshots")


def drifted_rows(cur, start, count):
    """The index's largest members bought at their weights on `start`, never rebalanced since."""
    cur.execute("""SELECT w.security_id, v.ticker, w.weight FROM srm.benchmark_weights(
                        (SELECT benchmark_id FROM srm.benchmark WHERE code = 'SP500'), current_date) w
                     JOIN srm.v_security v USING (security_id) ORDER BY w.weight DESC LIMIT %s""", (count,))
    members = cur.fetchall()
    then = []
    for security_id, ticker, weight_now in members:
        p0, p1 = price_on(cur, security_id, start), last_price(cur, security_id)
        if p0 and p1:
            then.append((ticker, float(weight_now) * p0 / p1, p0, p1))     # weight back then ∝ today's × price ratio
    total_then = sum(t[1] for t in then)
    # Bought at those weights; today's value of each grew with its price.
    grown = [(t[0], t[1] / total_then * t[3] / t[2]) for t in then]
    total_now = sum(g[1] for g in grown)
    return [(ticker, value / total_now, [(start, 1)]) for ticker, value in grown]


def run(conn, cfg, args):
    with LoadRun(conn, "DERIVED", "sample_portfolios", {"samples": len(SAMPLES) + 1}) as run, conn.cursor() as cur:
        src = source_id(cur, "DERIVED")
        write_blends(cur, run, src)
        conn.commit()
        specs = list(SAMPLES)
        code, name, account, approach, benchmark, value, start, count = DRIFTED
        # Lots of the samples' securities: make sure each has prices back to its earliest purchase.
        needs = {}
        for spec in specs:
            for ticker, _, lots in spec[7]:
                sid = security(cur, ticker)
                if sid:
                    for day, _ in (lots or [(recent(12), 1)]):
                        d = datetime.date.fromisoformat(day)
                        needs[sid] = min(needs.get(sid, d), d)
    ensure_history(conn, cfg, conn.cursor(), needs)
    with LoadRun(conn, "DERIVED", "sample_portfolios", {"samples": len(SAMPLES) + 1, "step": "lots"}) as run, \
            conn.cursor() as cur:
        specs.append((code, name, account, approach, benchmark, value, 0.0, drifted_rows(cur, start, count)))
        for code, name, account, approach, benchmark, value, cash_share, holdings in specs:
            cur.execute("""INSERT INTO srm.portfolio (code, name, account_type, approach, managed_by, benchmark_id, cash_balance,
                                                      description)
                           VALUES (%s, %s, %s, %s, %s, (SELECT benchmark_id FROM srm.benchmark WHERE code = %s), %s,
                                   'MxAcctMGR sample account (srm.py load sample-portfolios)')
                           ON CONFLICT (code) DO UPDATE SET name = excluded.name, account_type = excluded.account_type,
                               approach = excluded.approach, managed_by = excluded.managed_by,
                               benchmark_id = excluded.benchmark_id, cash_balance = excluded.cash_balance,
                               updated_at = now()
                           RETURNING portfolio_id""",
                        (code, name, account, approach, MANAGED_BY, benchmark, round(value * cash_share, 2)))
            portfolio_id = cur.fetchone()[0]
            cur.execute("DELETE FROM srm.portfolio_tax_lot WHERE portfolio_id = %s", (portfolio_id,))
            invested = value * (1 - cash_share)
            share_total = sum(h[1] for h in holdings)
            lots_written, problems = 0, []
            for ticker, share, lots in holdings:
                sid = security(cur, ticker)
                if not sid:
                    problems.append(f"{ticker}: not in the security master")
                    continue
                now = last_price(cur, sid)
                lots = lots or [(recent(12), 1)]
                holding_value = invested * share / share_total
                if now is None:
                    # Never priced (a delisted security): the lot is kept at its purchase price, so the account shows it
                    # as unpriced — part of the missing-data lesson.
                    now = next((price_on(cur, sid, d) for d, _ in lots if price_on(cur, sid, d)), None)
                    if now is None:
                        problems.append(f"{ticker}: no price at all; held at a nominal $10 a share")
                        now = 10.0
                quantity = holding_value / now
                for day, lot_share in lots:
                    cost_price = price_on(cur, sid, day)
                    if cost_price is None:
                        problems.append(f"{ticker}: no price near {day}; cost at today's price")
                        cost_price = now
                    q = round(quantity * lot_share, 6)
                    cur.execute("""INSERT INTO srm.portfolio_tax_lot (portfolio_id, security_id, acquired_date, quantity,
                                                                      cost_basis, note)
                                   VALUES (%s, %s, %s, %s, %s, %s)""",
                                (portfolio_id, sid, day, q, round(q * cost_price, 2), f"sample lot at the {day} close"))
                    lots_written += 1
            cur.execute("SELECT srm.sync_holdings_from_lots(%s)", (portfolio_id,))
            run.inserted += lots_written
            run.read += len(holdings)
            for p in problems:
                run.reject(f"{code} {p.split(':')[0]}", p)
            log(f"  {code}: {len(holdings)} holdings, {lots_written} lots, cash {value * cash_share:,.0f}"
                + (f" — {'; '.join(problems)}" if problems else ""))
        run.message = f"{len(specs)} sample accounts, {len(BLENDS)} blended benchmarks"
