"""Vanguard retirement plan (401(k)) downloads: funds, transactions, positions, trust NAVs and the account's tax lots.

A Vanguard plan's Download center gives the account's positions and up to 18 months of transactions as Quicken
(OfxDownload.qfx, OFX) or CSV (OfxDownload.csv). Drop them in a folder named in vanguard_plans.local.json (not in
git; copy vanguard_plans.example.json):

    {"dropFolders": ["~/MyCodeGIT/MxDataSRM/src-vanguard", "~/Downloads"],
     "plans": {"12345": {"portfolio": "MY_PORTFOLIO"}}}

Every run reads each plan download in those folders (oldest first) and keeps, in the security master (V026):
 * the plan's funds (srm.plan_fund): a public fund (VTIFX) is the security already in the master; a "Trust Unit A"
   fund becomes a collective investment trust (as trust-navs makes them) with an index fund as its proxy,
 * every transaction once (srm.plan_transaction, by its transaction id), so overlapping downloads add up to one
   history that grows with each new download,
 * the positions on the download's date (srm.plan_position).
The unit values in the downloads are the trusts' statement NAVs (srm.v_plan_nav): trust-navs, which runs after this
loader, carries them between days with each trust's proxy.

When the plan is mapped to a portfolio, its tax lots are rebuilt from the latest positions and the transactions: one
lot per fund and trade day (contributions, reinvested dividends, transfers in), fund-to-fund transfers out taken
first-in first-out, and what the fund held before the first transaction as one lot valued at that day's unit value
(the downloads don't carry its cost). Lots of the portfolio's other securities are kept. When the lots change, they
are saved as a new version of the portfolio (as a save in MxAcctMGR is), so every earlier version stays.

The QFX file repeats each transaction several times and splits it by money source (pre-tax, match, after-tax); it
is the better file: it has transaction ids and CUSIPs. A CSV file is used for a plan only while no QFX file was read.
"""

import csv
import datetime
import glob
import hashlib
import json
import os
import re

from ..common import LoadRun, debug, log, set_identifiers
from ..model import source_id
from . import trust_navs

SRM_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONFIG_FILE = os.path.join(SRM_DIR, "vanguard_plans.local.json")
DEFAULT_FOLDERS = ["~/MyCodeGIT/MxDataSRM/src-vanguard"]

# Vanguard's institutional trusts in 401(k) plans: the download's fund id → (code, name, proxy fund, CSV fund name).
TRUSTS = {
    "VGI00M080": ("VTSM-CIT", "Vanguard Institutional Total Stock Market Index Trust Unit A", "VITSX",
                  "Inst Tot Stk Mt Ix Tr U A"),
    "VGI00M088": ("VTBM-CIT", "Vanguard Institutional Total Bond Market Index Trust Unit A", "VBTIX",
                  "Inst Tot Bd Mkt Ix Tr U A"),
    "VGI00V015": ("VTISM-CIT", "Vanguard Institutional Total International Stock Market Index Trust Unit A", "VTSNX",
                  "Ist Tot Int St Mt I T U A"),
}

KINDS = {"contribution": "contributions", "dividend": "reinvested dividends", "transfer-in": "transfer in",
         "other-in": "other"}
CSV_ACTIONS = {"plan contribution": "contribution", "dividends on equity investments": "dividend",
               "fund to fund in": "transfer-in", "fund to fund out": "transfer-out"}


def _business_day(d):
    """The last weekday on or before d (a download dated on a weekend carries Friday's unit values)."""
    while d.weekday() >= 5:
        d -= datetime.timedelta(days=1)
    return d


# ---------------------------------------------------------------------------------------------------------- reading

def _tag(body, name):
    m = re.search(r"<" + name + r">([^<\r\n]*)", body)
    return m.group(1).strip() if m else None


def _ofx_date(v):
    return datetime.date(int(v[:4]), int(v[4:6]), int(v[6:8]))


