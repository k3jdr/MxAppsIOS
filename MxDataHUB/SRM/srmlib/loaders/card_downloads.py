"""Credit card downloads: the card company's side of MxAcctMGR's credit card registers (V029).

Chase downloads a card's activity as a spreadsheet (.csv) or Quicken / Money (.qfx / .ofx); Discover and Capital One
as .csv. Drop them in a folder named in card_accounts.local.json (not in git; copy card_accounts.example.json):

    {"dropFolders": ["~/MyCodeGIT/MxDataSRM/src-cards"],
     "accounts": {"1234": "CHASE_VISA"}}

`accounts` maps a card number's last four digits to the card's code in MxAcctMGR (Banking ▸ Credit Card Accounts);
a card's own last four digits, set there, map it too. A QFX / OFX file names its card, and so do Chase's CSV file
names (Chase1234_Activity…) and Capital One's Card No. column; other CSV files (Discover's) go in a sub-folder named
by the card's code (src-cards/DISCOVER/…). MxAcctMGR's Import File… puts a file there.

Each run reads every download there (oldest first) and keeps each line once (srm.card_line, by the file's
transaction id, or a hash of the CSV row and how many times the same row came before it in that file). Downloads of
overlapping periods share their lines; a line already read from the other format (a Chase CSV and a QFX of the
same weeks) is skipped: the same posted date and amount, as many times as the other format has it. The amounts are
signed as the statement reads them: positive adds to the balance owed. Then srm.post_card_lines posts the new lines
to the register and srm.match_card_payments links the card's payments to the checking entries that paid them.
"""

import csv
import datetime
import hashlib
import html
import io
import json
import os
import re

from ..common import LoadRun, debug, log

SRM_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONFIG_FILE = os.path.join(SRM_DIR, "card_accounts.local.json")
DEFAULT_FOLDERS = ["~/MyCodeGIT/MxDataSRM/src-cards"]
CHASE_FILE = re.compile(r"^chase(\d{4})_", re.I)


def _tag(body, name):
    m = re.search(r"<" + name + r">([^<\r\n]*)", body)
    return html.unescape(m.group(1).strip()) if m else None


def _ofx_date(v):
    return datetime.date(int(v[:4]), int(v[4:6]), int(v[6:8]))


def _kind(owed, words, category=""):
    """charge, credit, payment, fee, interest or adjustment from the line's amount (+ owed), its type and name words
    and its category (lower case). A refund is a credit even where the category lumps it with payments (Discover's
    Payments and Credits)."""
    every = words + " " + category
    if "interest" in every and "payment" not in words:
        return "interest"
    if re.search(r"\b(fees?|srvchg|late charge)\b", every):
        return "fee" if owed > 0 else "credit"
    if owed < 0 and re.search(r"\bpayment|autopay|thank you", words):
        return "payment"
    if "adjust" in words:
        return "adjustment"
    return "charge" if owed > 0 else "credit"


CHASE_TYPES = {"sale": "charge", "return": "credit", "payment": "payment", "fee": "fee", "adjustment": "adjustment"}


def read_ofx(text):
    """[(last4, lines, (owed, available, as_of) or None)] of each credit card statement in a QFX / OFX file. OFX
    signs a card's amounts from the holder's side (a charge is negative), so they are turned around."""
    out = []
    for stmt in re.findall(r"<CCSTMTRS>(.*?)</CCSTMTRS>", text, re.S):
        acct = _tag(stmt, "ACCTID") or ""
        lines = []
        for body in re.findall(r"<STMTTRN>(.*?)</STMTTRN>", stmt, re.S):
            owed = -round(float(_tag(body, "TRNAMT")), 2)
            kind_type, name, memo = _tag(body, "TRNTYPE"), _tag(body, "NAME"), _tag(body, "MEMO")
            words = " ".join(x for x in (kind_type, name, memo) if x).lower()
            if (kind_type or "").upper() == "INT":
                words += " interest"
            lines.append({"fitid": _tag(body, "FITID"), "transDate": _ofx_date(_tag(body, "DTUSER")) if _tag(body, "DTUSER") else None,
                          "date": _ofx_date(_tag(body, "DTPOSTED")), "amount": owed, "kind": _kind(owed, words),
                          "type": kind_type, "name": name, "category": None, "memo": memo})
        bal = re.search(r"<LEDGERBAL>(.*?)</LEDGERBAL>", stmt, re.S)
        avail = re.search(r"<AVAILBAL>(.*?)</AVAILBAL>", stmt, re.S)
        balance = None
        if bal:
            balance = (-round(float(_tag(bal.group(1), "BALAMT")), 2),
                       round(float(_tag(avail.group(1), "BALAMT")), 2) if avail else None,
                       _ofx_date(_tag(bal.group(1), "DTASOF")))
        out.append((acct[-4:], lines, balance))
    return out


