"""Credit card accounts for the accounts service: each card's register, its statement periods and payments (V029).

    GET  /cards/accounts                               cards with balance owed, available credit and the current statement
    PUT  /cards/accounts/<code>                        create or change one {name, issuer, last4, creditLimit, apr,
                                                       closeDay, dueDay, openingDate, openingBalance, payeeId, closedDate}
    GET  /cards/accounts/<code>/removal                what removing it would clean up: its register entries, the card
                                                       company's lines, its statements, its drop folder's downloads, and
                                                       the checking and cash-ledger entries linked to it (they stay)
    DELETE /cards/accounts/<code>?confirm=<code>&by=   removes it with its entries, lines and statements (the card's
                                                       code repeated as confirm); its drop folder is moved to _removed
    GET  /cards/accounts/<code>/register               its entries (running balance owed), statements and the checking
                                                       payments to it not linked to a card payment
    POST /cards/accounts/<code>/transactions           add an entry {date, kind, payeeId|payee, category, memo, amount, by}
    PUT  /cards/transactions/<id>                      change one {version, …}: refused (409) when someone changed it since
    POST /cards/transactions/<id>/link                 link a payment to the checking entry that paid it {bankTxnId} (null unlinks)
    POST /cards/accounts/<code>/pay                    pay it from a checking account {fromAccount, date, amount, memo, by}:
                                                       the checking entry and the card payment, linked
    PUT  /cards/accounts/<code>/statements/<closing>   what the statement says {statementBalance, minimumDue, dueDate, notes}
    POST /cards/accounts/<code>/import                 {filename, text}: the download saved in the card's drop folder, then
                                                       read (srm-loader POST /load/card-downloads); with no file, read them now.
                                                       With preview: true, what the file holds for the card, saving nothing:
                                                       each line new or already read, the totals by kind, the lines before
                                                       the card's opening date, categories with no category of ours. A file
                                                       that isn't a card download known here, or is another card's, is refused
    POST /cards/accounts/<code>/statements             read statement PDFs {files: [{fileName, text, pdf}], by}: text is the
                                                       PDF's text, pdf the file in base64, kept in the drop folder; each file
                                                       answers read, already, refused or otherNumber with why. Answers as
                                                       the register, with imported
    GET  /cards/targets                               the card registers' targets that aren't target accounts: each name as
                                                       the card company gives it, with its entries, total, dates and kinds
    POST /cards/targets                                make them target accounts {names: [...], by}: each a recipient of credit
                                                       card payments, in the category its entries mostly have, its entries
                                                       linked to it (a name a target account has already gets the card source)

Amounts are signed as a statement reads them: positive adds to the balance owed (charges, fees, interest), negative
lowers it (payments, credits). An entry is never deleted: it is voided.
"""

import base64
import calendar
import datetime as dt
import hashlib
import json
import os
import re
import urllib.request

import bank
import loans
from bank import Conflict, fetch, _date, _num, _payee

CODE = re.compile(r"^[A-Za-z0-9_\-]{1,40}$")
KINDS = ("charge", "credit", "payment", "fee", "interest", "adjustment")
STATUSES = ("pending", "posted", "reconciled", "void")
LOADER = "http://127.0.0.1:8770/load/card-downloads"


def _card(conn, code):
    rows = fetch(conn, "SELECT * FROM srm.card_account WHERE upper(code) = upper(%s)", (code,))
    if not rows:
        raise LookupError("no credit card account %s" % code)
    return rows[0]


def _f(v):
    return None if v is None else float(v)


# ------------------------------------------------------------------------------------------------------------ statements

def _closing(year, month, day):
    return dt.date(year, month, min(day, calendar.monthrange(year, month)[1]))


def _add_month(year, month, n=1):
    m = year * 12 + month - 1 + n
    return m // 12, m % 12 + 1


def _due(closing, close_day, due_day):
    """The payment due date of a statement closing on `closing`: the due day in the same month when it comes after
    the closing day, else in the next month."""
    if not due_day:
        return closing + dt.timedelta(days=25)
    y, m = (closing.year, closing.month) if due_day > (close_day or 0) else _add_month(closing.year, closing.month)
    return _closing(y, m, due_day)


def statements(conn, card, entries):
    """Each statement period from the opening date to the last closing date, newest first: what the register says
    (previous balance, charges, credits, payments, fees, interest, balance) beside what the statement says when
    entered (srm.card_statement), and whether it was paid by its due date."""
    if not card["statement_close_day"]:
        return []
    stored = {r["closing_date"]: r for r in fetch(conn, "SELECT * FROM srm.card_statement WHERE card_account_id = %s",
                                                  (card["card_account_id"],))}
    today = dt.date.today()
    close_day, due_day = card["statement_close_day"], card["payment_due_day"]
    y, m = card["opening_date"].year, card["opening_date"].month
    # A month's statement closes when it says it did, also when that isn't the card's usual day.
    closed = {(c.year, c.month): c for c in stored}
    closings = []
    while True:
        c = closed.get((y, m)) or _closing(y, m, close_day)
        if c > today:
            break
        # The opening date stands for a statement's closing: the first period is the next full one.
        if c >= card["opening_date"] + dt.timedelta(days=25):
            closings.append(c)
        y, m = _add_month(y, m)
    live = [e for e in entries if e["status"] != "void"]
    out, previous, start = [], float(card["opening_balance"]), card["opening_date"] + dt.timedelta(days=1)
    for c in closings:
        period = [e for e in live if start <= (e["postedDate"] or e["date"]) <= c]
        sums = {k: round(sum(float(e["amount"]) for e in period if e["kind"] == k), 2) for k in KINDS}
        balance = round(previous + sum(sums.values()), 2)
        s = stored.get(c) or {}
        due = s.get("due_date") or _due(c, close_day, due_day)
        owed = float(s["statement_balance"]) if s.get("statement_balance") is not None else balance
        paid = round(-sum(float(e["amount"]) for e in live if e["kind"] == "payment" and c < e["date"] <= due), 2)
        if s.get("minimum_due") is not None:
            minimum, estimated = float(s["minimum_due"]), False
        else:   # the usual card terms: the balance when small, else the greater of $40 and 1% plus interest and fees
            minimum = 0.0 if owed <= 0 else round(min(owed, max(40.0, owed * 0.01 + sums["interest"] + sums["fee"])), 2)
            estimated = True
        if owed <= 0:
            state = "nothing due"
        elif paid >= owed - 0.005:
            state = "paid"
        elif today <= due:
            state = "minimum paid" if paid >= minimum - 0.005 else "due"
        else:
            state = "minimum paid" if paid >= minimum - 0.005 else "late"
        out.append({"closingDate": c, "periodStart": start, "dueDate": due, "previousBalance": round(previous, 2),
                    "charges": sums["charge"], "credits": sums["credit"], "payments": sums["payment"],
                    "fees": sums["fee"], "interest": sums["interest"], "adjustments": sums["adjustment"],
                    "registerBalance": balance, "statementBalance": _f(s.get("statement_balance")),
                    "minimumDue": minimum, "minimumEstimated": estimated, "paid": paid, "state": state,
                    "notes": s.get("notes"), "version": s.get("version") or 0, "entries": len(period)})
        previous, start = balance, c + dt.timedelta(days=1)
    out.reverse()
    return out