def read_qfx(text):
    """{plan, asOf, funds: {fundId: {name, ticker, cusip}}, positions: [...], transactions: [...]} of a plan's QFX."""
    plan = _tag(re.search(r"<INVACCTFROM>.*?</INVACCTFROM>", text, re.S).group(0), "ACCTID")
    funds = {}
    for body in re.findall(r"<SECINFO>(.*?)</SECINFO>", text, re.S):
        funds[_tag(body, "UNIQUEID")] = {"name": _tag(body, "SECNAME"), "ticker": _tag(body, "TICKER"), "cusip": None}
    positions, as_of = [], None
    for body in re.findall(r"<POS(?:MF|STOCK|DEBT|OTHER)>(.*?)</POS(?:MF|STOCK|DEBT|OTHER)>", text, re.S):
        day = _business_day(_ofx_date(_tag(body, "DTPRICEASOF")))
        as_of = max(as_of, day) if as_of else day
        positions.append({"fundId": _tag(body, "UNIQUEID"), "units": float(_tag(body, "UNITS")),
                          "price": float(_tag(body, "UNITPRICE")), "value": float(_tag(body, "MKTVAL"))})
    transactions, seen = [], set()
    for kind, body in re.findall(r"<(BUYMF|SELLMF|REINVEST|TRANSFER|BUYOTHER|SELLOTHER|BUYSTOCK|SELLSTOCK)>(.*?)</\1>",
                                 text, re.S):
        fitid = _tag(body, "FITID")
        if fitid in seen:       # the file repeats transactions
            continue
        seen.add(fitid)
        cusip, units = _tag(body, "UNIQUEID"), abs(float(_tag(body, "UNITS")))
        # The FITID ends with the fund id the positions use (…00M080AAA → VGI00M080).
        fund_id = "VGI" + fitid[-9:-3] if len(fitid) > 9 else None
        if fund_id not in funds:
            fund_id = next((f for f, v in funds.items() if v["cusip"] == cusip or f == cusip), None)
        if kind == "TRANSFER":
            action = "transfer-out" if _tag(body, "TFERACTION") == "OUT" else "transfer-in"
        elif kind == "REINVEST":
            action = "dividend"
        elif kind.startswith("SELL"):
            action = "other-out"
        else:
            action = "contribution"
        if fund_id in funds:
            funds[fund_id]["cusip"] = cusip
        total = _tag(body, "TOTAL")
        transactions.append({"id": fitid, "date": _ofx_date(_tag(body, "DTTRADE")), "fundId": fund_id, "cusip": cusip,
                             "action": action, "source": _tag(body, "INV401KSOURCE"),
                             "units": -units if action.endswith("-out") else units,
                             "price": float(_tag(body, "UNITPRICE") or 0) or None,
                             "amount": abs(float(total)) if total else None, "description": _tag(body, "MEMO")})
    return {"format": "QFX", "plan": plan, "asOf": as_of, "funds": funds, "positions": positions,
            "transactions": transactions}


def read_csv(path, known_names):
    """The same from a plan's CSV download; its funds are known by name (TRUSTS, or a QFX file read before)."""
    rows = list(csv.reader(open(path, encoding="utf-8-sig")))
    as_of = _business_day(datetime.date.fromtimestamp(os.path.getmtime(path)))
    plan, funds, positions, transactions, count, section = None, {}, [], [], {}, None
    for r in rows:
        if not any(c.strip() for c in r):
            continue
        if r[0] == "Plan Number":
            section = "positions"
            continue
        if r[0] == "Account Number":
            section = "transactions"
            continue
        if section == "positions" and len(r) >= 6:
            plan, name = r[0].strip(), r[2].strip()
            fund_id = known_names.get(name, "NAME:" + name)
            funds[fund_id] = {"name": name, "ticker": None, "cusip": None}
            positions.append({"fundId": fund_id, "units": float(r[3]), "price": float(r[4]), "value": float(r[5])})
        elif section == "transactions" and len(r) >= 9 and r[1].strip():
            name = r[5].strip()
            fund_id = known_names.get(name, "NAME:" + name)
            funds.setdefault(fund_id, {"name": name, "ticker": None, "cusip": None})
            units, desc = float(r[7] or 0), r[4].strip()
            action = CSV_ACTIONS.get(desc.lower(), "other-in" if units >= 0 else "other-out")
            if action == "transfer-out" or action == "other-out":
                units = -abs(units)
            key = "|".join(c.strip() for c in r[:9])
            count[key] = count.get(key, 0) + 1          # identical rows are separate transactions
            transactions.append({"id": "csv:" + hashlib.sha1(f"{key}|{count[key]}".encode()).hexdigest()[:24],
                                 "date": datetime.datetime.strptime(r[1].strip(), "%m/%d/%Y").date(),
                                 "fundId": fund_id, "cusip": None, "action": action, "source": None, "units": units,
                                 "price": float(r[6] or 0) or None, "amount": abs(float(r[8])) if r[8] else None,
                                 "description": desc})
    return {"format": "CSV", "plan": plan, "asOf": as_of, "funds": funds, "positions": positions,
            "transactions": transactions}


