"""Collective investment trusts (CITs: the "Trust Unit A" funds in 401(k) plans), priced from your statements.

CITs have no ticker and no public price feed, free or paid. You keep their unit values (NAVs) from the plan statement
in MxDataHUB/SRM/trusts.local.json (not in git; copy trusts.example.json), each with an index fund that tracks the
same index as its proxy:

    {"trusts": [{"code": "VTSM-CIT", "name": "Vanguard Inst Total Stock Market Index Trust Unit A",
                 "proxy": "VITSX", "navs": {"2026-09-30": 123.4567}}]}

This loader creates or updates each trust (security type 'Collective Investment Trust', listing on MIC XXXX under
its code), records the proxy (srm.price_proxy), stores the statement NAVs (source STATEMENT), and prices every other
day the proxy has a close (source PROXY): the nearest earlier statement NAV × the proxy's return since that date (the
first NAV, scaled back, before it). Each new statement NAV re-anchors the series. It runs in the Prices category after
nasdaq-prices, so trusts move with their proxies every day. A trust without a statement NAV yet is created (so it can
be added to an account) but not priced.

Trusts held in a retirement plan whose downloads vanguard-plan reads need no entry here: the unit values in those
downloads (srm.v_plan_nav) are their statement NAVs, and the proxy vanguard-plan recorded carries them between days.
A file entry for the same trust adds its NAVs to the plan's.
"""

import argparse
import bisect
import datetime
import json
import os

import psycopg2.extras

from ..common import LoadRun, log, set_identifiers
from ..model import create_security, ensure_listing, normalize_ticker, source_id
from . import mutual_funds, nasdaq_prices

MIC = "XXXX"
TYPE = "Collective Investment Trust"
DEFAULT_FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "trusts.local.json")


def _proxy(conn, cfg, cur, run, symbol):
    """security_id of the proxy fund, adding a mutual fund from Nasdaq.com (with prices) when it's missing."""
    def find():
        cur.execute("""SELECT r.security_id FROM srm.resolve_identifier(%s) r ORDER BY r.rank LIMIT 1""", (symbol,))
        row = cur.fetchone()
        return row[0] if row else None
    found = find()
    if found is None:
        fund = mutual_funds.lookup(symbol)
        run.api_calls += 1
        if fund:
            mutual_funds.add(cur, run, [fund])
            conn.commit()
            nasdaq_prices.run(conn, cfg, argparse.Namespace(symbols=[fund[0]], since=None, max=None, force=False,
                                                            funds=False, all_securities=False))
            found = find()
    return found


def _trust(cur, run, code, name):
    """(security_id, listing_id) of the trust, created when new; keeps its name and type current."""
    cur.execute("SELECT security_id, listing_id FROM srm.listing WHERE mic = %s AND ticker = %s AND current_date < valid_to",
                (MIC, code))
    row = cur.fetchone()
    if row:
        cur.execute("""UPDATE srm.security SET name = %s, security_type = %s, is_active = true
                        WHERE security_id = %s AND (name <> %s OR security_type <> %s OR NOT is_active)""",
                    (name, TYPE, row[0], name, TYPE))
        run.updated += cur.rowcount
        return row
    security_id = create_security(cur, name, TYPE, run.load_id, country="US", primary_mic=MIC)
    listing_id, _ = ensure_listing(cur, security_id, MIC, code, True)
    set_identifiers(cur, run, [(security_id, "TICKER", code, MIC, listing_id)], "STATEMENT")
    run.inserted += 1
    return security_id, listing_id


def set_proxy(cur, security_id, proxy_id, note):
    """Records the index fund a trust follows between statement NAVs."""
    cur.execute("""INSERT INTO srm.price_proxy (security_id, proxy_security_id, note) VALUES (%s, %s, %s)
                   ON CONFLICT (security_id) DO UPDATE SET proxy_security_id = excluded.proxy_security_id,
                          note = excluded.note, updated_at = now()
                    WHERE srm.price_proxy.proxy_security_id <> excluded.proxy_security_id""",
                (security_id, proxy_id, note))


def _proxy_closes(cur, proxy_id):
    """[(date, close)] of the proxy's primary listing, one close per day."""
    cur.execute("""SELECT DISTINCT ON (p.price_date) p.price_date, p.close
                     FROM srm.price p JOIN srm.listing l USING (listing_id)
                    WHERE l.security_id = %s AND l.is_primary
                    ORDER BY p.price_date, p.source_id""", (proxy_id,))
    return [(d, float(c)) for d, c in cur.fetchall()]


def _plan_navs(cur, security_id):
    """{date: NAV} the retirement plan downloads reported for this trust (srm.v_plan_nav, vanguard-plan)."""
    cur.execute("SELECT price_date, nav FROM srm.v_plan_nav WHERE security_id = %s", (security_id,))
    return {d: float(v) for d, v in cur.fetchall()}