def _money(v):
    v = (v or "").replace("$", "").replace(",", "").strip()
    if not v:
        return 0.0
    neg = (v.startswith("(") and v.endswith(")")) or v.startswith("-")
    v = float(v.strip("()-"))
    return -v if neg else v


def _day(v):
    v = (v or "").strip()
    for fmt in ("%m/%d/%Y", "%m/%d/%y", "%Y-%m-%d"):
        try:
            return datetime.datetime.strptime(v, fmt).date()
        except ValueError:
            pass
    return None


def layout(header):
    """chase, discover or capitalone from a CSV header row, else None."""
    cols = [c.strip().lower() for c in header]
    if "transaction date" in cols and "post date" in cols and "type" in cols and "amount" in cols:
        return "chase"
    if any(c.startswith("trans. date") for c in cols) and "amount" in cols:
        return "discover"
    if "posted date" in cols and "card no." in cols and "debit" in cols:
        return "capitalone"
    return None


def read_csv(text):
    """(layout, [line + its card's last4 when the row names it]) of a Chase, Discover or Capital One CSV download.
    Chase: charges negative; Discover: charges positive; Capital One: Debit and Credit columns."""
    rows = [r for r in csv.reader(io.StringIO(text)) if any(c.strip() for c in r)]
    head = next((i for i, r in enumerate(rows) if layout(r)), None)
    if head is None:
        return None, []
    kind = layout(rows[head])
    cols = [c.strip().lower() for c in rows[head]]

    def col(*names):
        return next((i for i, c in enumerate(cols) if any(c.startswith(n) for n in names)), None)

    trans, post = col("transaction date", "trans. date"), col("post date", "posted date")
    desc, cat, typ, memo = col("description"), col("category"), col("type"), col("memo")
    amt, debit, credit, card = col("amount"), col("debit"), col("credit"), col("card no.")
    lines, seen = [], {}

    def cell(r, i):
        # Chase's CSV writes some names HTML-escaped (BARNES &amp; NOBLE).
        return html.unescape(r[i].strip()) if i is not None and i < len(r) else ""

    for r in rows[head + 1:]:
        posted = _day(cell(r, post)) or _day(cell(r, trans))
        if posted is None:
            continue
        if kind == "chase":
            owed = -_money(cell(r, amt))
        elif kind == "discover":
            owed = _money(cell(r, amt))
        else:
            owed = _money(cell(r, debit)) - _money(cell(r, credit))
        owed = round(owed, 2)
        name, category, trn_type = cell(r, desc) or None, cell(r, cat) or None, cell(r, typ) or None
        words = " ".join(x for x in (trn_type, name) if x).lower()
        line_kind = _kind(owed, words, (category or "").lower())
        if kind == "chase" and (trn_type or "").lower() in CHASE_TYPES and line_kind != "interest":
            line_kind = CHASE_TYPES[trn_type.lower()]
        key = "|".join(cell(r, i) for i in range(len(cols)))
        seen[key] = seen.get(key, 0) + 1
        lines.append({"fitid": "csv:" + hashlib.sha1(f"{key}|{seen[key]}".encode()).hexdigest()[:24],
                      "transDate": _day(cell(r, trans)), "date": posted, "amount": owed, "kind": line_kind,
                      "type": trn_type, "name": name, "category": category, "memo": cell(r, memo) or None,
                      "last4": (cell(r, card)[-4:] or None) if card is not None else None})
    return kind, lines


def _files(folders, single):
    paths = [single] if single else []
    for folder in ([] if single else folders):
        folder = os.path.expanduser(folder)
        for root, _, names in os.walk(folder):
            if root != folder and os.path.dirname(root) != folder:
                continue        # the folder and its card sub-folders only
            paths += [os.path.join(root, n) for n in names if n.lower().endswith((".qfx", ".ofx", ".csv"))]
    return sorted(set(paths), key=os.path.getmtime)