def _downloads(folders, single):
    """[(path, format)] of the plan downloads to read: QFX first (it names the funds CSV files only name), oldest first."""
    paths = [single] if single else []
    if not single:
        for folder in folders:
            folder = os.path.expanduser(folder)
            try:
                names = os.listdir(folder)
            except FileNotFoundError:
                continue
            except PermissionError:
                log(f"  can't read {folder}: give the app that runs the loaders access to it (System Settings ▸ "
                    "Privacy & Security ▸ Files and Folders), or drop the downloads in another folder")
                continue
            paths += [os.path.join(folder, n) for n in names if n.lower().endswith((".qfx", ".ofx", ".csv"))]
    found = []
    for p in sorted(set(paths), key=os.path.getmtime):
        try:
            with open(p, encoding="latin-1") as f:
                head = f.read(4096)
        except OSError:
            continue
        if p.lower().endswith(".csv"):
            if head.lstrip("﻿").startswith("Plan Number,Plan Name,Fund Name"):
                found.append((p, "CSV"))
        elif "<ORG>Vanguard" in head and "<INV401K>" in open(p, encoding="latin-1").read():    # a plan, not a brokerage account
            found.append((p, "QFX"))
    return sorted(found, key=lambda f: f[1] == "CSV")


# --------------------------------------------------------------------------------------------------------- securities

def _security(conn, cfg, cur, run, fund_id, fund):
    """security_id of a plan fund: a trust (created, with its proxy) or the public fund already in the master."""
    known = TRUSTS.get(fund_id)
    name = fund["name"] or fund_id
    if known or re.search(r"\bTr\b|\bTrust\b|\bU A$", name):
        code, full, proxy = known[:3] if known else ("VGI-" + fund_id.replace("VGI", ""), name, None)
        security_id, listing_id = trust_navs._trust(cur, run, code, full)
        if fund.get("cusip"):
            set_identifiers(cur, run, [(security_id, "CUSIP", fund["cusip"], None, None)], "VANGUARD_PLAN")
        if proxy:
            proxy_id = trust_navs._proxy(conn, cfg, cur, run, proxy)
            if proxy_id:
                trust_navs.set_proxy(cur, security_id, proxy_id, f"{code} follows {proxy}")
        return security_id
    for ident in (fund.get("ticker"), fund.get("cusip")):
        if ident and not ident.startswith("VGI"):
            cur.execute("SELECT r.security_id FROM srm.resolve_identifier(%s) r ORDER BY r.rank LIMIT 1", (ident,))
            row = cur.fetchone()
            if row:
                return row[0]
    return None


# ---------------------------------------------------------------------------------------------------------- tax lots

