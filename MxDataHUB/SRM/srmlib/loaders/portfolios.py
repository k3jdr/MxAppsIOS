"""Daily portfolio snapshots, so portfolio weight history builds up for performance attribution (which uses the
snapshot at the start of each month). Each portfolio's latest snapshot before the target date is carried
forward to it: shares are copied unchanged (their weights move with prices when the snapshot is valued);
weights are drifted by each security's adjusted-close return since that snapshot and re-scaled to the same
total. The target date defaults to the latest price date, so weekends and holidays add nothing.
A snapshot already on the target date (entered in MxDataHUB or loaded before) is never changed."""

import datetime

import psycopg2.extras

from ..common import LoadRun, log

# Adjusted closes on or before the snapshot date and the target date, from the security's primary priced listing.
HOLDINGS = """
    SELECT h.security_id, h.quantity, h.weight, h.cost_price, h.input_identifier, h.input_type, h.note,
           px.p0, px.p1
      FROM srm.portfolio_holding h
      LEFT JOIN LATERAL (
          SELECT (SELECT coalesce(p.adj_close, p.close) FROM srm.price p
                   WHERE p.listing_id = l.listing_id AND p.price_date <= h.as_of_date
                   ORDER BY p.price_date DESC LIMIT 1) AS p0,
                 (SELECT coalesce(p.adj_close, p.close) FROM srm.price p
                   WHERE p.listing_id = l.listing_id AND p.price_date <= %(target)s
                   ORDER BY p.price_date DESC LIMIT 1) AS p1
            FROM srm.listing l
           WHERE l.security_id = h.security_id
             AND EXISTS (SELECT 1 FROM srm.price p WHERE p.listing_id = l.listing_id)
           ORDER BY l.is_primary DESC, l.listing_id LIMIT 1) px ON true
     WHERE h.portfolio_id = %(portfolio)s AND h.as_of_date = %(source)s"""


def drift(rows):
    """New weights for the rows that have one: w × (1 + return), re-scaled to the original total.
    Returns ({security_id: weight}, [security_ids without both prices, whose weight was not drifted])."""
    weighted = [r for r in rows if r["weight"] is not None]
    unpriced = [r["security_id"] for r in weighted if not (r["p0"] and r["p1"])]
    grown = {r["security_id"]: float(r["weight"]) * (float(r["p1"]) / float(r["p0"]) if r["p0"] and r["p1"] else 1.0)
             for r in weighted}
    total_before = sum(float(r["weight"]) for r in weighted)
    total_after = sum(grown.values())
    if not weighted or abs(total_after) < 1e-12:
        return {r["security_id"]: float(r["weight"]) for r in weighted}, unpriced
    scale = total_before / total_after
    return {sid: w * scale for sid, w in grown.items()}, unpriced


def run(conn, cfg, args):
    with LoadRun(conn, "SNAPSHOT", "portfolio_snapshots") as run, \
            conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        if getattr(args, "as_of", None):
            target = datetime.date.fromisoformat(args.as_of)
        else:
            cur.execute("SELECT max(price_date) AS d FROM srm.price WHERE price_date <= current_date")
            target = cur.fetchone()["d"]
            if target is None:
                raise RuntimeError("no prices loaded; run fmp-prices first (or pass --as-of)")
        run.parameters["as_of"] = str(target)
        wanted = [p.upper() for p in (getattr(args, "portfolios", None) or [])]
        cur.execute("""
            SELECT p.portfolio_id, p.code,
                   (SELECT max(as_of_date) FROM srm.portfolio_holding h
                     WHERE h.portfolio_id = p.portfolio_id AND h.as_of_date < %s) AS source,
                   EXISTS (SELECT 1 FROM srm.portfolio_holding h
                            WHERE h.portfolio_id = p.portfolio_id AND h.as_of_date = %s) AS has_target
              FROM srm.portfolio p
             WHERE cardinality(%s::text[]) = 0 OR upper(p.code) = ANY(%s::text[])
             ORDER BY p.code""", (target, target, wanted, wanted))
        portfolios = cur.fetchall()
        missing = sorted(set(wanted) - {p["code"].upper() for p in portfolios})
        if missing:
            raise ValueError("no portfolio " + ", ".join(missing))

        carried, skipped = [], []
        for p in portfolios:
            if p["has_target"]:
                skipped.append(f"{p['code']} (has {target})")
                continue
            if p["source"] is None:
                skipped.append(f"{p['code']} (no snapshot before {target})")
                continue
            cur.execute(HOLDINGS, {"target": target, "portfolio": p["portfolio_id"], "source": p["source"]})
            rows = cur.fetchall()
            run.read += len(rows)
            weights, unpriced = drift(rows)
            psycopg2.extras.execute_values(cur, """
                INSERT INTO srm.portfolio_holding (portfolio_id, as_of_date, security_id, quantity, weight, cost_price,
                                                   input_identifier, input_type, note, load_id, drifted_from)
                VALUES %s ON CONFLICT (portfolio_id, as_of_date, security_id) DO NOTHING""",
                [(p["portfolio_id"], target, r["security_id"], r["quantity"], weights.get(r["security_id"]),
                  r["cost_price"], r["input_identifier"], r["input_type"], r["note"], run.load_id, p["source"])
                 for r in rows], page_size=len(rows) or 1)
            run.inserted += cur.rowcount
            carried.append(f"{p['code']} from {p['source']} ({len(rows)} holdings"
                           + (f", {len(unpriced)} without prices kept their weight" if unpriced else "") + ")")
        run.message = (f"{target}: " + ("; ".join(carried) if carried else "nothing to carry forward")
                       + (f". Skipped {', '.join(skipped)}" if skipped else ""))
        log("  " + run.message)
        conn.commit()
