#!/usr/bin/env python3
"""SRM (security reference master) tools.

    ./srm.py migrate                 apply pending migrations
    ./srm.py status                  migrations, row counts, identifier coverage, recent loads
    ./srm.py load all                run every loader in dependency order (not the OPTIONAL ones)
    ./srm.py load <name> [options]   one loader (see LOADERS)
    ./srm.py load mutual-funds --symbols VTIFX ... | --search "fund name"
                                     add mutual funds from Nasdaq.com and load their prices
    ./srm.py load trust-navs [--file F] collective trusts: statement NAVs + proxy-fund pricing (trusts.local.json)
    ./srm.py load portfolio-snapshots [--as-of DATE] [--portfolios CODE ...]
                                     carry portfolios' latest holdings forward (weight history)

Connection: --host/--port/--user/--dbname, or SRM_PG* environment variables, or
config.local.json; defaults postgres@192.168.0.223:5432/srm. Secrets: see srmlib/common.py.

Logging: -v (verbose) also prints what each step does — connection, downloads, rate-limit waits, retries,
rejects, identifier results, timings, and a loader's traceback when it fails; -vv (trace) also every HTTP request
and SQL statement with its time. Before or after the command: ./srm.py -v load ssga, ./srm.py load ssga -vv.
"""

import argparse
import sys
import time
import traceback

from srmlib import common, migrate
from srmlib.common import Config, debug, log
from srmlib.loaders import (fmp, gleif, mutual_funds, nasdaq100, nasdaq_prices, nasdaqtrader, openfigi, portfolios,
                             reference, sec, ssga, trust_navs)

# Dependency order: venues and the listed universe first, then constituents, then the
# per-security enrichment that works on the benchmark / portfolio securities.
LOADERS = {
    "reference": reference.run,                 # ISO 10383 MICs, ISO 4217 currencies
    "nasdaqtrader": nasdaqtrader.run,           # US listed securities and tickers
    "sec-tickers": sec.load_tickers,            # CIKs -> issuers
    "ssga": ssga.run,                           # S&P 500 / 400 / 600 and Dow weights, CUSIP, SEDOL
    "nasdaq100": nasdaq100.run,                 # Nasdaq-100 members
    "openfigi": openfigi.run,                   # composite / share-class / exchange FIGIs
    "fmp-profiles": fmp.load_profiles,          # ISIN, CUSIP, sector, industry, market cap
    "sec-submissions": sec.load_submissions,    # SIC, incorporation, EIN, former names
    "gleif": gleif.run,                         # LEIs and legal entity data
    "fmp-prices": fmp.load_prices,              # end-of-day prices
    "nasdaq-prices": nasdaq_prices.run,         # fund prices (ETFs, ETNs, closed-end and mutual funds) and gaps, no key
    "trust-navs": trust_navs.run,               # collective trusts: statement NAVs carried by a proxy fund's returns
    "mutual-funds": mutual_funds.run,           # add mutual funds from Nasdaq.com (--symbols / --search), with prices
    "fmp-index-levels": fmp.load_index_levels,  # benchmark levels
    "fmp-corporate-actions": fmp.load_corporate_actions,
    "portfolio-snapshots": portfolios.run,      # holdings carried forward to the latest price date
}
# Not run by `load all`: name them to run them.
OPTIONAL = {"portfolio-snapshots", "mutual-funds"}


