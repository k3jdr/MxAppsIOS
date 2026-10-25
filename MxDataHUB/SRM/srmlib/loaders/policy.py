"""Policy benchmarks (srm.benchmark_policy, V023) as benchmark weight snapshots.

A policy benchmark is a mix of securities — index funds or ETFs standing in for asset classes — with the date each mix
takes effect. This writes its month-end snapshots for the last two years and today (rebalanced to the mix each month),
each from the mix in effect on that day; months before the first mix take the first mix, as the plan the portfolio is
measured against as far back as attribution looks. The snapshots replace the benchmark's earlier ones, so a re-dated
or changed mix rewrites its history; srm.apply_benchmark_snapshot then updates its membership.

--benchmarks picks policy benchmarks by code (MxAcctMGR's editor runs it for the one it saved); else every one.
"""

import datetime

import psycopg2.extras

from ..common import LoadRun, log
from ..model import source_id

MONTHS = 25


def month_ends(today):
    """The last day of each of the last MONTHS months, oldest first, and today."""
    out, first = [], today.replace(day=1)
    for _ in range(MONTHS):
        last = first - datetime.timedelta(days=1)
        out.append(last)
        first = last.replace(day=1)
    return sorted(out) + [today]


def run(conn, cfg, args):
    today = datetime.date.today()
    codes = [c.upper() for c in (args.benchmarks or [])]
    with LoadRun(conn, "MANUAL", "policy_benchmarks", {"benchmarks": codes}) as run, conn.cursor() as cur:
        src = source_id(cur, "MANUAL")      # the mixes are entered by hand (MxAcctMGR's editor)
        cur.execute("""SELECT b.benchmark_id, b.code FROM srm.benchmark b
                        WHERE EXISTS (SELECT 1 FROM srm.benchmark_policy p WHERE p.benchmark_id = b.benchmark_id)
                          AND (%s::text[] IS NULL OR b.code = ANY(%s))
                        ORDER BY b.code""", (codes or None, codes or None))
        benchmarks = cur.fetchall()
        missing = set(codes) - {c for _, c in benchmarks}
        for code in sorted(missing):
            run.reject(code, "no policy benchmark with this code (define its mix first)")
        dates = month_ends(today)
        for benchmark_id, code in benchmarks:
            cur.execute("""SELECT effective_from, security_id, weight FROM srm.benchmark_policy
                            WHERE benchmark_id = %s ORDER BY effective_from""", (benchmark_id,))
            mixes = {}
            for eff, sid, w in cur.fetchall():
                mixes.setdefault(eff, []).append((sid, float(w)))
            starts = sorted(mixes)
            bad = [str(d) for d in starts if abs(sum(w for _, w in mixes[d]) - 1) > 0.001]
            if bad:
                run.reject(code, "mix weights don't add up to 100% from " + ", ".join(bad))
                continue
            rows = []
            for d in dates:
                eff = max((s for s in starts if s <= d), default=starts[0])
                rows += [(benchmark_id, d, sid, w, src, run.load_id) for sid, w in mixes[eff]]
            cur.execute("DELETE FROM srm.benchmark_weight WHERE benchmark_id = %s", (benchmark_id,))
            psycopg2.extras.execute_values(cur, """INSERT INTO srm.benchmark_weight
                    (benchmark_id, as_of_date, security_id, weight, source_id, load_id) VALUES %s""", rows)
            cur.execute("CALL srm.apply_benchmark_snapshot(%s, %s)", (benchmark_id, today))
            run.read += len(starts)
            run.inserted += len(rows)
            conn.commit()
            log(f"  {code}: {len(starts)} mix{'es' if len(starts) != 1 else ''} from {starts[0]}, "
                f"{len(dates)} snapshots ({dates[0]} to {dates[-1]})")
        run.message = f"{len(benchmarks)} policy benchmarks, {len(dates)} snapshots each"
        log("  " + run.message)
