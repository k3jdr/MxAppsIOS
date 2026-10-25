"""PNC checking account downloads: the bank's side of MxAcctMGR's check register (V027).

PNC Online Banking downloads an account's activity as Quicken (.qfx), Money / OFX (.ofx) or a spreadsheet (.csv).
Drop them in a folder named in bank_accounts.local.json (not in git; copy bank_accounts.example.json):

    {"dropFolders": ["~/MyCodeGIT/MxDataSRM/src-bank", "~/Downloads"],
     "accounts": {"1234": "PNC_CHECKING"}}

`accounts` maps the account number's last four digits (as the downloads name it) to the checking account's code in
MxAcctMGR (Accounts ▸ Checking Accounts). A QFX / OFX file names its account; a CSV file doesn't, so CSV files go in
a sub-folder named by the account's code (src-bank/PNC_CHECKING/…).

Each run reads every download there (oldest first) and keeps each bank line once (srm.bank_line, by the file's
transaction id, or a hash of the CSV row), records the latest ledger balance, and matches the lines to open register
entries (srm.match_bank_lines: same amount and check number, or same amount within a week), which marks them cleared.
The lines left over show in the register as the bank's entries to accept or match.
"""

import csv
import datetime
import hashlib
import io
import json
import os
import re

from ..common import LoadRun, debug, log

SRM_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONFIG_FILE = os.path.join(SRM_DIR, "bank_accounts.local.json")
DEFAULT_FOLDERS = ["~/MyCodeGIT/MxDataSRM/src-bank"]


def _tag(body, name):
    m = re.search(r"<" + name + r">([^<\r\n]*)", body)
    return m.group(1).strip() if m else None


def _ofx_date(v):
    return datetime.date(int(v[:4]), int(v[4:6]), int(v[6:8]))


def read_ofx(text):
    """[(last4, lines, (balance, as_of) or None)] of each bank account statement in a QFX / OFX file."""
    out = []
    for stmt in re.findall(r"<STMTRS>(.*?)</STMTRS>", text, re.S):
        acct = _tag(stmt, "ACCTID") or ""
        lines = []
        for body in re.findall(r"<STMTTRN>(.*?)</STMTTRN>", stmt, re.S):
            check = _tag(body, "CHECKNUM") or None
            lines.append({"fitid": _tag(body, "FITID"), "date": _ofx_date(_tag(body, "DTPOSTED")),
                          "amount": round(float(_tag(body, "TRNAMT")), 2), "type": _tag(body, "TRNTYPE"),
                          "checkNo": check.lstrip("0") or None if check else None,
                          "name": _tag(body, "NAME"), "memo": _tag(body, "MEMO")})
        bal = re.search(r"<LEDGERBAL>(.*?)</LEDGERBAL>", stmt, re.S)
        balance = (round(float(_tag(bal.group(1), "BALAMT")), 2), _ofx_date(_tag(bal.group(1), "DTASOF"))) if bal else None
        out.append((acct[-4:], lines, balance))
    return out


def _money(v):
    v = (v or "").replace("$", "").replace(",", "").strip()
    if not v:
        return 0.0
    neg = v.startswith("(") and v.endswith(")")
    v = float(v.strip("()"))
    return -v if neg else v


def read_csv(text):
    """Lines of a bank CSV: a header naming Date and Description, and Amount or Withdrawals / Deposits (Debit /
    Credit), with Check Number and Reference when given."""
    rows = list(csv.reader(io.StringIO(text)))
    head = next((i for i, r in enumerate(rows) if any("date" in c.lower() for c in r) and
                 any(k in " ".join(r).lower() for k in ("amount", "withdrawal", "debit"))), None)
    if head is None:
        raise ValueError("no header with a date and an amount (or withdrawals / deposits) column")
    cols = [c.strip().lower() for c in rows[head]]

    def col(*names):
        return next((i for i, c in enumerate(cols) if any(n in c for n in names)), None)

    d, desc, amt = col("date"), col("description", "payee", "name"), col("amount")
    out_, in_ = col("withdrawal", "debit"), col("deposit", "credit")
    check, ref, memo = col("check"), col("reference", "transaction id", "ref"), col("memo")
    lines, seen = [], {}
    for r in rows[head + 1:]:
        if len(r) <= d or not r[d].strip():
            continue
        try:
            date = datetime.datetime.strptime(r[d].strip(), "%m/%d/%Y").date()
        except ValueError:
            try:
                date = datetime.date.fromisoformat(r[d].strip())
            except ValueError:
                continue
        amount = _money(r[amt]) if amt is not None else _money(r[in_] if in_ is not None else "") - abs(_money(r[out_]))
        key = "|".join(c.strip() for c in r)
        seen[key] = seen.get(key, 0) + 1
        fitid = (r[ref].strip() if ref is not None and r[ref].strip() else None) or \
            "csv:" + hashlib.sha1(f"{key}|{seen[key]}".encode()).hexdigest()[:24]
        check_no = (r[check].strip().lstrip("0") or None) if check is not None and len(r) > check else None
        lines.append({"fitid": fitid, "date": date, "amount": round(amount, 2), "type": None, "checkNo": check_no,
                      "name": r[desc].strip() if desc is not None else None,
                      "memo": r[memo].strip() if memo is not None and len(r) > memo else None})
    return lines