def _price(cur, run, code, listing_id, navs, proxy_id, proxy, statement, proxy_src):
    """Replaces the trust's series: its statement NAVs, and every other day the proxy has a close, priced from them."""
    rows = [(d.isoformat(), v, statement) for d, v in sorted(navs.items())]
    closes = _proxy_closes(cur, proxy_id) if proxy_id else []
    if closes:
        dates = [d for d, _ in closes]
        anchors = sorted(navs)

        def proxy_on(day):      # the proxy's close on or before `day` (else its first close)
            i = bisect.bisect_right(dates, day) - 1
            return closes[max(i, 0)][1]

        for d, c in closes:
            if d in navs:
                continue
            i = bisect.bisect_right(anchors, d) - 1
            anchor = anchors[max(i, 0)]
            base = proxy_on(anchor)
            if base > 0:
                rows.append((d.isoformat(), round(navs[anchor] * c / base, 6), proxy_src))
    # Statement and proxy rows are both derived from the NAVs and the proxy, so they are replaced together.
    cur.execute("DELETE FROM srm.price WHERE listing_id = %s AND source_id IN (%s, %s)",
                (listing_id, statement, proxy_src))
    psycopg2.extras.execute_values(cur, """
        INSERT INTO srm.price (listing_id, price_date, close, currency_code, source_id, load_id)
        SELECT %s, v.d::date, v.c::numeric, 'USD', v.s::smallint, %s FROM (VALUES %%s) AS v(d, c, s)""" %
        (listing_id, run.load_id), rows, page_size=1000)
    run.inserted += len(rows)
    log(f"  {code}: {len(navs)} statement NAV(s), {len(rows) - len(navs)} proxy-priced days" +
        (f" from {proxy}" if closes else " (no proxy prices)"))


def run(conn, cfg, args):
    path = getattr(args, "file", None) or DEFAULT_FILE
    with LoadRun(conn, "STATEMENT", "trust_navs", {"file": path}) as run, conn.cursor() as cur:
        trusts = []
        if os.path.exists(path):
            with open(path) as f:
                trusts = json.load(f).get("trusts", [])
        statement, proxy_src = source_id(cur, "STATEMENT"), source_id(cur, "PROXY")
        priced, done = 0, set()
        for t in trusts:
            run.read += 1
            code, name, proxy = normalize_ticker(t.get("code")), (t.get("name") or "").strip(), (t.get("proxy") or "").strip()
            if not code or not name:
                run.reject(str(t.get("code")), "each trust needs a code (A-Z, 0-9, - .) and a name")
                continue
            security_id, listing_id = _trust(cur, run, code, name[:300])
            done.add(security_id)
            navs = _plan_navs(cur, security_id)
            for day, nav in (t.get("navs") or {}).items():
                try:
                    d, v = datetime.date.fromisoformat(day), float(nav)
                except (TypeError, ValueError):
                    run.reject(code, f"unreadable statement NAV {day!r}: {nav!r}")
                    continue
                if v <= 0:
                    run.reject(code, f"statement NAV on {day} must be positive")
                    continue
                navs[d] = v
            proxy_id = _proxy(conn, cfg, cur, run, proxy) if proxy else None
            if proxy and proxy_id is None:
                run.reject(code, f"proxy {proxy} is not in the security master and Nasdaq.com doesn't list it as a mutual fund")
            if proxy_id:
                set_proxy(cur, security_id, proxy_id, f"{code} follows {proxy}")
            if not navs:
                cur.execute("DELETE FROM srm.price WHERE listing_id = %s AND source_id IN (%s, %s)",
                            (listing_id, statement, proxy_src))
                run.reject(code, "no statement NAV yet: add one under \"navs\" (date: unit value from your plan statement)")
                continue
            _price(cur, run, code, listing_id, navs, proxy_id, proxy, statement, proxy_src)
            priced += 1

        # Trusts held in a retirement plan (vanguard-plan): its downloads' unit values, carried by their proxies.
        cur.execute("""SELECT l.security_id, l.listing_id, l.ticker, x.proxy_security_id, pl.ticker
                         FROM srm.listing l JOIN srm.security s USING (security_id)
                         LEFT JOIN srm.price_proxy x USING (security_id)
                         LEFT JOIN srm.listing pl ON pl.security_id = x.proxy_security_id AND pl.is_primary
                                                 AND current_date < pl.valid_to
                        WHERE l.mic = %s AND current_date < l.valid_to AND s.security_type = %s
                          AND EXISTS (SELECT 1 FROM srm.v_plan_nav n WHERE n.security_id = l.security_id)
                        ORDER BY l.ticker""", (MIC, TYPE))
        for security_id, listing_id, code, proxy_id, proxy in cur.fetchall():
            if security_id in done:
                continue
            run.read += 1
            _price(cur, run, code, listing_id, _plan_navs(cur, security_id), proxy_id, proxy, statement, proxy_src)
            priced += 1
        conn.commit()
        run.message = f"{run.read} trusts, {priced} priced"