# ------------------------------------------------------------------------------------------------------------ accounts

def accounts(conn):
    rows = fetch(conn, """
        SELECT a.card_account_id AS id, a.code, a.name, a.issuer, a.account_last4 AS last4, a.credit_limit AS "creditLimit",
               a.apr, a.statement_close_day AS "closeDay", a.payment_due_day AS "dueDay", a.opening_date AS "openingDate",
               a.opening_balance AS "openingBalance", a.payee_id AS "payeeId", p.name AS payee,
               a.issuer_balance AS "issuerBalance", a.issuer_available AS "issuerAvailable",
               a.issuer_balance_as_of AS "issuerBalanceAsOf", a.closed_date AS "closedDate",
               a.opening_balance + coalesce(sum(t.amount) FILTER (WHERE t.status <> 'void'), 0) AS balance,
               a.opening_balance + coalesce(sum(t.amount) FILTER (WHERE t.status IN ('posted', 'reconciled')), 0) AS "postedBalance",
               count(t.*) FILTER (WHERE t.status = 'pending') AS "pendingEntries",
               max(l.posted_date) AS "lastDownload"
          FROM srm.card_account a
          LEFT JOIN srm.payee p ON p.payee_id = a.payee_id
          LEFT JOIN srm.card_txn t ON t.card_account_id = a.card_account_id
          LEFT JOIN srm.card_line l ON l.card_line_id = t.card_line_id
         GROUP BY a.card_account_id, p.name ORDER BY a.closed_date NULLS FIRST, a.name""")
    for r in rows:
        r["available"] = round(float(r["creditLimit"]) - float(r["balance"]), 2) if r["creditLimit"] is not None else None
    return {"accounts": rows}