def statements(path, text, cards, by_last4):
    """[(code or None, lines, balance or None)] of one download."""
    name = os.path.basename(path)
    if not path.lower().endswith(".csv"):
        if "<CCSTMTRS>" not in text:
            return []       # a bank, brokerage or retirement plan file, not a card
        return [(by_last4.get(l4), lines, bal) for l4, lines, bal in read_ofx(text)]
    kind, lines = read_csv(text)
    if kind is None:
        return []           # not a card download we know
    folder = os.path.basename(os.path.dirname(path)).upper()
    if folder in cards:
        return [(folder, lines, None)]
    m = CHASE_FILE.match(name)
    if m:
        return [(by_last4.get(m.group(1)), lines, None)]
    if kind == "capitalone":
        groups = {}
        for l in lines:
            groups.setdefault(by_last4.get(l["last4"] or ""), []).append(l)
        return [(code, ls, None) for code, ls in groups.items()]
    return [(None, lines, None)]


def run(conn, cfg, args):
    single = getattr(args, "file", None)
    config = {}
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            config = json.load(f)
    folders = config.get("dropFolders") or DEFAULT_FOLDERS
    by_last4 = {k: v.upper() for k, v in (config.get("accounts") or {}).items()}
    with LoadRun(conn, "CARD_DOWNLOADS", "card_downloads", {"folders": folders, "file": single}) as run, conn.cursor() as cur:
        cur.execute("SELECT upper(code), card_account_id, account_last4 FROM srm.card_account WHERE closed_date IS NULL")
        cards = {c: (i, l4) for c, i, l4 in cur.fetchall()}
        for code, (_, l4) in cards.items():       # a card's own last four digits map it too
            if l4:
                by_last4.setdefault(l4, code)
        touched, new, skipped = set(), 0, 0
        for path in _files(folders, single):
            name = os.path.basename(path)
            try:
                text = open(path, encoding="utf-8-sig", errors="replace").read()
            except PermissionError:
                log(f"  can't read {path}: give the app that runs the loaders access to its folder")
                continue
            fmt = "CSV" if path.lower().endswith(".csv") else "OFX"
            for code, lines, balance in statements(path, text, cards, by_last4):
                if code not in cards:
                    run.reject(name, "card not mapped: set its last four digits on the card in MxAcctMGR (Banking ▸ "
                                     "Credit Card Accounts), put the file in a sub-folder named by the card's code, or "
                                     "map it in card_accounts.local.json")
                    continue
                aid = cards[code][0]
                touched.add(aid)
                # The other format's lines of the same days: a line found there (as many times as it is) is not new.
                other, occurrence = {}, {}
                if lines:
                    cur.execute("""SELECT posted_date, amount, count(*) FROM srm.card_line
                                    WHERE card_account_id = %s AND file_format <> %s AND posted_date BETWEEN %s AND %s
                                    GROUP BY 1, 2""",
                                (aid, fmt, min(l["date"] for l in lines), max(l["date"] for l in lines)))
                    other = {(d, float(a)): n for d, a, n in cur.fetchall()}
                for l in lines:
                    run.read += 1
                    k = (l["date"], l["amount"])
                    occurrence[k] = occurrence.get(k, 0) + 1
                    if occurrence[k] <= other.get(k, 0):
                        skipped += 1
                        continue
                    cur.execute("""INSERT INTO srm.card_line (card_account_id, fitid, trans_date, posted_date, amount, kind,
                                                              trn_type, name, category, memo, file_format, load_id)
                                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                                   ON CONFLICT (card_account_id, fitid) DO NOTHING""",
                                (aid, l["fitid"], l["transDate"], l["date"], l["amount"], l["kind"], l["type"],
                                 (l["name"] or "")[:200] or None, l["category"], l["memo"], fmt, run.load_id))
                    new += cur.rowcount
                if balance:
                    cur.execute("""UPDATE srm.card_account SET issuer_balance = %s, issuer_available = %s,
                                          issuer_balance_as_of = %s, updated_at = now()
                                    WHERE card_account_id = %s AND (issuer_balance_as_of IS NULL OR issuer_balance_as_of <= %s)""",
                                (balance[0], balance[1], balance[2], aid, balance[2]))
                debug(f"  {name}: {code}, {len(lines)} lines")
        posted = linked = 0
        for aid in touched:
            cur.execute("SELECT srm.post_card_lines(%s), srm.match_card_payments(%s)", (aid, aid))
            p, m = cur.fetchone()
            posted += p
            linked += m
        run.inserted += new
        run.updated += posted
        conn.commit()
        run.message = (f"{new} new card lines in {len(touched)} card(s) ({skipped} already read from the other format); "
                       f"{posted} posted to the register, {linked} payments linked to checking")
        log("  " + run.message)