def status(conn):
    migrate.status(conn)
    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass('srm.security') IS NOT NULL")
        if not cur.fetchone()[0]:
            return
        print()
        cur.execute("""
            SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname = 'srm' ORDER BY relname""")
        for name, n in cur.fetchall():
            cur.execute(f"SELECT count(*) FROM srm.{name}")
            print(f"  srm.{name:28s} {cur.fetchone()[0]:>10,}")
        print("\nIdentifier coverage (current values):")
        cur.execute("SELECT id_type, securities, total_securities, pct, sources FROM srm.v_identifier_coverage ORDER BY sort_order")
        for r in cur.fetchall():
            print(f"  {r[0]:17s} {r[1]:>7,} / {r[2]:,} ({r[3] or 0}%)  {r[4] or ''}")
        print("\nBenchmarks:")
        cur.execute("SELECT code, as_of_date, members, round(weight_sum, 6), last_level_date, constituent_source FROM srm.v_benchmark_summary ORDER BY code")
        for r in cur.fetchall():
            print(f"  {r[0]:8s} {r[1]}  {r[2]:>4} members  weight {r[3]}  levels to {r[4]}  ({r[5]})")
        print("\nRecent loads:")
        cur.execute("""SELECT load_id, source, loader, status, rows_read, rows_inserted, rows_updated, rows_rejected,
                              api_calls, to_char(started_at, 'MM-DD HH24:MI'), duration
                         FROM srm.v_load_history ORDER BY load_id DESC LIMIT 20""")
        for r in cur.fetchall():
            print(f"  {r[0]:>4} {r[9]} {r[2]:24s} {r[3]:9s} read {r[4]:>7,} ins {r[5]:>7,} upd {r[6]:>6,} rej {r[7]:>5,} calls {r[8]:>5,}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for name in ("host", "port", "user", "dbname"):
        parser.add_argument(f"--{name}")
    verbose_help = "print more: -v what each step does, -vv also every HTTP request and SQL statement"
    parser.add_argument("-v", "--verbose", action="count", default=0, help=verbose_help)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("migrate")
    sub.add_parser("status")
    load = sub.add_parser("load")
    load.add_argument("loader", choices=["all"] + list(LOADERS))
    # Its own dest: a subcommand's default would otherwise overwrite a -v given before the command.
    load.add_argument("-v", "--verbose", dest="load_verbose", action="count", default=0, help=verbose_help)
    load.add_argument("--max", type=int, help="at most this many API calls / securities (per-symbol loaders)")
    load.add_argument("--force", action="store_true", help="refresh even recently loaded rows")
    load.add_argument("--since", help="prices / index levels from this date (default: 2 years)")
    load.add_argument("--months", type=int, help="corporate actions: months of history (default 24)")
    load.add_argument("--history", action="store_true",
                      help="fmp-corporate-actions: also each security's full dividend / split history (2 calls per symbol)")
    load.add_argument("--symbols", nargs="*", help="FMP loaders: only these symbols / identifiers")
    load.add_argument("--all-securities", action="store_true",
                      help="FMP loaders: every active security instead of benchmark / portfolio members (~13k calls)")
    load.add_argument("--funds", action="store_true",
                      help="nasdaq-prices: every active fund (ETF, ETN, closed-end fund; ~6,100 requests at 1/second)")
    load.add_argument("--benchmarks", nargs="*", help="ssga: only these benchmark codes (SP500 DJIA SP400 SP600)")
    load.add_argument("--include-otc", action="store_true", help="sec-tickers: also create OTC securities")
    load.add_argument("--as-of", help="portfolio-snapshots: snapshot date (default: the latest price date)")
    load.add_argument("--portfolios", nargs="*", help="portfolio-snapshots: only these portfolio codes")
    load.add_argument("--search", help="mutual-funds: add the funds a Nasdaq.com name search finds")
    load.add_argument("--file", help="trust-navs: the trusts file (default trusts.local.json)")
    args = parser.parse_args()
    common.set_verbosity(max(args.verbose + getattr(args, "load_verbose", 0), common.VERBOSITY))
    debug(f"srm.py {' '.join(sys.argv[1:])} (Python {sys.version.split()[0]}, verbosity {common.VERBOSITY})")

    cfg = Config(args)
    conn = cfg.connect()
    try:
        if args.command == "migrate":
            migrate.migrate(conn)
        elif args.command == "status":
            status(conn)
        else:
            names = [n for n in LOADERS if n not in OPTIONAL] if args.loader == "all" else [args.loader]
            for name in names:
                log(f"== {name}")
                started = time.monotonic()
                try:
                    LOADERS[name](conn, cfg, args)
                except SystemExit:
                    raise
                except Exception as e:   # recorded in srm.load_run; go on with the next loader
                    log(f"{name} failed: {e}")
                    for line in traceback.format_exc().rstrip().splitlines():
                        debug(line)
                    if args.loader != "all":
                        return 1
                finally:
                    debug(f"{name} took {time.monotonic() - started:.1f}s")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
