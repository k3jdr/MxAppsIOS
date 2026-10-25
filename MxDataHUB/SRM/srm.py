#!/usr/bin/env python3
"""SRM (security reference master) tools.

    ./srm.py migrate                 apply pending migrations
    ./srm.py status                  migrations, row counts, identifier coverage, recent loads
    ./srm.py load all                run every loader in dependency order (not the OPTIONAL ones)
    ./srm.py load <name> [options]   one loader (see LOADERS)
    ./srm.py load mutual-funds --symbols VTIFX ... | --search "fund name"
                                     add mutual funds from Nasdaq.com and load their prices
    ./srm.py load vanguard-funds [--symbols VFIAX ...] [--since DATE] [--history]
                                     every Vanguard mutual fund and its daily NAV (history from Nasdaq.com)
    ./srm.py load vanguard-plan [--file F]  Vanguard 401(k) downloads (QFX / CSV) → trust NAVs, plan account lots
    ./srm.py load pnc-bank [--file F]  PNC checking downloads (QFX / CSV) → bank lines, matched to the register
    ./srm.py load card-downloads [--file F]  Chase / Discover / Capital One card downloads (CSV / QFX) → card registers
    ./srm.py load trust-navs [--file F] collective trusts: statement NAVs + proxy-fund pricing (trusts.local.json)
    ./srm.py load portfolio-snapshots [--as-of DATE] [--portfolios CODE ...]
                                     carry portfolios' latest holdings forward (weight history)
    ./srm.py load earnings-symbols [--since DATE] [--symbols TLSNF ...]
                                     securities for FMP earnings-calendar symbols the master lacks (FMP profile, OpenFIGI)
    ./srm.py load listed-derivatives [--symbols GSRFU ...] [--force] [--since DATE]
                                     units, warrants, rights, tracking stocks: what they hold, identifiers, prices
    ./srm.py load massive-prices [--since DATE] [--force]
                                     every U.S. listed and OTC security's daily bar from Massive's Flat Files
    ./srm.py load treasuries [--since DATE]
                                     outstanding Treasury bills, notes, bonds, TIPS, FRNs and their FedInvest prices
    ./srm.py load cboe-vix | fred-yields [--since DATE] [--force]
                                     market series: the VIX family (Cboe), Treasury yields and recessions (FRED)
    ./srm.py load fmp-fundamentals [--symbols MSFT ...] [--force]
                                     quarterly statements for srm.fundamental_watch (MxAcctMGR's Compute screen)

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
from srmlib.loaders import (blackrock, derivatives, earnings_symbols, fund_families, security_fixes, fmp_symbols, massive, policy, sector_inherit, earnings_symbols_cleanup, fmp, fundamentals, gleif, market_series, mutual_funds, nasdaq100,
                             nasdaq_prices, nasdaqtrader, openfigi, portfolios, reference, samples, sec, spelling_duplicates, ssga, treasuries, trust_navs, vanguard, vanguard_holdings,
                             vanguard_plan, pnc_bank, card_downloads)

# Dependency order: venues and the listed universe first, then constituents, then the
# per-security enrichment that works on the benchmark / portfolio securities.
LOADERS = {
    "reference": reference.run,                 # ISO 10383 MICs, ISO 4217 currencies
    "nasdaqtrader": nasdaqtrader.run,           # US listed securities and tickers
    "sec-tickers": sec.load_tickers,            # CIKs -> issuers
    "ssga": ssga.run,                           # S&P 500 / 400 / 600 and Dow weights, CUSIP, SEDOL
    "nasdaq100": nasdaq100.run,                 # Nasdaq-100 members
    "earnings-symbols": earnings_symbols.run,   # companies in FMP's earnings calendar not yet here (OTC, ADRs, preferreds)
    "fmp-symbols": fmp_symbols.run,             # securities by FMP symbol (--symbols JMAT.L JMPLY): abroad / OTC-only, with prices
    "earnings-symbols-cleanup": earnings_symbols_cleanup.run,   # one-off fix of 2026-10-23's loads (report only unless --force)
    "openfigi": openfigi.run,                   # composite / share-class / exchange FIGIs
    "fmp-profiles": fmp.load_profiles,          # ISIN, CUSIP, sector, industry, market cap
    "inherit-sectors": sector_inherit.run,      # preferreds, warrants, units, rights: their company's sector
    "security-fixes": security_fixes.run,       # corrections the sources get wrong (security_fixes.json)
    "listed-derivatives": derivatives.run,      # units, warrants, rights: relations, CUSIP / ISIN / sector, prices
    "spelling-duplicates": spelling_duplicates.run,   # one-off: merge earnings-symbols' FMP-spelling duplicates (--force)
    "sec-submissions": sec.load_submissions,    # SIC, incorporation, EIN, former names
    "gleif": gleif.run,                         # LEIs and legal entity data
    "massive-prices": massive.run,              # every U.S. ticker's day bar from Massive Flat Files (one file a day)
    "fmp-prices": fmp.load_prices,              # end-of-day prices
    "fmp-otc-prices": fmp.load_otc_prices,      # end-of-day prices of every OTC listing (fmp-prices --otc)
    "nasdaq-prices": nasdaq_prices.run,         # fund prices (ETFs, ETNs, closed-end and mutual funds) and gaps, no key
    "vanguard-funds": vanguard.run,             # every Vanguard mutual fund (Vanguard's list), daily NAV; history from Nasdaq.com
    "blackrock-funds": blackrock.run,           # iShares ETFs, BlackRock mutual funds and CEFs: family profiles, NAVs
    "fund-families": fund_families.run,         # every other family's mutual funds and ETFs (FMP's fund screener), NAVs
    "vanguard-plan": vanguard_plan.run,         # Vanguard 401(k) downloads: funds, transactions, positions, trust NAVs, lots
    "vanguard-holdings": vanguard_holdings.run, # Vanguard index funds' month-end holdings as benchmarks VTSM VTBM VTISM VTIB (V036)
    "trust-navs": trust_navs.run,
    "card-downloads": card_downloads.run,       # credit card downloads (CSV / QFX) → card lines posted to the card registers
    "pnc-bank": pnc_bank.run,                   # PNC checking downloads (QFX / CSV) → bank lines matched to the check register               # collective trusts: statement NAVs carried by a proxy fund's returns
    "mutual-funds": mutual_funds.run,           # add mutual funds from Nasdaq.com (--symbols / --search), with prices
    "fmp-index-levels": fmp.load_index_levels,  # benchmark levels
    "fmp-corporate-actions": fmp.load_corporate_actions,
    "treasuries": treasuries.run,               # every outstanding Treasury (TreasuryDirect), daily prices (FedInvest)
    "cboe-vix": market_series.load_cboe,        # VIX, VIX9D, VIX3M, VIX6M daily OHLC (Cboe, no key)
    "fred-yields": market_series.load_fred,     # Treasury constant-maturity yields, NBER recessions (FRED, no key)
    "fmp-fundamentals": fundamentals.run,       # quarterly revenue, cash flow, capex, D&A (srm.fundamental_watch)
    "policy-benchmarks": policy.run,            # policy benchmarks' month-end snapshots from their dated mixes (V023)
    "sample-portfolios": samples.run,           # MxAcctMGR's sample accounts from real securities and prices
    "portfolio-snapshots": portfolios.run,      # holdings carried forward to the latest price date
}
# Not run by `load all`: name them to run them.
OPTIONAL = {"portfolio-snapshots", "mutual-funds", "earnings-symbols-cleanup", "spelling-duplicates", "sample-portfolios",
            "fmp-symbols"}


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
        cur.execute("SELECT to_regclass('srm.v_market_series_summary') IS NOT NULL")
        if cur.fetchone()[0]:
            print("\nMarket series:")
            cur.execute("""SELECT series_code, source, observations, first_date, last_date, last_value
                             FROM srm.v_market_series_summary ORDER BY sort_order""")
            for r in cur.fetchall():
                print(f"  {r[0]:7s} {r[1]:5s} {r[2]:>7,} values  {str(r[3] or ''):10} to {str(r[4] or ''):10}  last {r[5] if r[5] is not None else '—'}")
            cur.execute("""SELECT count(DISTINCT symbol), count(*), max(period_end), max(updated_at)::date
                             FROM srm.fundamental_quarter""")
            r = cur.fetchone()
            print(f"\nCompany fundamentals: {r[0]} companies, {r[1]:,} quarters, latest quarter {r[2]}, updated {r[3]}")
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
    load.add_argument("--since", help="prices / index levels / market series from this date (default: 2 years; series: incremental)")
    load.add_argument("--months", type=int, help="corporate actions: months of history (default 24)")
    load.add_argument("--history", action="store_true",
                      help="fmp-corporate-actions: also each security's full dividend / split history (2 calls per symbol); "
                           "vanguard-funds: ask Nasdaq.com for every fund's NAV history, not only new funds and gaps")
    load.add_argument("--symbols", nargs="*", help="FMP loaders: only these symbols / identifiers")
    load.add_argument("--all-securities", action="store_true",
                      help="FMP loaders: every active security instead of benchmark / portfolio members (~13k calls)")
    load.add_argument("--funds", action="store_true",
                      help="nasdaq-prices: every active fund (ETF, ETN, closed-end fund; ~6,100 requests at 1/second)")
    load.add_argument("--benchmarks", nargs="*",
                      help="ssga: only these benchmark codes (SP500 DJIA SP400 SP600); vanguard-holdings: VTSM VTBM VTISM VTIB")
    load.add_argument("--include-otc", action="store_true", help="sec-tickers: also create OTC securities")
    load.add_argument("--missing-sector", action="store_true",
                      help="fmp-profiles: active stocks, ADRs and REITs without a sector (never profiled)")
    load.add_argument("--otc", action="store_true", help="fmp-prices: every current OTC listing (as fmp-otc-prices)")
    load.add_argument("--min-cap", type=float, help="fmp-symbols: screen FMP's OTC lines of companies worth at least this ($)")
    load.add_argument("--home", action="store_true", help="fmp-symbols: also each company's London / Toronto line")
    load.add_argument("--as-of", help="portfolio-snapshots: snapshot date (default: the latest price date)")
    load.add_argument("--portfolios", nargs="*", help="portfolio-snapshots: only these portfolio codes")
    load.add_argument("--search", help="mutual-funds: add the funds a Nasdaq.com name search finds")
    load.add_argument("--file", help="trust-navs: the trusts file (default trusts.local.json); "
                                                 "vanguard-plan / pnc-bank / card-downloads: one download (default: the drop folders)")
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