def build_lots(positions, transactions, navs):
    """[(acquired, quantity, cost, note)] of one fund: per trade day in, FIFO out, the rest held before as one lot.
    Raises ValueError when the transactions don't explain the position."""
    held = positions["units"]
    days = {}
    for t in transactions:
        days.setdefault(t["date"], []).append(t)
    opening = held - sum(t["units"] for t in transactions)
    if opening < -0.001:
        raise ValueError(f"the transactions take out {-opening:,.3f} units more than the plan held")
    lots = []
    if opening > 0.0005:
        first = min(days) if days else positions["asOf"]
        price = next((navs[d] for d in sorted(navs) if d >= first), None) or positions["price"]
        lots.append([first - datetime.timedelta(days=1), opening, opening * price,
                     f"held before {first.isoformat()}: cost unknown, valued at that day's unit value"])
    for day in sorted(days):
        ins = [t for t in days[day] if t["units"] > 0]
        if ins:
            units = sum(t["units"] for t in ins)
            cost = sum(t["amount"] if t["amount"] else t["units"] * (t["price"] or 0) for t in ins)
            kinds = sorted({KINDS[t["action"]] for t in ins})
            lots.append([day, units, cost, ", ".join(kinds)])
        out = -sum(t["units"] for t in days[day] if t["units"] < 0)
        while out > 1e-9 and lots:
            lot = lots[0]
            take = min(out, lot[1])
            lot[2] -= lot[2] * take / lot[1]
            lot[1] -= take
            out -= take
            if lot[1] <= 1e-6:
                lots.pop(0)
    return [(d, round(q, 6), round(max(c, 0), 2), n) for d, q, c, n in lots if round(q, 6) > 0]


def _plan_lots(cur, plan):
    """{security_id: [lot]} of the plan from its latest positions and its transactions, plus that date."""
    cur.execute("SELECT max(as_of) FROM srm.plan_position WHERE plan_number = %s", (plan,))
    as_of = cur.fetchone()[0]
    if not as_of:
        return as_of, {}, []
    cur.execute("SELECT 1 FROM srm.plan_transaction WHERE plan_number = %s AND file_format = 'QFX' LIMIT 1", (plan,))
    fmt = "QFX" if cur.fetchone() else "CSV"
    cur.execute("""SELECT f.fund_id, f.fund_name, f.security_id, p.units, p.price
                     FROM srm.plan_fund f
                     LEFT JOIN srm.plan_position p ON p.plan_number = f.plan_number AND p.fund_id = f.fund_id AND p.as_of = %s
                    WHERE f.plan_number = %s""", (as_of, plan))
    out, problems = {}, []
    for fund_id, name, security_id, units, price in cur.fetchall():
        if security_id is None:
            if units:
                problems.append(f"{name}: not in the security master")
            continue
        cur.execute("""SELECT trade_date, action, units, price, amount FROM srm.plan_transaction
                        WHERE plan_number = %s AND fund_id = %s AND file_format = %s AND trade_date <= %s""",
                    (plan, fund_id, fmt, as_of))
        txns = [{"date": d, "action": a, "units": float(u), "price": float(p) if p else None,
                 "amount": float(m) if m is not None else None} for d, a, u, p, m in cur.fetchall()]
        cur.execute("SELECT price_date, nav FROM srm.v_plan_nav WHERE security_id = %s", (security_id,))
        navs = {d: float(v) for d, v in cur.fetchall()}
        try:
            lots = build_lots({"units": float(units or 0), "price": float(price or 0), "asOf": as_of}, txns, navs)
        except ValueError as e:
            problems.append(f"{name}: {e}; kept as one lot at its value")
            lots = [(as_of, round(float(units), 6), round(float(units) * float(price or 0), 2), "position")] if units else []
        out.setdefault(security_id, []).extend(lots)
    return as_of, out, problems