def _files(folders, single):
    paths = [single] if single else []
    for folder in ([] if single else folders):
        folder = os.path.expanduser(folder)
        for root, _, names in os.walk(folder):
            if root != folder and os.path.dirname(root) != folder:
                continue        # the folder and its account sub-folders only
            paths += [os.path.join(root, n) for n in names if n.lower().endswith((".qfx", ".ofx", ".csv"))]
    return sorted(set(paths), key=os.path.getmtime)


def run(conn, cfg, args):
    single = getattr(args, "file", None)
    config = {}
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            config = json.load(f)
    folders = config.get("dropFolders") or DEFAULT_FOLDERS
    by_last4 = config.get("accounts") or {}
    with LoadRun(conn, "PNC_BANK", "pnc_bank", {"folders": folders, "file": single}) as run, conn.cursor() as cur:
        cur.execute("SELECT upper(code), bank_account_id, account_last4 FROM srm.bank_account WHERE closed_date IS NULL")
        accounts = {c: (i, l4) for c, i, l4 in cur.fetchall()}
        for l4, code in list(by_last4.items()):
            by_last4[l4] = code.upper()
        for code, (_, l4) in accounts.items():       # an account's own last four digits map it too
            if l4:
                by_last4.setdefault(l4, code)
        touched, new = set(), 0
        for path in _files(folders, single):
            name = os.path.basename(path)
            try:
                text = open(path, encoding="utf-8-sig", errors="replace").read()
            except PermissionError:
                log(f"  can't read {path}: give the app that runs the loaders access to its folder")
                continue
            if path.lower().endswith(".csv"):
                code = os.path.basename(os.path.dirname(path)).upper()
                if code not in accounts:
                    continue        # not in an account's sub-folder: not a bank download we know
                statements = [(code, read_csv(text), None)]
            else:
                if "<STMTRS>" not in text:
                    continue        # a brokerage or retirement plan file, not a bank account
                statements = [(by_last4.get(l4), lines, bal) for l4, lines, bal in read_ofx(text)]
            for code, lines, balance in statements:
                if code not in accounts:
                    run.reject(name, "account not mapped: add its last four digits to the account in MxAcctMGR "
                                     "(Accounts ▸ Checking Accounts) or to bank_accounts.local.json")
                    continue
                aid = accounts[code][0]
                touched.add(aid)
                for l in lines:
                    run.read += 1
                    cur.execute("""INSERT INTO srm.bank_line (bank_account_id, fitid, posted_date, amount, trn_type, check_no,
                                                              name, memo, file_format, load_id)
                                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                                   ON CONFLICT (bank_account_id, fitid) DO NOTHING""",
                                (aid, l["fitid"], l["date"], l["amount"], l["type"], l["checkNo"], l["name"], l["memo"],
                                 "CSV" if path.lower().endswith(".csv") else "OFX", run.load_id))
                    new += cur.rowcount
                if balance:
                    cur.execute("""UPDATE srm.bank_account SET bank_balance = %s, bank_balance_as_of = %s, updated_at = now()
                                    WHERE bank_account_id = %s AND (bank_balance_as_of IS NULL OR bank_balance_as_of <= %s)""",
                                (balance[0], balance[1], aid, balance[1]))
                debug(f"  {name}: {code}, {len(lines)} lines")
        matched = 0
        for aid in touched:
            cur.execute("SELECT srm.match_bank_lines(%s)", (aid,))
            matched += cur.fetchone()[0]
        run.inserted += new
        run.updated += matched
        conn.commit()
        run.message = f"{new} new bank lines in {len(touched)} account(s); {matched} matched to register entries"
        log("  " + run.message)
