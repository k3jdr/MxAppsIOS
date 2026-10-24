"""Corrections to securities that the sources get wrong (security_fixes.json next to srm.py), with the reason in the
load's log. Runs last in Identifiers & issuer data, after the loaders that set types and names, so a correction stays.

  * rules, in order: securities of the rule's `from` types whose name or ticker matches (`name`, `ticker`: PostgreSQL
    regular expressions, either one) and whose FMP industry matches `industry` (when given), unless the name matches
    `notName`, get the type `to` — exchange-listed notes ("baby bonds") typed as stock, preferreds typed common, REIT
    common shares;
  * fixes: a security named by ticker (its current U.S. or OTC listing) gets the type and / or name given;
  * remove: a security named by ticker (any current listing) is deleted, with its listings, identifiers, prices and
    holdings-snapshot rows — refused while an account's tax lots hold it or a benchmark uses it. Done once: the next
    run finds nothing to delete.
"""

import json
import os

from ..common import LoadRun, log

FILE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "security_fixes.json")
FIELDS = {"securityType": "security_type", "name": "name"}


def run(conn, cfg, args):
    path = getattr(args, "file", None) or FILE
    with open(path) as f:
        spec = json.load(f)
    fixes, rules = spec.get("fixes") or [], spec.get("rules") or []
    with LoadRun(conn, "MANUAL", "security_fixes", {"file": os.path.basename(path)}) as run, conn.cursor() as cur:
        run.read = len(fixes)
        by_rule = []
        for r in rules:
            cur.execute("SELECT 1 FROM srm.security_type WHERE security_type = %s", (r["to"],))
            if not cur.fetchone():
                run.reject(r.get("rule"), f"unknown security type {r['to']!r}")
                continue
            match = []
            params = [r["to"], list(r["from"])]
            if r.get("name") or r.get("ticker"):
                match.append("(" + " OR ".join(x for x, k in (("v.name ~* %s", "name"), ("v.ticker ~ %s", "ticker")) if r.get(k)) + ")")
                params += [r[k] for k in ("name", "ticker") if r.get(k)]
            if r.get("industry"):
                match.append("v.industry ~* %s")
                params.append(r["industry"])
            if r.get("notName"):
                match.append("v.name !~* %s")
                params.append(r["notName"])
            if not match:
                run.reject(r.get("rule"), "a rule needs a name, ticker or industry pattern")
                continue
            cur.execute("""UPDATE srm.security s SET security_type = %s, updated_at = now()
                             FROM srm.v_security v
                            WHERE v.security_id = s.security_id AND v.is_active AND s.security_type = ANY(%s) AND """
                        + " AND ".join(match) + " RETURNING v.ticker", params)
            tickers = [t for (t,) in cur.fetchall()]
            run.updated += len(tickers)
            by_rule.append(f"{r.get('rule')}: {len(tickers)}")
            log(f"  rule '{r.get('rule')}' → {r['to']}: {len(tickers)}" + (" (" + ", ".join(tickers[:12]) + (" …" if len(tickers) > 12 else "") + ")" if tickers else ""))
        for fix in fixes:
            ticker = (fix.get("ticker") or "").strip().upper()
            cur.execute("""SELECT coalesce(srm.us_security(%s),
                                  (SELECT l.security_id FROM srm.listing l WHERE l.ticker = %s AND l.mic = 'OTCM'
                                      AND current_date >= l.valid_from AND current_date < l.valid_to LIMIT 1))""", (ticker, ticker))
            security_id = cur.fetchone()[0]
            if not security_id:
                run.reject(ticker, "no current listing with this ticker")
                continue
            sets = {col: fix[key] for key, col in FIELDS.items() if fix.get(key)}
            if sets.get("security_type"):
                cur.execute("SELECT 1 FROM srm.security_type WHERE security_type = %s", (sets["security_type"],))
                if not cur.fetchone():
                    run.reject(ticker, f"unknown security type {sets['security_type']!r}")
                    continue
            cur.execute("SELECT " + ", ".join(sets) + " FROM srm.security WHERE security_id = %s", (security_id,))
            before = dict(zip(sets, cur.fetchone()))
            changed = {c: v for c, v in sets.items() if before[c] != v}
            if not changed:
                continue
            cur.execute("UPDATE srm.security SET " + ", ".join(f"{c} = %s" for c in changed) + ", updated_at = now() "
                        "WHERE security_id = %s", list(changed.values()) + [security_id])
            run.updated += 1
            log(f"  {ticker} (security {security_id}): " + "; ".join(f"{c} {before[c]!r} → {v!r}" for c, v in changed.items())
                + f" — {fix.get('why', '')}")
        removed = []
        for item in spec.get("remove") or []:
            ticker = (item.get("ticker") or "").strip().upper()
            cur.execute("""SELECT l.security_id FROM srm.listing l WHERE l.ticker = %s
                              AND current_date >= l.valid_from AND current_date < l.valid_to
                            ORDER BY l.is_primary DESC LIMIT 1""", (ticker,))
            row = cur.fetchone()
            if not row:
                continue                        # already gone
            sid = row[0]
            cur.execute("""SELECT (SELECT count(*) FROM srm.portfolio_tax_lot WHERE security_id = %s),
                                  (SELECT count(*) FROM srm.benchmark_weight WHERE security_id = %s)
                                + (SELECT count(*) FROM srm.benchmark_policy WHERE security_id = %s)
                                + (SELECT count(*) FROM srm.benchmark_constituent WHERE security_id = %s)""", (sid, sid, sid, sid))
            lots, bench = cur.fetchone()
            if lots or bench:
                run.reject(ticker, f"not removed: {lots} tax lots and {bench} benchmark rows still use it")
                continue
            cur.execute("DELETE FROM srm.portfolio_holding WHERE security_id = %s", (sid,))
            snapshots = cur.rowcount
            cur.execute("DELETE FROM srm.portfolio_transaction WHERE security_id = %s", (sid,))
            cur.execute("DELETE FROM srm.price_proxy WHERE proxy_security_id = %s", (sid,))
            cur.execute("DELETE FROM srm.security WHERE security_id = %s RETURNING name", (sid,))
            name = cur.fetchone()[0]
            removed.append(ticker)
            log(f"  removed {ticker} (security {sid}, {name}) and {snapshots} holdings-snapshot rows — {item.get('why', '')}")
        conn.commit()
        run.message = (f"rules — {'; '.join(by_rule)}; " if by_rule else "") + f"{len(fixes)} named corrections" + (f"; removed {', '.join(removed)}" if removed else "")
        log("  " + run.message)
