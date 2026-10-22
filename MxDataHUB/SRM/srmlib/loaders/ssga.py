"""Index constituents and weights from State Street SPDR ETF daily holdings (free .xlsx):
SPY -> S&P 500, DIA -> Dow Jones Industrial Average, MDY -> S&P MidCap 400, SPSM -> S&P SmallCap 600.
The ETFs fully replicate their indexes, so holdings weights are a close proxy for index weights.
Each holding carries ticker, CUSIP and SEDOL, which are recorded as identifiers."""

import datetime
import os
import re

import psycopg2.extras

from .. import xlsx
from ..common import CACHE_DIR, LoadRun, debug, download, log, set_identifiers
from ..model import (classification_node, create_security, normalize_ticker, security_by_identifier,
                     security_by_us_ticker, set_classification, source_id)

URL = "https://www.ssga.com/us/en/intermediary/library-content/products/fund-data/etfs/us/holdings-daily-us-en-{etf}.xlsx"
FUNDS = {"SP500": "spy", "DJIA": "dia", "SP400": "mdy", "SP600": "spsm"}
# Fund lines that are not index constituents: cash, money market, futures, and contingent value
# rights / earn-outs / escrow lines left over from corporate actions.
NOT_CONSTITUENT = re.compile(r"^(U\.?S\.? DOLLAR|.*MONEY MARKET|.*\bE-MINI\b|.*\bFUTURES?\b)|"
                             r"\b(CONTRA|CVR|EARNOUT|ESCROW|WRNTY)\b|REP \+", re.I)


def _holdings(path):
    as_of, header, out = None, None, []
    for row in xlsx.rows(path):
        cells = [(c or "").strip() if isinstance(c, str) else c for c in row]
        if not cells:
            continue
        if cells[0] == "Holdings:" and len(cells) > 1:
            as_of = datetime.datetime.strptime(cells[1].replace("As of", "").strip(), "%d-%b-%Y").date()
        elif cells[0] == "Name" and "Weight" in cells:
            header = cells
        elif header and cells[0] and len(cells) >= len(header) - 1:
            r = dict(zip(header, cells))
            if r.get("Weight") in (None, "", "-"):
                if not any(cells[1:]):
                    header = None   # end of the table
                continue
            out.append(r)
    return as_of, out


def run(conn, cfg, args):
    wanted = [b.upper() for b in (args.benchmarks or FUNDS)]
    for code in wanted:
        etf = FUNDS.get(code)
        if not etf:
            log(f"  no SPDR fund for {code}")
            continue
        with LoadRun(conn, "SSGA", f"ssga_{etf}", {"benchmark": code, "etf": etf.upper()}) as run, conn.cursor() as cur:
            path = download(URL.format(etf=etf), os.path.join(CACHE_DIR, f"holdings-{etf}.xlsx"))
            run.api_calls += 1
            as_of, holdings = _holdings(path)
            if not as_of or not holdings:
                raise RuntimeError(f"could not read holdings from {etf}.xlsx")
            debug(f"{etf.upper()}: {len(holdings)} holding lines as of {as_of} in {os.path.basename(path)}")
            cur.execute("SELECT benchmark_id FROM srm.benchmark WHERE code = %s", (code,))
            benchmark_id = cur.fetchone()[0]
            ssga = source_id(cur, "SSGA")
            members, ids = {}, []
            for h in holdings:
                run.read += 1
                ticker = normalize_ticker(h.get("Ticker"))
                cusip = (h.get("Identifier") or "").upper()
                sedol = (h.get("SEDOL") or "").upper()
                try:
                    weight = float(h["Weight"]) / 100
                except (TypeError, ValueError):
                    run.reject(h.get("Name"), "weight is not a number", h)
                    continue
                if (weight <= 0 or not ticker or cusip in ("", "-") or NOT_CONSTITUENT.search(h.get("Name") or "")
                        or re.match(r"^[0-9]{5,}", ticker) or weight < 0.00001):
                    run.reject(h.get("Name"), "not an index constituent (cash, future, CVR or residual weight)", h)
                    continue
                security_id = (security_by_identifier(cur, "CUSIP", cusip) or security_by_us_ticker(cur, ticker))
                if security_id is None:
                    # Not in the listed universe (e.g. a CVR or a ticker the directory spells differently).
                    security_id = create_security(cur, h["Name"].title(), "Common Stock", run.load_id, country="US")
                    run.inserted += 1
                if security_id in members:   # same security twice (rare): add the weights
                    members[security_id][0] += weight
                    continue
                shares = h.get("Shares Held")
                members[security_id] = [weight, float(shares) if shares not in (None, "", "-") else None]
                ids.append((security_id, "CUSIP", cusip, None, None))
                if sedol and sedol != "-":
                    ids.append((security_id, "SEDOL", sedol, None, None))
                sector = h.get("Sector")
                if sector and sector != "-":
                    node = classification_node(cur, "SSGA", 1, sector)
                    set_classification(cur, security_id, "SSGA", 1, node, ssga, run.load_id)
            set_identifiers(cur, run, ids, "SSGA")

            total = sum(w for w, _ in members.values())
            cur.execute("DELETE FROM srm.benchmark_weight WHERE benchmark_id = %s AND as_of_date = %s", (benchmark_id, as_of))
            psycopg2.extras.execute_values(cur, """
                INSERT INTO srm.benchmark_weight (benchmark_id, as_of_date, security_id, weight, shares, source_id, load_id)
                VALUES %s""", [(benchmark_id, as_of, sid, w / total, s, ssga, run.load_id)
                               for sid, (w, s) in members.items()])
            cur.execute("CALL srm.apply_benchmark_snapshot(%s, %s)", (benchmark_id, as_of))
            run.parameters["as_of"] = str(as_of)
            run.message = f"{code} {as_of}: {len(members)} members, holdings weight {total:.4%} re-normalised to 100%"
            log("  " + run.message)
            conn.commit()