def save_account(conn, code, body):
    if not CODE.match(code):
        raise ValueError("card code must be 1–40 letters, digits, _ or -")
    name = (body.get("name") or "").strip()
    if not name:
        raise ValueError("name is required")
    last4 = (body.get("last4") or "").strip() or None
    if last4 and not re.match(r"^[0-9]{4}$", last4):
        raise ValueError("last4 is the card number's last four digits (never the whole number)")

    def day(key):
        v = body.get(key)
        if v in (None, ""):
            return None
        if not str(v).isdigit() or not 1 <= int(v) <= 31:
            raise ValueError("%s must be a day of the month (1–31)" % key)
        return int(v)

    def opt(key):
        return _num(body[key], key) if body.get(key) not in (None, "") else None

    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO srm.card_account (code, name, issuer, account_last4, credit_limit, apr, statement_close_day,
                                          payment_due_day, opening_date, opening_balance, payee_id, closed_date)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (code) DO UPDATE SET name = excluded.name, issuer = excluded.issuer,
                   account_last4 = excluded.account_last4, credit_limit = excluded.credit_limit, apr = excluded.apr,
                   statement_close_day = excluded.statement_close_day, payment_due_day = excluded.payment_due_day,
                   opening_date = excluded.opening_date, opening_balance = excluded.opening_balance,
                   payee_id = excluded.payee_id, closed_date = excluded.closed_date, updated_at = now()
            RETURNING card_account_id""",
                    (code.upper(), name[:120], (body.get("issuer") or "Chase").strip()[:80], last4, opt("creditLimit"),
                     opt("apr"), day("closeDay"), day("dueDay"), _date(body.get("openingDate") or dt.date.today()),
                     _num(body.get("openingBalance", 0) or 0, "openingBalance"), body.get("payeeId") or None,
                     _date(body["closedDate"]) if body.get("closedDate") else None))
        cid = cur.fetchone()[0]
    fetch(conn, "SELECT srm.match_card_payments(%s)", (cid,))
    conn.commit()
    return accounts(conn)


# ------------------------------------------------------------------------------------------------------------ register

TXN_SQL = """
    SELECT t.txn_id AS id, t.txn_date AS date, t.posted_date AS "postedDate", t.kind, t.payee_id AS "payeeId",
           coalesce(p.name, t.payee_name) AS payee, p.account_last4 AS "payeeLast4", p.institution AS "payeeInstitution",
           p.notes AS "payeeNote", p.nickname AS "payeeNickname", p.next_payment_date AS "payeeNextDate",
           p.next_payment_amount AS "payeeNextAmount", pl.address AS "linkAddress", pl.display_text AS "linkText", pl.hover_rtf AS "linkTip", pl.link_title AS "linkTitle",
           coalesce(g.category_code, p.category_code) AS category, c.name AS "categoryName", t.memo,
           t.amount, t.status, t.card_line_id AS "cardLineId", l.name AS "issuerName", l.category AS "issuerCategory",
           l.file_format AS "fileFormat", t.bank_txn_id AS "bankTxnId", ba.code AS "bankAccount", bt.txn_date AS "bankDate",
           bt.check_no AS "bankCheckNo", t.version, t.entered_by AS "enteredBy", t.created_at AS "enteredAt",
           t.updated_by AS "updatedBy", t.updated_at AS "updatedAt"
      FROM srm.card_txn t
      LEFT JOIN srm.payee p USING (payee_id)
      LEFT JOIN srm.payee_link pl ON pl.payee_id = t.payee_id
      LEFT JOIN srm.spending_tag g ON g.card_txn_id = t.txn_id
      LEFT JOIN srm.spending_category c ON c.code = coalesce(g.category_code, p.category_code)
      LEFT JOIN srm.card_line l ON l.card_line_id = t.card_line_id
      LEFT JOIN srm.bank_txn bt ON bt.txn_id = t.bank_txn_id
      LEFT JOIN srm.bank_account ba ON ba.bank_account_id = bt.bank_account_id"""


def register(conn, code):
    card = _card(conn, code)
    acct = [a for a in accounts(conn)["accounts"] if a["code"].upper() == card["code"].upper()][0]
    rows = [bank.nest_link(r, "payeeLink") for r in
            fetch(conn, TXN_SQL + " WHERE t.card_account_id = %s ORDER BY coalesce(t.posted_date, t.txn_date), t.txn_date, t.txn_id",
                  (card["card_account_id"],))]
    balance = float(card["opening_balance"])
    for r in rows:
        if r["status"] != "void":
            balance += float(r["amount"])
        r["balance"] = round(balance, 2)
    unlinked = []
    if card["payee_id"]:
        unlinked = fetch(conn, """
            SELECT t.txn_id AS id, a.code AS "bankAccount", t.txn_date AS date, t.kind, t.check_no AS "checkNo",
                   t.amount, t.memo, t.status
              FROM srm.bank_txn t JOIN srm.bank_account a USING (bank_account_id)
             WHERE t.payee_id = %s AND t.status <> 'void' AND t.txn_date >= %s
               AND NOT EXISTS (SELECT 1 FROM srm.card_txn c WHERE c.bank_txn_id = t.txn_id)
             ORDER BY t.txn_date""", (card["payee_id"], card["opening_date"]))
    return {"account": acct, "entries": rows, "statements": statements(conn, card, rows), "unlinkedPayments": unlinked,
            "missingStatements": missing_statements(conn, card)}


def _fields(conn, body, current=None):
    cur = current or {}
    kind = body.get("kind", cur.get("kind", "charge"))
    if kind not in KINDS:
        raise ValueError("kind must be one of " + ", ".join(KINDS))
    amount = _num(body.get("amount", cur.get("amount")), "amount")
    if amount == 0:
        raise ValueError("amount must not be zero")
    # Charges, fees and interest add to what is owed; payments and credits lower it. Adjustments keep their sign.
    if kind in ("charge", "fee", "interest"):
        amount = abs(amount)
    elif kind in ("payment", "credit"):
        amount = -abs(amount)
    status = body.get("status", cur.get("status", "pending"))
    if status not in STATUSES:
        raise ValueError("status must be one of " + ", ".join(STATUSES))
    if "payeeId" in body or "payee" in body:
        payee_id, payee_name = _payee(conn, body, source="card")
    else:
        payee_id, payee_name = cur.get("payeeId"), cur.get("payee")
    return {"txn_date": _date(body.get("date", cur.get("date")) or dt.date.today()), "kind": kind,
            "payee_id": payee_id, "payee_name": payee_name,
            "memo": (body.get("memo", cur.get("memo")) or "").strip()[:200] or None, "amount": amount, "status": status}


def add_transaction(conn, code, body, commit=True):
    card = _card(conn, code)
    f = _fields(conn, body)
    rows = fetch(conn, """
        INSERT INTO srm.card_txn (card_account_id, txn_date, kind, payee_id, payee_name, memo, amount,
                                  status, bank_txn_id, entered_by, updated_by)
        VALUES (%(cid)s, %(txn_date)s, %(kind)s, %(payee_id)s, %(payee_name)s, %(memo)s, %(amount)s,
                %(status)s, %(bank)s, %(by)s, %(by)s) RETURNING txn_id""",
                 dict(f, cid=card["card_account_id"], bank=body.get("bankTxnId"), by=str(body.get("by") or "MxAcctMGR")[:80]))
    if f["kind"] != "payment":
        bank.file_category(conn, "card_txn_id", rows[0]["txn_id"], f["payee_id"], body)
    if not commit:
        return rows[0]["txn_id"]
    # A charge entered from a receipt may already be among the card company's lines: post them now.
    fetch(conn, "SELECT srm.post_card_lines(%s), srm.match_card_payments(%s)", (card["card_account_id"], card["card_account_id"]))
    conn.commit()
    return {"id": rows[0]["txn_id"], **register(conn, code)}


def update_transaction(conn, txn_id, body):
    rows = fetch(conn, TXN_SQL + " WHERE t.txn_id = %s FOR UPDATE OF t", (txn_id,))
    if not rows:
        raise LookupError("no card register entry %s" % txn_id)
    cur = rows[0]
    if "version" not in body:
        raise ValueError("version is required: the version the edit was made from")
    if int(body["version"]) != cur["version"]:
        conn.rollback()
        raise Conflict("%s changed this entry on %s (version %d) since you opened it (version %d)"
                       % (cur["updatedBy"] or "someone", cur["updatedAt"].strftime("%Y-%m-%d at %H:%M"), cur["version"],
                          int(body["version"])), version=cur["version"])
    f = _fields(conn, body, cur)
    unmatch = f["status"] in ("pending", "void") and cur["cardLineId"] is not None
    by = str(body.get("by") or "MxAcctMGR")[:80]
    with conn.cursor() as c:
        c.execute("""UPDATE srm.card_txn SET txn_date = %(txn_date)s, kind = %(kind)s, payee_id = %(payee_id)s,
                            payee_name = %(payee_name)s, memo = %(memo)s,
                            amount = %(amount)s, status = %(status)s,
                            card_line_id = CASE WHEN %(unmatch)s THEN NULL ELSE card_line_id END,
                            posted_date = CASE WHEN %(unmatch)s THEN NULL ELSE posted_date END,
                            bank_txn_id = CASE WHEN %(void)s THEN NULL ELSE bank_txn_id END,
                            version = version + 1, updated_by = %(by)s, updated_at = now()
                      WHERE txn_id = %(id)s RETURNING card_account_id""",
                  dict(f, id=txn_id, unmatch=unmatch, void=f["status"] == "void", by=by))
        cid = c.fetchone()[0]
    if f["kind"] != "payment":
        bank.file_category(conn, "card_txn_id", txn_id, f["payee_id"], body)
    # The payee picked for a card company's line: its name there maps to that payee from now on.
    if f["payee_id"] and cur["issuerName"] and f["payee_id"] != cur["payeeId"]:
        fetch(conn, """UPDATE srm.payee SET bank_names = array_append(bank_names, %s)
                        WHERE payee_id = %s AND lower(name) <> lower(%s)
                          AND NOT (lower(%s) = ANY (SELECT lower(x) FROM unnest(bank_names) x))""",
              (cur["issuerName"], f["payee_id"], cur["issuerName"], cur["issuerName"]))
    code = fetch(conn, "SELECT code FROM srm.card_account WHERE card_account_id = %s", (cid,))[0]["code"]
    conn.commit()
    return register(conn, code)


def link_payment(conn, txn_id, body):
    rows = fetch(conn, """SELECT t.card_account_id, t.kind, t.amount, a.code, a.payee_id FROM srm.card_txn t
                           JOIN srm.card_account a USING (card_account_id) WHERE t.txn_id = %s FOR UPDATE OF t""", (txn_id,))
    if not rows:
        raise LookupError("no card register entry %s" % txn_id)
    t = rows[0]
    bank_txn = body.get("bankTxnId")
    if bank_txn:
        if t["kind"] != "payment":
            raise ValueError("only a payment links to a checking entry")
        b = fetch(conn, "SELECT amount, status FROM srm.bank_txn WHERE txn_id = %s", (int(bank_txn),))
        if not b or b[0]["status"] == "void":
            raise ValueError("no checking entry %s" % bank_txn)
        if fetch(conn, "SELECT 1 FROM srm.card_txn WHERE bank_txn_id = %s AND txn_id <> %s", (int(bank_txn), txn_id)):
            raise Conflict("that checking entry already paid another card payment")
    fetch(conn, """UPDATE srm.card_txn SET bank_txn_id = %s, version = version + 1, updated_by = %s, updated_at = now()
                    WHERE txn_id = %s""", (int(bank_txn) if bank_txn else None, body.get("by") or "MxAcctMGR", txn_id))
    conn.commit()
    return register(conn, t["code"])


def pay(conn, code, body):
    """A payment from a checking account: the checking entry (to the card's external account, a transfer) and the
    card's payment, linked; the card company's line for it posts the payment when it is read."""
    card = _card(conn, code)
    if not card["payee_id"]:
        raise ValueError("set the card's external account (how the check register pays it) first: Edit… ▸ Paid from checking as")
    amount = abs(_num(body.get("amount"), "amount"))
    if amount == 0:
        raise ValueError("amount must not be zero")
    by = str(body.get("by") or "MxAcctMGR")[:80]
    date = body.get("date") or dt.date.today().isoformat()
    memo = body.get("memo") or "%s payment" % card["name"]
    out = bank.add_transaction(conn, body.get("fromAccount") or "", {
        "date": date, "kind": "transfer", "payeeId": card["payee_id"], "memo": memo, "amount": -amount, "by": by},
        match=False)
    add_transaction(conn, code, {"date": date, "kind": "payment", "payeeId": card["payee_id"], "memo": memo,
                                 "amount": amount, "bankTxnId": out["id"], "by": by}, commit=False)
    fetch(conn, "SELECT srm.post_card_lines(%s)", (card["card_account_id"],))
    fetch(conn, "SELECT srm.match_bank_lines(bank_account_id) FROM srm.bank_txn WHERE txn_id = %s", (out["id"],))
    conn.commit()
    return register(conn, code)


def save_statement(conn, code, closing, body):
    card = _card(conn, code)
    closing = _date(closing, "closing date")

    def opt(key):
        return _num(body[key], key) if body.get(key) not in (None, "") else None

    cur = fetch(conn, "SELECT version FROM srm.card_statement WHERE card_account_id = %s AND closing_date = %s FOR UPDATE",
                (card["card_account_id"], closing))
    if cur and int(body.get("version", -1)) != cur[0]["version"]:
        conn.rollback()
        raise Conflict("someone changed this statement since you opened it", version=cur[0]["version"])
    fetch(conn, """
        INSERT INTO srm.card_statement (card_account_id, closing_date, statement_balance, minimum_due, due_date, notes, updated_by)
        VALUES (%s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (card_account_id, closing_date) DO UPDATE SET statement_balance = excluded.statement_balance,
               minimum_due = excluded.minimum_due, due_date = excluded.due_date, notes = excluded.notes,
               updated_by = excluded.updated_by, version = srm.card_statement.version + 1, updated_at = now()""",
          (card["card_account_id"], closing, opt("statementBalance"), opt("minimumDue"),
           _date(body["dueDate"], "dueDate") if body.get("dueDate") else None,
           (body.get("notes") or "").strip()[:2000] or None, str(body.get("by") or "MxAcctMGR")[:80]))
    conn.commit()
    return register(conn, code)


def _drop_folder(code, create=True):
    """The card's sub-folder of the first drop folder (card_accounts.local.json), where Import File… saves a download."""
    from srmlib.loaders import card_downloads   # SRM's folder is on sys.path (accounts_service.SRM)
    folders = card_downloads.DEFAULT_FOLDERS
    if os.path.exists(card_downloads.CONFIG_FILE):
        with open(card_downloads.CONFIG_FILE) as f:
            folders = json.load(f).get("dropFolders") or folders
    folder = os.path.join(os.path.expanduser(folders[0]), code.upper())
    if create:
        os.makedirs(folder, exist_ok=True)
    return folder


def _download(conn, card, body):
    """(file name, what it is, the file's lines for the card) of an uploaded download, refused (ValueError) when it isn't
    a card download known here or the card it names is another one — as card-downloads would read it from the card's
    sub-folder."""
    from srmlib.loaders import card_downloads   # SRM's folder is on sys.path (accounts_service.SRM)
    name = os.path.basename(str(body.get("filename") or "download.csv"))
    if not re.match(r"^[\w .()\-]{1,120}\.(csv|qfx|ofx)$", name, re.I):
        raise ValueError("a card download is a .csv, .qfx or .ofx file")
    text = str(body["text"]).lstrip("\ufeff")
    what, found = card_downloads.read_file(name, text)
    if not what:
        raise ValueError("%s isn't a card download MxAcctMGR reads: Chase CSV or QFX / OFX, Discover or Capital One CSV"
                         % name)
    with conn.cursor() as cur:
        cards, by_last4 = card_downloads.last4_map(cur, card_downloads.config())
    code, lines, others = card["code"].upper(), [], set()
    for l4, ls, _ in found:
        to = card_downloads.card_of(l4, what == "QFX / OFX", code, cards, by_last4)
        if to == code:
            lines += ls
        else:
            others.add(to or "···" + (l4 or "?"))
    if not lines:
        names = {r["code"].upper(): r["name"] for r in fetch(conn, "SELECT code, name FROM srm.card_account")}
        raise ValueError("%s is the activity of %s, not %s: pick that card to import it"
                         % (name, ", ".join(sorted(names.get(o, o) for o in others)), card["name"]))
    return name, what, lines


def preview_download(conn, card, body):
    """What an uploaded download holds for the card, saving nothing: its lines, each new or already read."""
    from srmlib.loaders import card_downloads
    name, what, lines = _download(conn, card, body)
    fmt = "CSV" if name.lower().endswith(".csv") else "OFX"
    with conn.cursor() as cur:
        states = card_downloads.states(cur, card["card_account_id"], fmt, lines)
    mapped = {r["c"] for r in fetch(conn, "SELECT issuer_category AS c FROM srm.card_category WHERE category_code IS NOT NULL")}
    new = [l for l, st in zip(lines, states) if st == "new"]
    kinds = {}
    for l in new:
        k = kinds.setdefault(l["kind"], {"kind": l["kind"], "count": 0, "total": 0.0})
        k["count"] += 1
        k["total"] = round(k["total"] + l["amount"], 2)
    opening = card["opening_date"]
    # A CSV file doesn't name its card (Discover's): one from another card company is likely the wrong card's.
    company = what[:-4] if what.endswith(" CSV") else None
    issuer = (card["issuer"] or "").strip()
    other_company = bool(company and issuer and company.lower() not in issuer.lower()
                         and issuer.lower() not in company.lower())
    return {"preview": {
        "file": name, "what": what, "lines": len(lines), "new": len(new),
        "otherCompany": "%s is a %s download, and %s is a %s card" % (name, company, card["name"], issuer) if other_company else None,
        "read": states.count("read"), "otherFormat": states.count("other format"),
        "first": min(l["date"] for l in lines), "last": max(l["date"] for l in lines),
        "openingDate": opening,
        "beforeOpening": sum(1 for l in new if opening and (l["transDate"] or l["date"]) < opening),
        "kinds": sorted(kinds.values(), key=lambda k: KINDS.index(k["kind"]) if k["kind"] in KINDS else 99),
        "unmapped": sorted({l["category"] for l in new if l["category"] and l["kind"] == "charge"
                            and l["category"].lower() not in mapped}),
        "entries": [{"date": l["transDate"] or l["date"], "postedDate": l["date"], "kind": l["kind"], "name": l["name"],
                     "category": l["category"], "amount": l["amount"], "state": st}
                    for l, st in zip(lines, states)]}}


def import_downloads(conn, code, body):
    """Saves an uploaded download in the card's drop folder, then runs srm.py load card-downloads through srm-loader
    (so it shows in the activity log), then the register. With preview, only what the file holds."""
    card = _card(conn, code)
    if body.get("text") and body.get("preview"):
        return preview_download(conn, card, body)
    saved = None
    if body.get("text"):
        name, _, _ = _download(conn, card, body)
        saved = os.path.join(_drop_folder(card["code"]), name)
        with open(saved, "w", encoding="utf-8") as f:
            f.write(body["text"])
        os.utime(saved)   # read last: the newest download's balance wins
    req = urllib.request.Request(LOADER, data=b"", method="POST")
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            out = json.load(r)
    except Exception as e:
        raise ValueError("srm-loader (port 8770) didn't run card-downloads: %s" % e)
    run = (out.get("runs") or [{}])[-1]
    return {"load": {"status": run.get("status") or out.get("status"), "message": run.get("message") or out.get("error"),
                     "file": saved and os.path.basename(saved)},
            **register(conn, code)}


# --------------------------------------------------------------------------------------------- statements from their PDFs

STATEMENT_MONEY = r"([-+]?\s*\$?\s*[\d,]+\.\d\d)"
STATEMENT_ROW = re.compile(r"^(\d\d)/(\d\d)\s+(.+?)\s+(-?[\d,]*\.\d\d)\s*$")
# Where the rows a statement lists end: its other tables list rewards or repeat rows that are already counted.
STATEMENT_ACTIVITY = re.compile(r"ACCOUNT ACTIVITY.*?(?=^INTEREST CHARGES\s*$|^SHOP WITH POINTS ACTIVITY|\Z)", re.S | re.M)
STATEMENT_TOTAL = re.compile(r"^TOTAL (FEES|INTEREST) FOR THIS PERIOD\s+\$?([\d,]+\.\d\d)", re.I)


def _statement_money(text, label):
    m = re.search(label + r"\s*:?\s+" + STATEMENT_MONEY, text)
    return float(re.sub(r"[\s$,+]", "", m.group(1))) if m else None


def _statement_day(s):
    return dt.datetime.strptime(s, "%m/%d/%y").date()


def _statement_kind(amount, name, section):
    """charge, credit, payment or adjustment from the part of the statement that lists the row. A fee or interest row
    is marked by the total that follows it (_statement_rows): merchants' names say "fee" as well."""
    if amount < 0 and re.search(r"^(payment thank you|autopay|automatic payment)", name, re.I):
        return "payment"   # whichever part of the statement it's read under
    if section == "credits" and amount < 0 and re.search(r"\bpayment|autopay|thank you", name, re.I):
        return "payment"
    if amount < 0:
        return "credit"
    if section == "credits" or re.search(r"\bcredit balance refund\b", name, re.I):
        return "adjustment"   # the card company paying a credit balance back: not spending
    return "charge"


def _statement_rows(text, start, closing):
    """Each transaction a statement lists, in its order. A row gives only the month and day: the year is the last one
    that doesn't put it after the closing date. posted_date isn't on a statement: it is the transaction date, or the
    opening date when it was made before it, so the line falls in this statement's period. The same row twice in a
    statement (two charges alike the same day) is two lines."""
    rows, section, seen = [], "purchases", {}
    for part in STATEMENT_ACTIVITY.findall(text):
        for line in part.splitlines():
            line = line.strip()
            if line.startswith("PAYMENTS AND OTHER CREDITS"):
                section = "credits"
            elif line.startswith(("PURCHASE", "CASH ADVANCE", "BALANCE TRANSFER", "FEES CHARGED", "INTEREST CHARGED")):
                section = "purchases"
            total = STATEMENT_TOTAL.match(line)
            if total:   # the rows just above add up to it
                left = float(total.group(2).replace(",", ""))
                for r in reversed(rows):
                    if left < 0.005:
                        break
                    r["kind"] = "fee" if total.group(1).upper() == "FEES" else "interest"
                    left = round(left - r["amount"], 2)
                continue
            m = STATEMENT_ROW.match(line)
            if not m:
                continue
            amount, name = round(float(m.group(4).replace(",", "")), 2), m.group(3)
            try:
                day = dt.date(closing.year, int(m.group(1)), int(m.group(2)))
                if day > closing:
                    day = dt.date(closing.year - 1, int(m.group(1)), int(m.group(2)))
            except ValueError:
                raise ValueError("a row's date can't be read: %s/%s" % (m.group(1), m.group(2)))
            key = "%s|%s|%s|%s" % (closing, day, name, amount)
            seen[key] = seen.get(key, 0) + 1
            rows.append({"fitid": "pdf:" + hashlib.sha1(("%s|%d" % (key, seen[key])).encode()).hexdigest()[:24],
                         "transDate": day, "date": max(day, start), "amount": amount, "name": name, "type": None,
                         "kind": _statement_kind(amount, name, section), "category": None, "memo": None})
    return rows


def parse_statement(text):
    """What a card statement's text says: Chase's layout (PDFKit's reading order) is the one read. Refused (ValueError)
    when it isn't one, or when its rows don't add up to the change in its balance: the lines can't be taken back."""
    period = re.search(r"Opening/Closing Date\s+(\d\d/\d\d/\d\d)\s*-\s*(\d\d/\d\d/\d\d)", text)
    if not period or "ACCOUNT SUMMARY" not in text:
        raise ValueError("it isn't a statement layout MxAcctMGR reads (Chase's)")
    start, closing = _statement_day(period.group(1)), _statement_day(period.group(2))
    previous, balance = _statement_money(text, "Previous Balance"), _statement_money(text, "New Balance")
    if previous is None or balance is None:
        raise ValueError("its previous and new balance can't be read")
    rows = _statement_rows(text, start, closing)
    total = round(sum(r["amount"] for r in rows), 2)
    if abs(round(balance - previous, 2) - total) >= 0.005:
        raise ValueError("its transactions add up to ${:,.2f} and its balance changed by ${:,.2f}: nothing was kept"
                         .format(total, round(balance - previous, 2)))
    number = re.search(r"Account Number:\s*[X\s]*(\d{4})\b", text)
    due = re.search(r"Payment Due Date:?\s+(\d\d/\d\d/\d\d)", text)
    rate = re.search(r"^Purchases\s+(\d+\.\d+)%", text, re.M)
    limit = re.search(r"Credit Access Line\s+\$([\d,]+)", text)
    return {"start": start, "closing": closing, "previous": previous, "balance": balance, "rows": rows,
            "last4": number.group(1) if number else None, "due": _statement_day(due.group(1)) if due else None,
            "minimum": _statement_money(text, "Minimum Payment Due"), "apr": float(rate.group(1)) if rate else None,
            "limit": float(limit.group(1).replace(",", "")) if limit else None}


def _continues(conn, card, s):
    """Whether a statement naming another number carries on from a statement of this card: the day after one closed or
    the day before one starts, with the balance it left. A reissued card's number changes, its balance doesn't."""
    if not s["balance"] and not s["previous"]:
        return False
    return bool(fetch(conn, """
        SELECT 1 FROM srm.card_statement
         WHERE card_account_id = %s AND ((period_start = %s AND previous_balance = %s AND %s <> 0)
                                         OR (closing_date = %s AND statement_balance = %s AND %s <> 0))""",
                      (card["card_account_id"], s["closing"] + dt.timedelta(days=1), s["balance"], s["balance"],
                       s["start"] - dt.timedelta(days=1), s["previous"], s["previous"])))


def _read_statement(conn, cur, card, s, name, data, sha, by, run):
    """Keeps a statement's figures, PDF and lines; the lines a download already gave aren't read again. (new lines, lines
    read from a download already)"""
    from srmlib.loaders import card_downloads   # SRM's folder is on sys.path (accounts_service.SRM)
    aid = card["card_account_id"]
    states = card_downloads.states(cur, aid, "PDF", s["rows"])
    if data is not None:
        name = os.path.basename(loans.save_pdf(_drop_folder(card["code"]), name, data))
    fetch(conn, """
        INSERT INTO srm.card_statement (card_account_id, closing_date, statement_balance, minimum_due, due_date, updated_by,
                                        period_start, previous_balance, card_last4, credit_limit, apr, file_name, file_sha256)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (card_account_id, closing_date) DO UPDATE SET statement_balance = excluded.statement_balance,
               minimum_due = excluded.minimum_due, due_date = excluded.due_date, updated_by = excluded.updated_by,
               period_start = excluded.period_start, previous_balance = excluded.previous_balance,
               card_last4 = excluded.card_last4, credit_limit = excluded.credit_limit, apr = excluded.apr,
               file_name = excluded.file_name, file_sha256 = excluded.file_sha256,
               version = srm.card_statement.version + 1, updated_at = now()""",
          (aid, s["closing"], s["balance"], s["minimum"], s["due"], by, s["start"], s["previous"], s["last4"], s["limit"], s["apr"], name, sha))
    new = 0
    for l, state in zip(s["rows"], states):
        if state != "new":
            continue
        cur.execute("""INSERT INTO srm.card_line (card_account_id, fitid, trans_date, posted_date, amount, kind, trn_type,
                                                  name, category, memo, file_format, load_id)
                       VALUES (%s, %s, %s, %s, %s, %s, NULL, %s, NULL, NULL, 'PDF', %s)
                       ON CONFLICT (card_account_id, fitid) DO NOTHING""",
                    (aid, l["fitid"], l["transDate"], l["date"], l["amount"], l["kind"], l["name"][:200], run.load_id))
        new += cur.rowcount
    return new, states.count("other format")


def _fill_card(conn, card, first):
    """What the card leaves empty, from its latest statement: last four digits, closing and due days, limit and APR. The
    digits, limit and APR follow the statements while they are what an earlier statement said (a reissued card, a new
    rate); one typed in stays. A card only statements have filled starts where the earliest statement read (first)
    starts, owing what that statement brought forward."""
    aid = card["card_account_id"]
    latest = fetch(conn, """
        SELECT closing_date, due_date, card_last4, credit_limit, apr FROM srm.card_statement
         WHERE card_account_id = %s AND file_sha256 IS NOT NULL ORDER BY closing_date DESC LIMIT 1""", (aid,))[0]

    def follows(column):
        return """%(col)s = CASE WHEN %(col)s IS NULL OR %(col)s IN
                                      (SELECT %(from)s FROM srm.card_statement
                                        WHERE card_account_id = %%(a)s AND closing_date < %%(c)s AND %(from)s IS NOT NULL)
                                 THEN coalesce(%%(%(from)s)s, %(col)s) ELSE %(col)s END""" % {"col": column[0], "from": column[1]}

    fetch(conn, "UPDATE srm.card_account SET " + ", ".join(follows(c) for c in (
        ("account_last4", "card_last4"), ("credit_limit", "credit_limit"), ("apr", "apr"))) + """,
               statement_close_day = coalesce(statement_close_day, %(close)s),
               payment_due_day = coalesce(payment_due_day, %(due)s), updated_at = now()
         WHERE card_account_id = %(a)s""",
          {"a": aid, "c": latest["closing_date"], "card_last4": latest["card_last4"], "credit_limit": latest["credit_limit"],
           "apr": latest["apr"], "close": latest["closing_date"].day,
           "due": latest["due_date"].day if latest["due_date"] else None})
    downloaded = fetch(conn, "SELECT 1 FROM srm.card_line WHERE card_account_id = %s AND file_format <> 'PDF' LIMIT 1", (aid,))
    if not downloaded and first["start"] <= card["opening_date"]:
        fetch(conn, """UPDATE srm.card_account SET opening_date = %s, opening_balance = %s, updated_at = now()
                        WHERE card_account_id = %s""",
              (first["start"] - dt.timedelta(days=1), first["previous"], aid))


def import_statements(conn, code, body):
    """Reads statement PDFs (their text; the service has no PDF reader). A statement read before, by its file's SHA-256,
    is skipped; another card's is refused; one naming a number no card has waits as otherNumber until it carries on from
    a statement of this card (a reissued card), so the app sends those again once the others are read."""
    from srmlib.common import LoadRun
    from srmlib.loaders import card_downloads
    card = _card(conn, code)
    by = str(body.get("by") or "MxAcctMGR")[:80]
    results, read = [], []
    with LoadRun(conn, "CARD_DOWNLOADS", "card_statements", {"card": card["code"], "files": len(body.get("files") or [])}) as run, conn.cursor() as cur:
        aid = card["card_account_id"]
        fetch(conn, "SELECT 1 FROM srm.card_account WHERE card_account_id = %s FOR UPDATE", (aid,))
        card = _card(conn, code)
        cards, by_last4 = card_downloads.last4_map(cur, card_downloads.config())
        for f in body.get("files") or []:
            name = os.path.basename(str(f.get("fileName") or "statement.pdf"))[:200]
            r = {"fileName": name}
            results.append(r)
            run.read += 1
            try:
                text = str(f.get("text") or "")
                if not text.strip():
                    raise ValueError("it has no text to read (a scanned image?)")
                data = base64.b64decode(f["pdf"]) if f.get("pdf") else None
                sha = hashlib.sha256(data if data is not None else text.encode()).hexdigest()
                if fetch(conn, "SELECT 1 FROM srm.card_statement WHERE card_account_id = %s AND file_sha256 = %s", (aid, sha)):
                    r.update(status="already", message="read already")
                    continue
                s = parse_statement(text)
                mine, owner, note = card["account_last4"], by_last4.get(s["last4"]), ""
                if owner and owner != card["code"].upper():
                    raise ValueError("it is the statement of card ···%s (%s)" % (s["last4"], owner))
                if s["last4"] and mine and s["last4"] != mine and not owner:
                    if not _continues(conn, card, s):
                        r.update(status="otherNumber", message="it is for card ···%s, not ···%s, and doesn't carry on from a statement of this card" % (s["last4"], mine))
                        continue
                    note = " (under the card's other number ···%s)" % s["last4"]
                fetch(conn, "SAVEPOINT statement")
                try:
                    new, skipped = _read_statement(conn, cur, card, s, name, data, sha, by, run)
                    fetch(conn, "RELEASE SAVEPOINT statement")
                except Exception:
                    fetch(conn, "ROLLBACK TO SAVEPOINT statement")
                    raise
                run.inserted += new
                read.append(s)
                r.update(status="read", closingDate=s["closing"], lines=new, downloaded=skipped,
                         message="closing %s: balance %s, %d new lines%s" % (s["closing"].strftime("%m/%d/%Y"), "${:,.2f}".format(s["balance"]), new, note))
            except (ValueError, KeyError) as e:
                r.update(status="refused", message=str(e).strip("'\""))
        if read:
            _fill_card(conn, card, min(read, key=lambda s: s["start"]))
            cur.execute("SELECT srm.post_card_lines(%s), srm.match_card_payments(%s)", (aid, aid))
            run.updated += cur.fetchone()[0]
        run.message = "%s: %d of %d statements read, %d new lines" % (card["code"], len(read), len(results), run.inserted)
        conn.commit()
    return dict(register(conn, code), imported=results)


def missing_statements(conn, card):
    """The periods between two statements read from their PDFs that none covers: their lines aren't in the register."""
    rows = fetch(conn, """
        SELECT closing_date, period_start, previous_balance, statement_balance FROM srm.card_statement
         WHERE card_account_id = %s AND period_start IS NOT NULL ORDER BY closing_date""", (card["card_account_id"],))
    out = []
    for a, b in zip(rows, rows[1:]):
        if a["closing_date"] + dt.timedelta(days=1) < b["period_start"]:
            out.append({"from": a["closing_date"] + dt.timedelta(days=1), "to": b["period_start"] - dt.timedelta(days=1),
                        "before": _f(a["statement_balance"]), "after": _f(b["previous_balance"])})
    return out


# ------------------------------------------------------------------------------------------------------------ removal

def removal(conn, code):
    """What removing the card would clean up: its register entries (and how many were entered here, not from a
    download), the card company's lines, its statements and its drop folder's files; and what stays, unlinked: the
    checking entries that paid it and the cash-ledger entries naming its charges. `remembered`: what was made on its
    downloaded lines — tags, Amazon matches, family-page notes, tax-year moves, edited entries — kept to re-attach when
    a card with the same last four digits reads those lines again (V049)."""
    card = _card(conn, code)
    counts = fetch(conn, """
        SELECT (SELECT count(*) FROM srm.card_txn WHERE card_account_id = %(a)s) AS entries,
               (SELECT count(*) FROM srm.card_txn WHERE card_account_id = %(a)s AND card_line_id IS NULL) AS "enteredHere",
               (SELECT count(*) FROM srm.card_line WHERE card_account_id = %(a)s) AS lines,
               (SELECT count(*) FROM srm.card_statement WHERE card_account_id = %(a)s) AS statements,
               (SELECT count(*) FROM srm.card_txn WHERE card_account_id = %(a)s AND bank_txn_id IS NOT NULL) AS "checkingLinked",
               (SELECT count(*) FROM srm.expense_entry e JOIN srm.card_txn t ON t.txn_id = e.card_txn_id
                 WHERE t.card_account_id = %(a)s) AS "expenseLinked",
               (SELECT name FROM srm.payee WHERE payee_id = %(p)s) AS payee""",
                   {"a": card["card_account_id"], "p": card["payee_id"]})[0]
    counts["remembered"] = fetch(conn, """
        SELECT count(g.*) AS tags, (SELECT count(*) FROM srm.amazon_match m JOIN srm.card_txn x ON x.txn_id = m.card_txn_id
                                     WHERE x.card_account_id = %(a)s AND x.card_line_id IS NOT NULL) AS "amazonMatches",
               (SELECT count(*) FROM srm.spending_feedback f JOIN srm.card_txn x ON x.txn_id = f.entry_id
                 WHERE f.entry_source = 'card' AND x.card_account_id = %(a)s AND x.card_line_id IS NOT NULL) AS notes,
               (SELECT count(*) FROM srm.tax_assignment s JOIN srm.card_txn x ON x.txn_id = s.entry_id
                 WHERE s.source = 'card' AND x.card_account_id = %(a)s AND x.card_line_id IS NOT NULL) AS "taxMoves",
               (SELECT count(*) FROM srm.card_txn x WHERE x.card_account_id = %(a)s AND x.card_line_id IS NOT NULL
                   AND coalesce(x.updated_by, '') NOT IN ('card download', 'card match', 'payment match', '')) AS edited,
               coalesce(nullif(btrim(%(l)s), ''), %(c)s) AS "cardKey"
          FROM srm.spending_tag g JOIN srm.card_txn t ON t.txn_id = g.card_txn_id
         WHERE t.card_account_id = %(a)s AND t.card_line_id IS NOT NULL""",
                                 {"a": card["card_account_id"], "l": card["account_last4"], "c": card["code"]})[0]
    folder = _drop_folder(card["code"], create=False)
    files = sorted(n for n in os.listdir(folder) if not n.startswith(".")) if os.path.isdir(folder) else []
    return {"removal": dict(counts, code=card["code"], name=card["name"], folder=folder, files=files)}


def remove_account(conn, code, q):
    """Removes the card with its register entries, the card company's lines and its statements (they go with it:
    ON DELETE CASCADE); checking and cash-ledger entries linked to its entries stay, unlinked. First, what was made on
    its downloaded lines is kept to re-attach (srm.remember_card_lines, V049). Its drop folder is moved to the drop
    folder's _removed folder (card-downloads doesn't read there), not deleted."""
    card = _card(conn, code)
    if (q.get("confirm") or "").upper() != card["code"].upper():
        raise ValueError("removing a credit card account needs confirm=%s (its code)" % card["code"])
    gone = removal(conn, code)["removal"]
    gone["rememberedLines"] = fetch(conn, "SELECT srm.remember_card_lines(%s, %s) AS n",
                                    (card["card_account_id"], str(q.get("by") or "MxAcctMGR")[:80]))[0]["n"]
    fetch(conn, "DELETE FROM srm.card_account WHERE card_account_id = %s", (card["card_account_id"],))
    # Its place in Spending Analysis's sources goes too: a card added again with this code starts connected.
    fetch(conn, "DELETE FROM srm.spending_source WHERE source = 'card' AND register = %s", (card["code"],))
    fetch(conn, "DELETE FROM srm.source_link WHERE source = 'card' AND register = %s", (card["code"],))
    conn.commit()
    folder, moved = gone["folder"], None
    if os.path.isdir(folder):
        if os.listdir(folder):
            moved = os.path.join(os.path.dirname(folder), "_removed",
                                 "%s-%s" % (card["code"].upper(), dt.datetime.now().strftime("%Y%m%d-%H%M%S")))
            os.makedirs(os.path.dirname(moved), exist_ok=True)
            os.rename(folder, moved)
        else:
            os.rmdir(folder)
    print("card account %s removed by %s: %s entries, %s lines, %s statements%s" % (
        card["code"], q.get("by") or "MxAcctMGR", gone["entries"], gone["lines"], gone["statements"],
        ", drop folder moved to " + moved if moved else ""), flush=True)
    return {"removed": dict(gone, movedTo=moved), **accounts(conn)}


# ------------------------------------------------------------------------------------------------------ card targets

# The card company's own lines aren't targets: payments come from checking, interest, fees and adjustments from the card.
OWN_KINDS = ("payment", "interest", "fee", "adjustment")


def card_targets(conn):
    """The names card entries carry without a target account (as the card company gives them), each with its entries,
    total, first and last date and kinds; `merchant` is false for the card company's own lines."""
    rows = fetch(conn, """
        SELECT t.payee_name AS name, count(*) AS entries, sum(t.amount) AS total, min(t.txn_date) AS first,
               max(t.txn_date) AS last, array_agg(DISTINCT t.kind) AS kinds
          FROM srm.card_txn t
         WHERE t.payee_id IS NULL AND coalesce(btrim(t.payee_name), '') <> '' AND t.status <> 'void'
         GROUP BY t.payee_name ORDER BY count(*) DESC, lower(t.payee_name)""")
    for r in rows:
        r["merchant"] = not set(r["kinds"]) <= set(OWN_KINDS)
    return {"targets": rows}


def add_card_targets(conn, body):
    """Makes card targets target accounts (recipients of credit card payments) and links their entries to them."""
    names = [n.strip() for n in body.get("names") or [] if isinstance(n, str) and n.strip()]
    if not names:
        raise ValueError("names lists the card targets to add")
    by = str(body.get("by") or "MxAcctMGR")[:80]
    added = linked = 0
    for name in names:
        found = fetch(conn, "SELECT payee_id FROM srm.payee WHERE lower(name) = lower(%s)", (name,))
        if found:
            pid = found[0]["payee_id"]
            fetch(conn, """UPDATE srm.payee SET funding_sources = array_append(funding_sources, 'card')
                            WHERE payee_id = %s AND NOT ('card' = ANY (funding_sources))""", (pid,))
        else:
            # Its category: the one the card company's categories of its entries mostly map to.
            category = fetch(conn, """SELECT m.category_code FROM srm.card_txn t JOIN srm.card_line l USING (card_line_id)
                                        JOIN srm.card_category m ON m.issuer_category = lower(l.category)
                                       WHERE t.payee_id IS NULL AND lower(t.payee_name) = lower(%s) AND m.category_code IS NOT NULL
                                       GROUP BY 1 ORDER BY count(*) DESC LIMIT 1""", (name,))
            pid = fetch(conn, """INSERT INTO srm.payee (name, category_code, funding_sources, updated_by)
                                 VALUES (%s, %s, '{card}', %s) RETURNING payee_id""",
                        (name[:120], category[0]["category_code"] if category else None, by))[0]["payee_id"]
            added += 1
        with conn.cursor() as cur:
            cur.execute("""UPDATE srm.card_txn SET payee_id = %s, version = version + 1, updated_by = %s, updated_at = now()
                            WHERE payee_id IS NULL AND lower(payee_name) = lower(%s)""", (pid, by, name))
            linked += cur.rowcount
    conn.commit()
    return {"added": added, "linked": linked, **card_targets(conn)}


def route(conn, method, parts, body, q):
    """The card endpoints' answer, or None when the path isn't one of them."""
    if parts == ["cards", "targets"]:
        return card_targets(conn) if method == "GET" else add_card_targets(conn, body) if method == "POST" else None
    if parts == ["cards", "accounts"] and method == "GET":
        return accounts(conn)
    if len(parts) == 3 and parts[:2] == ["cards", "accounts"] and method == "PUT":
        return save_account(conn, parts[2], body)
    if len(parts) == 3 and parts[:2] == ["cards", "accounts"] and method == "DELETE":
        return remove_account(conn, parts[2], q)
    if len(parts) == 4 and parts[:2] == ["cards", "accounts"] and parts[3] == "removal" and method == "GET":
        return removal(conn, parts[2])
    if len(parts) == 4 and parts[:2] == ["cards", "accounts"] and method in ("GET", "POST"):
        action = {("GET", "register"): register, ("POST", "transactions"): add_transaction, ("POST", "pay"): pay,
                  ("POST", "import"): import_downloads, ("POST", "statements"): import_statements}.get((method, parts[3]))
        if action is register:
            return register(conn, parts[2])
        if action:
            return action(conn, parts[2], body)
    if len(parts) == 5 and parts[:2] == ["cards", "accounts"] and parts[3] == "statements" and method == "PUT":
        return save_statement(conn, parts[2], parts[4], body)
    if len(parts) == 3 and parts[:2] == ["cards", "transactions"] and method == "PUT":
        return update_transaction(conn, int(parts[2]), body)
    if len(parts) == 4 and parts[:2] == ["cards", "transactions"] and parts[3] == "link" and method == "POST":
        return link_payment(conn, int(parts[2]), body)
    return None