def _save_portfolio(cur, run, plan, code, as_of, lots):
    """Replaces the plan securities' lots in the portfolio as a new saved version; False when nothing changed."""
    cur.execute("SELECT portfolio_id FROM srm.portfolio WHERE upper(code) = upper(%s) FOR UPDATE", (code,))
    row = cur.fetchone()
    if row is None:
        cur.execute("""INSERT INTO srm.portfolio (code, name, inception_date, description, account_type, managed_by,
                                                  cash_balance, updated_by, version)
                       VALUES (%s, %s, current_date, %s, 'retirement', 'MxAcctMGR', 0, 'vanguard-plan', 0)
                       RETURNING portfolio_id""",
                    (code, f"Vanguard plan {plan}", f"Vanguard retirement plan {plan}, from its downloads"))
        row = cur.fetchone()
    pid = row[0]
    cur.execute("SELECT security_id FROM srm.plan_fund WHERE plan_number = %s AND security_id IS NOT NULL", (plan,))
    plan_ids = [r[0] for r in cur.fetchall()]
    cur.execute("""SELECT security_id, acquired_date, round(quantity, 6), round(cost_basis, 2) FROM srm.portfolio_tax_lot
                    WHERE portfolio_id = %s AND security_id = ANY(%s)""", (pid, plan_ids))
    current = sorted((s, d, float(q), float(c)) for s, d, q, c in cur.fetchall())
    new = sorted((s, d, q, c) for s, ls in lots.items() for d, q, c, _ in ls)
    if current == new:
        return False
    cur.execute("DELETE FROM srm.portfolio_tax_lot WHERE portfolio_id = %s AND security_id = ANY(%s)", (pid, plan_ids))
    for security_id, ls in lots.items():
        for d, q, c, note in ls:
            cur.execute("""INSERT INTO srm.portfolio_tax_lot (portfolio_id, security_id, acquired_date, quantity, cost_basis, note)
                           VALUES (%s, %s, %s, %s, %s, %s)""", (pid, security_id, d, q, c, f"Vanguard plan: {note}"[:200]))
    cur.execute("""UPDATE srm.portfolio SET version = version + 1, updated_by = 'vanguard-plan', updated_at = now()
                    WHERE portfolio_id = %s""", (pid,))
    cur.execute("SELECT srm.sync_holdings_from_lots(%s, current_date)", (pid,))
    cur.execute("""
        INSERT INTO srm.portfolio_version (portfolio_id, version, saved_by, name, account_type, approach, benchmark_code,
                                           cash_balance, settings, lots, note)
        SELECT p.portfolio_id, p.version, p.updated_by, p.name, p.account_type, p.approach, b.code, p.cash_balance,
               p.settings,
               coalesce((SELECT jsonb_agg(jsonb_build_object('securityId', l.security_id, 'ticker', v.ticker,
                                                             'acquired', l.acquired_date, 'quantity', l.quantity,
                                                             'costBasis', l.cost_basis, 'note', l.note) ORDER BY l.lot_id)
                           FROM srm.portfolio_tax_lot l JOIN srm.v_security v USING (security_id)
                          WHERE l.portfolio_id = p.portfolio_id), '[]'::jsonb),
               %s
          FROM srm.portfolio p LEFT JOIN srm.benchmark b USING (benchmark_id)
         WHERE p.portfolio_id = %s""", (f"Vanguard plan {plan} positions of {as_of.isoformat()} (load {run.load_id})", pid))
    run.updated += 1
    return True


# ---------------------------------------------------------------------------------------------------------------- run

def run(conn, cfg, args):
    single = getattr(args, "file", None)
    config = {}
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            config = json.load(f)
    folders = config.get("dropFolders") or DEFAULT_FOLDERS
    with LoadRun(conn, "VANGUARD_PLAN", "vanguard_plan", {"folders": folders, "file": single}) as run, conn.cursor() as cur:
        files = _downloads(folders, single)
        if not files:
            run.message = "no plan downloads in " + ", ".join(folders)
            log("  " + run.message)
            return
        plans, new_txns = set(), 0
        for path, fmt in files:
            if fmt == "QFX":
                data = read_qfx(open(path, encoding="latin-1").read())
            else:
                cur.execute("SELECT fund_name, fund_id FROM srm.plan_fund")
                names = dict(cur.fetchall())
                names.update({v[3]: k for k, v in TRUSTS.items()})
                data = read_csv(path, names)
            plan = data["plan"]
            if not plan:
                run.reject(os.path.basename(path), "no plan number in the file")
                continue
            plans.add(plan)
            for fund_id, fund in data["funds"].items():
                if fund_id.startswith("NAME:"):
                    run.reject(fund["name"], "CSV fund not known by name yet: read the plan's QFX download once")
                    continue
                cur.execute("SELECT security_id FROM srm.plan_fund WHERE plan_number = %s AND fund_id = %s", (plan, fund_id))
                row = cur.fetchone()
                # A CSV names the fund only: keep the security a QFX file linked it to.
                security_id = row[0] if row and row[0] and fmt == "CSV" else _security(conn, cfg, cur, run, fund_id, fund)
                if security_id is None:
                    run.reject(fund["name"], f"{fund_id}: no security for it in the master")
                cur.execute("""INSERT INTO srm.plan_fund (plan_number, fund_id, fund_name, cusip, security_id)
                               VALUES (%s, %s, %s, %s, %s)
                               ON CONFLICT (plan_number, fund_id) DO UPDATE SET fund_name = excluded.fund_name,
                                      cusip = coalesce(excluded.cusip, srm.plan_fund.cusip),
                                      security_id = coalesce(excluded.security_id, srm.plan_fund.security_id),
                                      updated_at = now()""",
                            (plan, fund_id, fund["name"], fund.get("cusip"), security_id))
            for t in data["transactions"]:
                run.read += 1
                if not t["fundId"] or t["fundId"].startswith("NAME:"):
                    continue
                cur.execute("""INSERT INTO srm.plan_transaction (plan_number, txn_id, trade_date, fund_id, action,
                                      money_source, units, price, amount, description, file_format, load_id)
                               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                               ON CONFLICT (plan_number, txn_id) DO NOTHING""",
                            (plan, t["id"], t["date"], t["fundId"], t["action"], t["source"], t["units"], t["price"],
                             t["amount"], t["description"], fmt, run.load_id))
                new_txns += cur.rowcount
            for p in data["positions"]:
                if p["fundId"].startswith("NAME:"):
                    continue
                cur.execute("""INSERT INTO srm.plan_position (plan_number, as_of, fund_id, units, price, market_value, load_id)
                               VALUES (%s, %s, %s, %s, %s, %s, %s)
                               ON CONFLICT (plan_number, as_of, fund_id) DO UPDATE SET units = excluded.units,
                                      price = excluded.price, market_value = excluded.market_value, load_id = excluded.load_id""",
                            (plan, data["asOf"], p["fundId"], p["units"], p["price"], p["value"], run.load_id))
            debug(f"  {os.path.basename(path)}: {fmt}, plan {plan}, {len(data['positions'])} positions, "
                  f"{len(data['transactions'])} transactions")
        run.inserted += new_txns
        log(f"  {len(files)} download(s), {new_txns} new transaction(s)")

        saved = []
        for plan in sorted(plans):
            as_of, lots, problems = _plan_lots(cur, plan)
            for p in problems:
                run.reject(plan, p)
            code = (config.get("plans", {}).get(plan) or {}).get("portfolio")
            total = sum(q for ls in lots.values() for _, q, _, _ in ls)
            log(f"  plan {plan}: positions of {as_of}, {sum(len(ls) for ls in lots.values())} lots in "
                f"{len(lots)} funds ({total:,.3f} units)")
            if not code:
                log(f"  plan {plan} isn't mapped to a portfolio in {os.path.basename(CONFIG_FILE)}: lots not saved")
                continue
            if _save_portfolio(cur, run, plan, code, as_of, lots):
                saved.append(code)
                log(f"  {code}: saved a new version with the plan's lots")
            else:
                log(f"  {code}: lots unchanged")
        conn.commit()
        run.message = (f"{len(files)} download(s), {new_txns} new transactions; plans {', '.join(sorted(plans))}"
                       + (f"; saved {', '.join(saved)}" if saved else "; portfolios unchanged"))
