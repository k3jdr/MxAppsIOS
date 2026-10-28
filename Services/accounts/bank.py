"""Checking accounts for the accounts service: the shared check register, payees and expense accounts (V027).

    GET  /bank/accounts                          checking accounts with register, cleared and bank balances
    PUT  /bank/accounts/<code>                   create or change one {name, institution, last4, openingDate, openingBalance}
    GET  /bank/accounts/<code>/register          its entries (running balance) and the bank's lines not in it
    POST /bank/accounts/<code>/transactions      add an entry {date, kind, checkNo, payeeId|payee, expenseAccountId, memo, amount, by}
    PUT  /bank/transactions/<id>                 change one {version, …}: refused (409) when someone changed it since
    POST /bank/transactions/<id>/move            move it one line up or down in the register {direction: up | down}
    POST /bank/accounts/<code>/status            mark several entries cleared or not cleared {entries: [{id, version}],
                                                 status: cleared | open}: all or none (409 when one changed since)
    POST /bank/lines/<id>/accept                 add the bank's line to the register (its payee found by name), cleared
    POST /bank/lines/<id>/match                  match it to an entry {txnId}
    POST /bank/accounts/<code>/import            read the bank's downloads now (srm-loader POST /load/pnc-bank)
    GET  /expense-accounts                       expense accounts with their payees and this year's totals
    PUT  /expense-accounts/<id>                  create (id 0) or change one {name, kind, description}; names are unique
                                                 (ignoring case); answers with the list and the account's id
    GET  /expense-accounts/<id>/usage            what files under it: card and checking entries, target accounts,
                                                 cash-ledger lines, card categories, its spending rule
    DELETE /expense-accounts/<id>?moveTo=&by=    take one off; what files under it moves to moveTo (another of the
                                                 same kind), which is required when anything does
    PUT  /payees/<id>                            create (id 0) or change a target account {version, name, nickname, description,
                                                 status, reference (its identifier), institution, last4, expenseAccountId,
                                                 defaultAmount, nextPaymentDate, nextPaymentAmount, logonUrl, userName,
                                                 address1, address2, city, state, zipCode, phone, notes, bankNames,
                                                 fundingSources: checking and / or card} (V033)
    GET  /payees/<id>/entries?year=              the entries behind its yearTotal (year=all: its totalPaid), newest
                                                 first: register, statement name, category, Spending Analysis
                                                 category, and what an Amazon charge bought
    PUT  /payees/<id>/note                       change only its note (the register's hover text) {note}
    PUT  /payees/<id>/link                       its link (V032): {address, text, hoverText, hoverRtf, title, by}
    DELETE /payees/<id>/link                     take the link off
    GET  /payees/<id>/usage                      what still files under it: checking, card and cash-ledger entries, the
                                                 cards paid as it, the cash ledgers funded through it, its tax items
    DELETE /payees/<id>                          remove a target account nothing files under (400 while anything does:
                                                 consolidate its entries first); its link and spending rule go with it

A target account (an external account: srm.payee, V028 / V033) is offered as a target by the registers its funding
sources name — the Checking Accounts register's (checking) and the card registers' (card); one first named in a
register (typed, or a bank line accepted) is created with that register's source, and gains it when another register
names it. Its password and user keys are never sent here: MxAcctMGR keeps them in the Keychain.

A target account's link — a web page, an email address or a page in MxNoteONE, with words of its own and
formatted hover text (srm.payee_link) — comes with it wherever it is a target: each register entry's payeeLink and
each payee's link, {address, text, tip (the hover text as RTF), title}, or null.

Each entry's amount is signed: negative leaves the account (checks, debits, fees). A register entry is never
deleted: it is voided (status void) so the check number stays accounted for.

The register is listed, and its balance run, in its own order — each entry's line, as on the shared paper register
(V031): a new entry gets its line from the database (after the last line dated on or before it), and the only way
to change it is to move the entry one line up or down. No endpoint sets a line.
"""

import datetime as dt
import json
import re
import urllib.request

CODE = re.compile(r"^[A-Za-z0-9_\-]{1,40}$")
KINDS = ("check", "debit", "deposit", "transfer", "fee", "interest")
STATUSES = ("open", "cleared", "reconciled", "void")
LOADER = "http://127.0.0.1:8770/load/pnc-bank"


class Conflict(Exception):
    """An edit made from a version that has moved on (HTTP 409)."""
    def __init__(self, message, **payload):
        super().__init__(message)
        self.payload = payload


def fetch(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        if cur.description is None:
            return []
        names = [d[0] for d in cur.description]
        return [dict(zip(names, r)) for r in cur.fetchall()]


def _num(v, what):
    try:
        return round(float(v), 2)
    except (TypeError, ValueError):
        raise ValueError("%s must be a number" % what)


def _date(v, what="date"):
    try:
        return dt.date.fromisoformat(str(v)[:10])
    except ValueError:
        raise ValueError("%s must be yyyy-mm-dd" % what)


def _account_id(conn, code):
    rows = fetch(conn, "SELECT bank_account_id FROM srm.bank_account WHERE upper(code) = upper(%s)", (code,))
    if not rows:
        raise LookupError("no checking account %s" % code)
    return rows[0]["bank_account_id"]


# ------------------------------------------------------------------------------------------------------------ accounts

def accounts(conn):
    rows = fetch(conn, """
        SELECT a.code, a.name, a.institution, a.account_last4 AS last4, a.opening_date AS "openingDate",
               a.opening_balance AS "openingBalance", a.bank_balance AS "bankBalance",
               a.bank_balance_as_of AS "bankBalanceAsOf", a.closed_date AS "closedDate",
               a.opening_balance + coalesce(sum(t.amount) FILTER (WHERE t.status <> 'void'), 0) AS balance,
               a.opening_balance + coalesce(sum(t.amount) FILTER (WHERE t.status IN ('cleared', 'reconciled')), 0) AS "clearedBalance",
               count(t.*) FILTER (WHERE t.status = 'open') AS "openEntries",
               (SELECT count(*) FROM srm.bank_line b WHERE b.bank_account_id = a.bank_account_id
                   AND NOT EXISTS (SELECT 1 FROM srm.bank_txn x WHERE x.bank_line_id = b.bank_line_id)) AS "bankOnly"
          FROM srm.bank_account a LEFT JOIN srm.bank_txn t USING (bank_account_id)
         GROUP BY a.bank_account_id ORDER BY a.closed_date NULLS FIRST, a.name""")
    return {"accounts": rows}


def save_account(conn, code, body):
    if not CODE.match(code):
        raise ValueError("account code must be 1–40 letters, digits, _ or -")
    name = (body.get("name") or "").strip()
    if not name:
        raise ValueError("name is required")
    last4 = (body.get("last4") or "").strip() or None
    if last4 and not re.match(r"^[0-9]{4}$", last4):
        raise ValueError("last4 is the account number's last four digits (never the whole number)")
    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO srm.bank_account (code, name, institution, account_last4, opening_date, opening_balance, closed_date)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (code) DO UPDATE SET name = excluded.name, institution = excluded.institution,
                   account_last4 = excluded.account_last4, opening_date = excluded.opening_date,
                   opening_balance = excluded.opening_balance, closed_date = excluded.closed_date, updated_at = now()""",
                    (code.upper(), name[:120], (body.get("institution") or "PNC")[:80], last4,
                     _date(body.get("openingDate") or dt.date.today()), _num(body.get("openingBalance", 0), "openingBalance"),
                     _date(body["closedDate"]) if body.get("closedDate") else None))
    conn.commit()
    return accounts(conn)


# ------------------------------------------------------------------------------------------------------------ register

TXN_SQL = """
    SELECT t.txn_id AS id, t.txn_date AS date, t.kind, t.check_no AS "checkNo", t.payee_id AS "payeeId",
           coalesce(p.name, t.payee_name) AS payee, p.account_last4 AS "payeeLast4", p.institution AS "payeeInstitution",
           p.notes AS "payeeNote", p.nickname AS "payeeNickname", p.next_payment_date AS "payeeNextDate",
           p.next_payment_amount AS "payeeNextAmount", pl.address AS "linkAddress", pl.display_text AS "linkText", pl.hover_rtf AS "linkTip", pl.link_title AS "linkTitle",
           coalesce(t.expense_account_id, p.expense_account_id) AS "expenseAccountId",
           e.name AS "expenseAccount", t.memo, t.amount, t.status, t.bank_line_id AS "bankLineId",
           b.posted_date AS "bankDate", b.name AS "bankName", t.version, t.entered_by AS "enteredBy",
           t.created_at AS "enteredAt", t.updated_by AS "updatedBy", t.updated_at AS "updatedAt",
           t.register_seq AS line
      FROM srm.bank_txn t
      LEFT JOIN srm.payee p USING (payee_id)
      LEFT JOIN srm.payee_link pl ON pl.payee_id = t.payee_id
      LEFT JOIN srm.expense_account e ON e.expense_account_id = coalesce(t.expense_account_id, p.expense_account_id)
      LEFT JOIN srm.bank_line b ON b.bank_line_id = t.bank_line_id"""


def nest_link(row, key):
    """Puts a row's link columns (linkAddress, linkText, linkTip, linkTitle) together as row[key], or None."""
    link = {k: row.pop("link" + k.capitalize(), None) for k in ("address", "text", "tip", "title")}
    row[key] = link if link["address"] else None
    return row


def register(conn, code):
    aid = _account_id(conn, code)
    acct = [a for a in accounts(conn)["accounts"] if a["code"].upper() == code.upper()][0]
    rows = [nest_link(r, "payeeLink") for r in fetch(conn, TXN_SQL + " WHERE t.bank_account_id = %s ORDER BY t.register_seq", (aid,))]
    balance = float(acct["openingBalance"])
    for r in rows:
        if r["status"] != "void":
            balance += float(r["amount"])
        r["balance"] = round(balance, 2)
    lines = fetch(conn, """
        SELECT b.bank_line_id AS id, b.posted_date AS date, b.amount, b.trn_type AS type, b.check_no AS "checkNo",
               b.name, b.memo,
               (SELECT p.name FROM srm.payee p WHERE lower(b.name) = ANY (SELECT lower(x) FROM unnest(p.bank_names) x)
                    OR lower(p.name) = lower(b.name) LIMIT 1) AS payee
          FROM srm.bank_line b
         WHERE b.bank_account_id = %s AND NOT EXISTS (SELECT 1 FROM srm.bank_txn x WHERE x.bank_line_id = b.bank_line_id)
         ORDER BY b.posted_date, b.bank_line_id""", (aid,))
    return {"account": acct, "entries": rows, "bankOnly": lines}


def _payee(conn, body, source="checking"):
    """(payee_id, payee_name, expense_account_id default) from payeeId or a payee name (found or created). A target
    named in a register (source: checking or card) is offered by that register's target list from then on."""
    if body.get("payeeId"):
        rows = fetch(conn, "SELECT payee_id, name, expense_account_id, default_amount FROM srm.payee WHERE payee_id = %s",
                     (int(body["payeeId"]),))
        if not rows:
            raise ValueError("no payee %s" % body["payeeId"])
        return rows[0]["payee_id"], rows[0]["name"], rows[0]["expense_account_id"]
    name = (body.get("payee") or "").strip()
    if not name:
        return None, None, None
    rows = fetch(conn, "SELECT payee_id, name, expense_account_id FROM srm.payee WHERE lower(name) = lower(%s)", (name,))
    if rows:
        fetch(conn, """UPDATE srm.payee SET funding_sources = array_append(funding_sources, %s)
                        WHERE payee_id = %s AND NOT (%s = ANY (funding_sources))""", (source, rows[0]["payee_id"], source))
        return rows[0]["payee_id"], rows[0]["name"], rows[0]["expense_account_id"]
    rows = fetch(conn, """INSERT INTO srm.payee (name, expense_account_id, updated_by, funding_sources) VALUES (%s, %s, %s, %s)
                          RETURNING payee_id""", (name[:120], body.get("expenseAccountId") or None, body.get("by"), [source]))
    return rows[0]["payee_id"], name, body.get("expenseAccountId")


def _fields(conn, body, current=None):
    cur = current or {}
    kind = body.get("kind", cur.get("kind", "check"))
    if kind not in KINDS:
        raise ValueError("kind must be one of " + ", ".join(KINDS))
    amount = _num(body.get("amount", cur.get("amount")), "amount")
    if amount == 0:
        raise ValueError("amount must not be zero")
    # Checks, debits, fees and transfers out leave the account; deposits and interest come in.
    if kind in ("check", "debit", "fee"):
        amount = -abs(amount)
    elif kind in ("deposit", "interest"):
        amount = abs(amount)
    status = body.get("status", cur.get("status", "open"))
    if status not in STATUSES:
        raise ValueError("status must be one of " + ", ".join(STATUSES))
    check_no = str(body.get("checkNo", cur.get("checkNo")) or "").strip() or None
    if kind == "check" and not check_no:
        raise ValueError("a check needs its check number")
    if "payeeId" in body or "payee" in body:
        payee_id, payee_name, default_account = _payee(conn, body)
    else:
        payee_id, payee_name, default_account = cur.get("payeeId"), cur.get("payee"), None
    expense = body.get("expenseAccountId", cur.get("expenseAccountId")) or default_account
    return {"txn_date": _date(body.get("date", cur.get("date")) or dt.date.today()), "kind": kind, "check_no": check_no,
            "payee_id": payee_id, "payee_name": payee_name, "expense_account_id": expense,
            "memo": (body.get("memo", cur.get("memo")) or "").strip()[:200] or None, "amount": amount, "status": status}


def add_transaction(conn, code, body, match=True):
    aid = _account_id(conn, code)
    f = _fields(conn, body)
    if f["check_no"]:
        dup = fetch(conn, """SELECT txn_id FROM srm.bank_txn WHERE bank_account_id = %s AND check_no = %s AND status <> 'void'""",
                    (aid, f["check_no"]))
        if dup:
            raise Conflict("check %s is already in the register" % f["check_no"], txnId=dup[0]["txn_id"])
    rows = fetch(conn, """
        INSERT INTO srm.bank_txn (bank_account_id, txn_date, kind, check_no, payee_id, payee_name, expense_account_id,
                                  memo, amount, status, entered_by, updated_by)
        VALUES (%(aid)s, %(txn_date)s, %(kind)s, %(check_no)s, %(payee_id)s, %(payee_name)s, %(expense_account_id)s,
                %(memo)s, %(amount)s, %(status)s, %(by)s, %(by)s) RETURNING txn_id""",
                 dict(f, aid=aid, by=str(body.get("by") or "MxAcctMGR")[:80]))
    if match:
        fetch(conn, "SELECT srm.match_bank_lines(%s)", (aid,))
        conn.commit()
        return {"id": rows[0]["txn_id"], **register(conn, code)}
    return {"id": rows[0]["txn_id"]}


def update_transaction(conn, txn_id, body):
    rows = fetch(conn, TXN_SQL + " WHERE t.txn_id = %s FOR UPDATE OF t", (txn_id,))
    if not rows:
        raise LookupError("no register entry %s" % txn_id)
    cur = rows[0]
    if "version" not in body:
        raise ValueError("version is required: the version the edit was made from")
    if int(body["version"]) != cur["version"]:
        conn.rollback()
        raise Conflict("%s changed this entry on %s (version %d) since you opened it (version %d)"
                       % (cur["updatedBy"] or "someone", cur["updatedAt"].strftime("%Y-%m-%d at %H:%M"), cur["version"],
                          int(body["version"])), version=cur["version"])
    f = _fields(conn, body, cur)
    unmatch = f["status"] in ("open", "void") and cur["bankLineId"] is not None
    with conn.cursor() as c:
        c.execute("""UPDATE srm.bank_txn SET txn_date = %(txn_date)s, kind = %(kind)s, check_no = %(check_no)s,
                            payee_id = %(payee_id)s, payee_name = %(payee_name)s, expense_account_id = %(expense_account_id)s,
                            memo = %(memo)s, amount = %(amount)s, status = %(status)s,
                            bank_line_id = CASE WHEN %(unmatch)s THEN NULL ELSE bank_line_id END,
                            version = version + 1, updated_by = %(by)s, updated_at = now()
                      WHERE txn_id = %(id)s RETURNING bank_account_id""",
                  dict(f, id=txn_id, unmatch=unmatch, by=str(body.get("by") or "MxAcctMGR")[:80]))
        aid = c.fetchone()[0]
    code = fetch(conn, "SELECT code FROM srm.bank_account WHERE bank_account_id = %s", (aid,))[0]["code"]
    conn.commit()
    return register(conn, code)


def set_status(conn, code, body):
    """Marks the entries listed cleared, or not cleared (unmatching their bank lines), in one transaction: refused
    whole (409) when one of them changed since it was read. Void entries are left as they are; a reconciled entry
    stays reconciled when marked cleared."""
    aid = _account_id(conn, code)
    status = body.get("status")
    if status not in ("cleared", "open"):
        raise ValueError("status must be cleared or open")
    wanted = {int(e["id"]): int(e["version"]) for e in body.get("entries") or [] if "id" in e and "version" in e}
    if not wanted:
        raise ValueError("entries is a list of {id, version}")
    rows = fetch(conn, """SELECT txn_id, version, status, updated_by, updated_at FROM srm.bank_txn
                           WHERE bank_account_id = %s AND txn_id = ANY (%s) FOR UPDATE""", (aid, list(wanted)))
    if len(rows) != len(wanted):
        conn.rollback()
        raise LookupError("not every entry is in %s" % code)
    stale = [r for r in rows if r["version"] != wanted[r["txn_id"]]]
    if stale:
        conn.rollback()
        r = stale[0]
        raise Conflict("%s changed %d of these entries since you opened them (the latest on %s); nothing was marked"
                       % (r["updated_by"] or "someone", len(stale), r["updated_at"].strftime("%Y-%m-%d at %H:%M")))
    ids = [r["txn_id"] for r in rows if r["status"] != "void"
           and not (status == "cleared" and r["status"] in ("cleared", "reconciled")) and not (status == "open" and r["status"] == "open")]
    if ids:
        fetch(conn, """UPDATE srm.bank_txn SET status = %s,
                              bank_line_id = CASE WHEN %s = 'open' THEN NULL ELSE bank_line_id END,
                              version = version + 1, updated_by = %s, updated_at = now()
                        WHERE txn_id = ANY (%s)""", (status, status, str(body.get("by") or "MxAcctMGR")[:80], ids))
    conn.commit()
    return {"changed": len(ids), **register(conn, code)}


def move_transaction(conn, txn_id, body):
    """Moves an entry one line up or down in its register (swaps it with its neighbour); answers with the register.
    The first line can't move up, nor the last down: nothing changes."""
    direction = body.get("direction")
    if direction not in ("up", "down"):
        raise ValueError("direction must be up or down")
    rows = fetch(conn, """SELECT a.code FROM srm.bank_txn t JOIN srm.bank_account a USING (bank_account_id)
                           WHERE t.txn_id = %s""", (txn_id,))
    if not rows:
        raise LookupError("no register entry %s" % txn_id)
    fetch(conn, "SELECT srm.move_bank_txn(%s, %s)", (txn_id, direction == "down"))
    conn.commit()
    return register(conn, rows[0]["code"])


def _line(conn, line_id):
    rows = fetch(conn, """SELECT b.*, a.code FROM srm.bank_line b JOIN srm.bank_account a USING (bank_account_id)
                           WHERE b.bank_line_id = %s""", (line_id,))
    if not rows:
        raise LookupError("no bank line %s" % line_id)
    if fetch(conn, "SELECT 1 FROM srm.bank_txn WHERE bank_line_id = %s", (line_id,)):
        raise Conflict("that bank line is already in the register")
    return rows[0]


def accept_line(conn, line_id, body):
    """The bank's line as a register entry: its payee found by the name the bank uses (or created), cleared."""
    b = _line(conn, line_id)
    amount = float(b["amount"])
    kind = "check" if b["check_no"] else ("deposit" if amount > 0 else ("fee" if (b["trn_type"] or "").upper() in ("FEE", "SRVCHG") else "debit"))
    found = fetch(conn, """SELECT payee_id, name, expense_account_id FROM srm.payee
                            WHERE lower(%s) = ANY (SELECT lower(x) FROM unnest(bank_names) x) OR lower(name) = lower(%s)
                            LIMIT 1""", (b["name"] or "", b["name"] or ""))
    payee = body.get("payee") or (found[0]["name"] if found else (b["name"] or "").strip()[:120] or None)
    out = add_transaction(conn, b["code"], {"date": b["posted_date"].isoformat(), "kind": kind, "checkNo": b["check_no"],
                                             "payee": payee, "expenseAccountId": body.get("expenseAccountId"),
                                             "memo": b["memo"], "amount": amount, "by": body.get("by") or "MxAcctMGR"},
                          match=False)
    # The new entry is this line: matched and cleared.
    fetch(conn, "UPDATE srm.bank_txn SET bank_line_id = %s, status = 'cleared' WHERE txn_id = %s", (line_id, out["id"]))
    if payee and b["name"] and payee.lower() != b["name"].lower():
        fetch(conn, """UPDATE srm.payee SET bank_names = array_append(bank_names, %s)
                        WHERE lower(name) = lower(%s) AND NOT (%s = ANY (bank_names))""", (b["name"], payee, b["name"]))
    conn.commit()
    return register(conn, b["code"])


def match_line(conn, line_id, body):
    b = _line(conn, line_id)
    txn = fetch(conn, "SELECT bank_account_id, bank_line_id, status FROM srm.bank_txn WHERE txn_id = %s FOR UPDATE",
                (int(body.get("txnId") or 0),))
    if not txn or txn[0]["bank_account_id"] != b["bank_account_id"]:
        raise ValueError("txnId must be an entry in the same account")
    if txn[0]["bank_line_id"] or txn[0]["status"] == "void":
        raise Conflict("that entry is already matched or void")
    fetch(conn, """UPDATE srm.bank_txn SET bank_line_id = %s, status = 'cleared', version = version + 1, updated_by = %s,
                          updated_at = now() WHERE txn_id = %s""", (line_id, body.get("by") or "MxAcctMGR", int(body["txnId"])))
    conn.commit()
    return register(conn, b["code"])


def import_downloads(conn, code):
    """Runs srm.py load pnc-bank through srm-loader (so it shows in the activity log), then the register."""
    _account_id(conn, code)
    req = urllib.request.Request(LOADER, data=b"", method="POST")
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            out = json.load(r)
    except Exception as e:
        raise ValueError("srm-loader (port 8770) didn't run pnc-bank: %s" % e)
    run = (out.get("runs") or [{}])[-1]
    return {"load": {"status": run.get("status") or out.get("status"), "message": run.get("message") or out.get("error")},
            **register(conn, code)}


# ----------------------------------------------------------------------------------------------- payees and expense accounts

# What was spent (positive) or received (negative), from the check registers and the credit card registers. A card
# payment isn't spending: its charges are (V029), so the checking entry that pays a card goes in Transfers.
SPEND = """
    SELECT b.txn_date, b.payee_id, coalesce(b.expense_account_id, p.expense_account_id) AS expense_account_id,
           -b.amount AS spent
      FROM srm.bank_txn b LEFT JOIN srm.payee p USING (payee_id) WHERE b.status <> 'void'
    UNION ALL
    SELECT c.txn_date, c.payee_id, c.expense_account_id, c.amount
      FROM srm.card_txn c WHERE c.status <> 'void' AND c.kind <> 'payment'"""


def expense_accounts(conn, q=None):
    year = int((q or {}).get("year") or dt.date.today().year)
    accts = fetch(conn, """
        WITH t AS (%s)
        SELECT e.expense_account_id AS id, e.name, e.kind, e.description,
               coalesce(sum(t.spent) FILTER (WHERE extract(year FROM t.txn_date) = %%s), 0) AS "yearTotal",
               count(t.*) FILTER (WHERE extract(year FROM t.txn_date) = %%s) AS "yearEntries"
          FROM srm.expense_account e LEFT JOIN t ON t.expense_account_id = e.expense_account_id
         GROUP BY e.expense_account_id ORDER BY e.sort_order, e.name""" % SPEND, (year, year))
    payees = fetch(conn, """
        SELECT p.payee_id AS id, p.name, p.expense_account_id AS "expenseAccountId", p.default_amount AS "defaultAmount",
               p.address_1 AS "address1", p.address_2 AS "address2", p.city, p.state, p.zip_code AS "zipCode",
               p.reference, p.phone, p.logon_url AS "logonUrl", p.user_name AS "userName", p.nickname, p.description,
               p.status, p.next_payment_date AS "nextPaymentDate", p.next_payment_amount AS "nextPaymentAmount",
               p.funding_sources AS "fundingSources", p.bank_names AS "bankNames", p.notes, p.active, p.version,
               p.institution, p.account_last4 AS last4, pl.address AS "linkAddress", pl.display_text AS "linkText", pl.hover_rtf AS "linkTip", pl.link_title AS "linkTitle",
               p.updated_by AS "updatedBy", p.updated_at AS "updatedAt",
               coalesce(sum(t.spent) FILTER (WHERE extract(year FROM t.txn_date) = %%s), 0) AS "yearTotal",
               coalesce(sum(t.spent), 0) AS "totalPaid", max(t.txn_date) AS "lastPaid"
          FROM srm.payee p LEFT JOIN (%s) t USING (payee_id) LEFT JOIN srm.payee_link pl USING (payee_id)
         GROUP BY p.payee_id, pl.payee_id ORDER BY lower(p.name)""" % SPEND, (year,))
    return {"year": year, "expenseAccounts": accts, "payees": [nest_link(p, "link") for p in payees]}


def payee_entries(conn, pid, q=None):
    """The entries behind a target account's This year (yearTotal) or, with year=all, its Total paid: SPEND's checks
    and card charges with it as the target, newest first — each with its register, the statement's name, its
    category (expense account), its Spending Analysis category, and what an Amazon charge bought (V046)."""
    rows = fetch(conn, "SELECT name FROM srm.payee WHERE payee_id = %s", (int(pid),))
    if not rows:
        raise LookupError("no target account %s" % pid)
    raw = str((q or {}).get("year") or dt.date.today().year)
    year = None if raw == "all" else int(raw)
    entries = fetch(conn, """
        WITH t AS (
            SELECT 'bank'::text AS source, b.txn_id AS "entryId", b.txn_date AS date, a.code AS register, b.kind,
                   b.check_no AS "checkNo", coalesce(nullif(btrim(l.name), ''), b.payee_name) AS name, b.memo,
                   coalesce(b.expense_account_id, p.expense_account_id) AS expense_account_id, -b.amount AS amount
              FROM srm.bank_txn b JOIN srm.bank_account a USING (bank_account_id) LEFT JOIN srm.payee p USING (payee_id)
              LEFT JOIN srm.bank_line l USING (bank_line_id)
             WHERE b.payee_id = %(pid)s AND b.status <> 'void'
            UNION ALL
            SELECT 'card', c.txn_id, c.txn_date, a.code, c.kind, NULL, coalesce(nullif(btrim(l.name), ''), c.payee_name),
                   c.memo, c.expense_account_id, c.amount
              FROM srm.card_txn c JOIN srm.card_account a USING (card_account_id) LEFT JOIN srm.card_line l USING (card_line_id)
             WHERE c.payee_id = %(pid)s AND c.status <> 'void' AND c.kind <> 'payment')
        SELECT t.source, t."entryId", t.date, t.register, t.kind, t."checkNo", t.name, t.memo, t.amount,
               ea.name AS category, sc.name AS spending, ac.orders, ac.items_text AS bought
          FROM t
          LEFT JOIN srm.expense_account ea USING (expense_account_id)
          LEFT JOIN srm.v_spending_entry se ON se.source = t.source AND se.entry_id = t."entryId"
          LEFT JOIN srm.spending_category sc ON sc.code = se.category_code
          LEFT JOIN srm.v_amazon_charge ac ON ac.source = t.source AND ac.entry_id = t."entryId"
         WHERE %(year)s::int IS NULL OR extract(year FROM t.date) = %(year)s
         ORDER BY t.date DESC, t."entryId" DESC""", {"pid": int(pid), "year": year})
    return {"id": int(pid), "name": rows[0]["name"], "year": year, "entries": entries,
            "total": round(sum(float(e["amount"]) for e in entries), 2)}


def save_expense_account(conn, eid, body):
    eid = int(eid)
    name = " ".join((body.get("name") or "").split())[:80]
    if not name:
        raise ValueError("name is required")
    cur = None
    if eid:
        rows = fetch(conn, "SELECT kind, description FROM srm.expense_account WHERE expense_account_id = %s", (eid,))
        if not rows:
            raise LookupError("no expense account %s" % eid)
        cur = rows[0]
    kind = body.get("kind") or (cur["kind"] if cur else "expense")
    if kind not in ("expense", "income", "transfer"):
        raise ValueError("kind must be expense, income or transfer")
    if fetch(conn, "SELECT 1 FROM srm.expense_account WHERE lower(name) = lower(%s) AND expense_account_id <> %s", (name, eid)):
        raise ValueError("there is already an expense account named %s" % name)
    # A change keeps the description it doesn't send.
    description = (str(body["description"]).strip() or None) if "description" in body else (cur["description"] if cur else None)
    if not eid:
        eid = fetch(conn, """INSERT INTO srm.expense_account (name, kind, description, sort_order)
                             VALUES (%s, %s, %s, coalesce((SELECT max(sort_order) FROM srm.expense_account WHERE kind = %s), 100) + 1)
                             RETURNING expense_account_id""", (name, kind, description, kind))[0]["expense_account_id"]
    else:
        fetch(conn, "UPDATE srm.expense_account SET name = %s, kind = %s, description = %s WHERE expense_account_id = %s",
              (name, kind, description, eid))
    conn.commit()
    return dict(expense_accounts(conn), id=eid)


# What files under an expense account, and how to move it elsewhere: (what, count query, move statement).
EXPENSE_USES = (
    ("card entries", "SELECT count(*) FROM srm.card_txn WHERE expense_account_id = %s",
     "UPDATE srm.card_txn SET expense_account_id = %s, version = version + 1, updated_by = %s, updated_at = now() WHERE expense_account_id = %s"),
    ("checking entries", "SELECT count(*) FROM srm.bank_txn WHERE expense_account_id = %s",
     "UPDATE srm.bank_txn SET expense_account_id = %s, version = version + 1, updated_by = %s, updated_at = now() WHERE expense_account_id = %s"),
    ("target accounts", "SELECT count(*) FROM srm.payee WHERE expense_account_id = %s",
     "UPDATE srm.payee SET expense_account_id = %s, version = version + 1, updated_by = %s, updated_at = now() WHERE expense_account_id = %s"),
    ("cash-ledger lines", "SELECT count(*) FROM srm.expense_line WHERE expense_account_id = %s",
     "UPDATE srm.expense_line SET expense_account_id = %s WHERE expense_account_id = %s"),
    ("card categories", "SELECT count(*) FROM srm.card_category WHERE expense_account_id = %s",
     "UPDATE srm.card_category SET expense_account_id = %s WHERE expense_account_id = %s"),
)


def expense_account_usage(conn, eid):
    rows = fetch(conn, "SELECT name, kind FROM srm.expense_account WHERE expense_account_id = %s", (int(eid),))
    if not rows:
        raise LookupError("no expense account %s" % eid)
    uses = {what: fetch(conn, count, (int(eid),))[0]["count"] for what, count, _ in EXPENSE_USES}
    rule = fetch(conn, "SELECT 1 FROM srm.spending_rule WHERE expense_account_id = %s", (int(eid),))
    return {"id": int(eid), "name": rows[0]["name"], "kind": rows[0]["kind"], "uses": uses, "inUse": sum(uses.values()),
            "spendingRule": bool(rule)}


def delete_expense_account(conn, eid, q):
    """Takes an expense account off. What files under it — card and checking entries, target accounts, cash-ledger
    lines, the card categories mapped to it — moves to moveTo first (required when anything does); its spending rule
    goes with it (moveTo keeps its own)."""
    usage = expense_account_usage(conn, eid)
    move_to = int(q.get("moveTo") or 0)
    by = str(q.get("by") or "MxAcctMGR")[:80]
    if usage["inUse"]:
        if not move_to:
            one = {"card entries": "card entry", "checking entries": "checking entry", "target accounts": "target account",
                   "cash-ledger lines": "cash-ledger line", "card categories": "card category"}
            raise ValueError("%s is in use (%s): choose an expense account to move it to" % (
                usage["name"], ", ".join("%d %s" % (n, one[w] if n == 1 else w) for w, n in usage["uses"].items() if n)))
        target = fetch(conn, "SELECT kind FROM srm.expense_account WHERE expense_account_id = %s", (move_to,))
        if not target or move_to == int(eid):
            raise ValueError("moveTo must be another expense account")
        if target[0]["kind"] != usage["kind"]:
            raise ValueError("moveTo must be an %s account, as %s is" % (usage["kind"], usage["name"]))
        for what, _, move in EXPENSE_USES:
            params = (move_to, by, int(eid)) if "updated_by" in move else (move_to, int(eid))
            fetch(conn, move, params)
    fetch(conn, "DELETE FROM srm.expense_account WHERE expense_account_id = %s", (int(eid),))
    conn.commit()
    return expense_accounts(conn)


PAYEE_STATUSES = ("active", "inactive", "closed")
FUNDING_SOURCES = ("checking", "card")
# The target account's columns as save_payee writes them, in order.
PAYEE_COLUMNS = ("name", "nickname", "description", "status", "active", "reference", "institution", "account_last4",
                 "expense_account_id", "default_amount", "next_payment_date", "next_payment_amount", "logon_url",
                 "user_name", "address_1", "address_2", "city", "state", "zip_code", "phone", "notes", "bank_names",
                 "funding_sources", "updated_by")


def save_payee(conn, pid, body):
    """A target account, created (id 0) or changed from the version it was read at. A change keeps the saved value of
    each field it doesn't send (an older MxAcctMGR sends fewer, and names three of them address, website and active:
    read as address1, logonUrl and status)."""
    name = (body.get("name") or "").strip()
    if not name:
        raise ValueError("name is required")
    cur = {}
    if int(pid) != 0:
        rows = fetch(conn, "SELECT * FROM srm.payee WHERE payee_id = %s FOR UPDATE", (int(pid),))
        if not rows:
            raise LookupError("no target account %s" % pid)
        cur = rows[0]
        if int(body.get("version", -1)) != cur["version"]:
            conn.rollback()
            raise Conflict("%s changed this target account since you opened it" % (cur["updated_by"] or "someone"),
                           version=cur["version"])
        # Names are unique whatever their case (srm.payee's index on lower(name)): say so rather than fail on the index.
        if fetch(conn, "SELECT 1 FROM srm.payee WHERE lower(name) = lower(%s) AND payee_id <> %s", (name, int(pid))):
            conn.rollback()
            raise Conflict("there is already a target account named %s" % name, version=cur["version"])

    def given(*keys):
        return next((k for k in keys if k in body), None)

    def text(column, n, *keys):
        k = given(*keys)
        return cur.get(column) if k is None else (str(body[k] or "")).strip()[:n] or None

    def amount(column, key):
        return cur.get(column) if key not in body else (_num(body[key], key) if body[key] not in (None, "") else None)

    last4 = text("account_last4", 4, "last4")
    if last4 and not re.match(r"^[0-9A-Za-z]{4}$", last4):
        raise ValueError("last4 is the target account's last four characters (never the whole number)")
    k = given("status", "active")
    status = cur.get("status", "active") if k is None else (body["status"] if k == "status" else ("active" if body["active"] else "inactive"))
    if status not in PAYEE_STATUSES:
        raise ValueError("status must be one of " + ", ".join(PAYEE_STATUSES))
    sources = body["fundingSources"] if "fundingSources" in body else cur.get("funding_sources", list(FUNDING_SOURCES))
    if not isinstance(sources, list) or any(x not in FUNDING_SOURCES for x in sources):
        raise ValueError("fundingSources lists checking and / or card")
    k = given("nextPaymentDate")
    values = dict(
        name=name[:120], nickname=text("nickname", 80, "nickname"), description=text("description", 2000, "description"),
        status=status, active=status == "active", reference=text("reference", 120, "reference"),
        institution=text("institution", 120, "institution"), account_last4=last4,
        expense_account_id=(body.get("expenseAccountId") or None) if "expenseAccountId" in body else cur.get("expense_account_id"),
        default_amount=amount("default_amount", "defaultAmount"),
        next_payment_date=cur.get("next_payment_date") if k is None else (_date(body[k]) if body[k] else None),
        next_payment_amount=amount("next_payment_amount", "nextPaymentAmount"),
        logon_url=text("logon_url", 500, "logonUrl", "website"), user_name=text("user_name", 200, "userName"),
        address_1=text("address_1", 200, "address1", "address"), address_2=text("address_2", 200, "address2"),
        city=text("city", 100, "city"), state=text("state", 60, "state"), zip_code=text("zip_code", 20, "zipCode"),
        phone=text("phone", 60, "phone"), notes=text("notes", 2000, "notes"),
        bank_names=[n for n in body["bankNames"] if isinstance(n, str) and n.strip()] if isinstance(body.get("bankNames"), list)
                   else cur.get("bank_names", []),
        funding_sources=[x for x in FUNDING_SOURCES if x in sources], updated_by=str(body.get("by") or "MxAcctMGR")[:80])
    row = tuple(values[c] for c in PAYEE_COLUMNS)
    if int(pid) == 0:
        if fetch(conn, "SELECT 1 FROM srm.payee WHERE lower(name) = lower(%s)", (name,)):
            raise Conflict("there is already a target account %s" % name)
        fetch(conn, "INSERT INTO srm.payee (%s) VALUES (%s)" % (", ".join(PAYEE_COLUMNS), ", ".join(["%s"] * len(PAYEE_COLUMNS))), row)
    else:
        fetch(conn, "UPDATE srm.payee SET %s, version = version + 1, updated_at = now() WHERE payee_id = %%s"
              % ", ".join("%s = %%s" % c for c in PAYEE_COLUMNS), row + (int(pid),))
    conn.commit()
    return expense_accounts(conn)


def save_payee_note(conn, pid, body):
    """Only the external account's note (the register's hover text, edited in place); answers with the payee."""
    rows = fetch(conn, """UPDATE srm.payee SET notes = %s, version = version + 1, updated_by = %s, updated_at = now()
                           WHERE payee_id = %s RETURNING payee_id, notes, version""",
                 ((body.get("note") or "").strip()[:2000] or None, str(body.get("by") or "MxAcctMGR")[:80], int(pid)))
    if not rows:
        raise LookupError("no payee %s" % pid)
    conn.commit()
    return {"id": rows[0]["payee_id"], "note": rows[0]["notes"], "version": rows[0]["version"]}


def save_payee_link(conn, pid, body):
    """The external account's link (srm.payee_link, V032), made or changed; answers with it."""
    address = (body.get("address") or "").strip()
    if not address:
        raise ValueError("the link needs an address")
    blank = lambda k, n: (body.get(k) or "").strip()[:n] or None
    rows = fetch(conn, """
        INSERT INTO srm.payee_link (payee_id, address, display_text, hover_text, hover_rtf, link_title, updated_at, updated_by)
        SELECT payee_id, %s, %s, %s, %s, %s, now(), %s FROM srm.payee WHERE payee_id = %s
        ON CONFLICT (payee_id) DO UPDATE SET address = excluded.address, display_text = excluded.display_text,
            hover_text = excluded.hover_text, hover_rtf = excluded.hover_rtf, link_title = excluded.link_title,
            updated_at = now(), updated_by = excluded.updated_by
        RETURNING payee_id AS id, address AS "linkAddress", display_text AS "linkText", hover_rtf AS "linkTip",
                  link_title AS "linkTitle"
        """,
                 (address[:2000], blank("text", 200), blank("hoverText", 4000), body.get("hoverRtf") or None,
                  blank("title", 300), str(body.get("by") or "MxAcctMGR")[:80], int(pid)))
    if not rows:
        raise LookupError("no payee %s" % pid)
    conn.commit()
    return nest_link(rows[0], "link")


def delete_payee_link(conn, pid):
    fetch(conn, "DELETE FROM srm.payee_link WHERE payee_id = %s", (int(pid),))
    conn.commit()
    return {"id": int(pid), "link": None}


# What still files under a target account, so it can't be removed: (what, one of them, count query).
PAYEE_USES = (
    ("checking entries", "checking entry", "SELECT count(*) FROM srm.bank_txn WHERE payee_id = %s"),
    ("card entries", "card entry", "SELECT count(*) FROM srm.card_txn WHERE payee_id = %s"),
    ("cash-ledger entries", "cash-ledger entry", "SELECT count(*) FROM srm.expense_entry WHERE payee_id = %s"),
    ("card accounts paid as it", "card account paid as it", "SELECT count(*) FROM srm.card_account WHERE payee_id = %s"),
    ("cash ledgers funded through it", "cash ledger funded through it",
     "SELECT count(*) FROM srm.expense_ledger WHERE %s = ANY (funding_payees)"),
    ("tax items", "tax item", "SELECT count(*) FROM srm.tax_item WHERE payee_id = %s"),
)


def payee_usage(conn, pid):
    """What still files under a target account (counts by kind), and whether it has a spending rule or a link."""
    rows = fetch(conn, "SELECT name FROM srm.payee WHERE payee_id = %s", (int(pid),))
    if not rows:
        raise LookupError("no target account %s" % pid)
    uses = {what: fetch(conn, count, (int(pid),))[0]["count"] for what, _, count in PAYEE_USES}
    rule = fetch(conn, "SELECT 1 FROM srm.spending_rule WHERE payee_id = %s", (int(pid),))
    link = fetch(conn, "SELECT 1 FROM srm.payee_link WHERE payee_id = %s", (int(pid),))
    return {"id": int(pid), "name": rows[0]["name"], "uses": uses, "inUse": sum(uses.values()),
            "spendingRule": bool(rule), "link": bool(link)}


def delete_payee(conn, pid):
    """Removes a target account nothing files under any more (its entries consolidated into another). Refused while
    a checking, card or cash-ledger entry, a card account, a cash ledger's funding or a tax item still names it:
    those would lose their target silently (ON DELETE SET NULL). Its link and spending rule go with it (CASCADE);
    MxAcctMGR takes its password and user keys out of the Keychain."""
    usage = payee_usage(conn, pid)
    if usage["inUse"]:
        one = {what: single for what, single, _ in PAYEE_USES}
        raise ValueError("%s is still in use (%s): consolidate them into another target account first" % (
            usage["name"], ", ".join("%d %s" % (n, one[w] if n == 1 else w) for w, n in usage["uses"].items() if n)))
    fetch(conn, "DELETE FROM srm.payee WHERE payee_id = %s", (int(pid),))
    conn.commit()
    return expense_accounts(conn)


def route(conn, method, parts, body, q):
    """The bank endpoints' answer, or None when the path isn't one of them."""
    if parts == ["bank", "accounts"] and method == "GET":
        return accounts(conn)
    if len(parts) == 3 and parts[:2] == ["bank", "accounts"] and method == "PUT":
        return save_account(conn, parts[2], body)
    if len(parts) == 4 and parts[:2] == ["bank", "accounts"] and parts[3] == "register" and method == "GET":
        return register(conn, parts[2])
    if len(parts) == 4 and parts[:2] == ["bank", "accounts"] and parts[3] == "transactions" and method == "POST":
        return add_transaction(conn, parts[2], body)
    if len(parts) == 4 and parts[:2] == ["bank", "accounts"] and parts[3] == "status" and method == "POST":
        return set_status(conn, parts[2], body)
    if len(parts) == 4 and parts[:2] == ["bank", "accounts"] and parts[3] == "import" and method == "POST":
        return import_downloads(conn, parts[2])
    if len(parts) == 3 and parts[:2] == ["bank", "transactions"] and method == "PUT":
        return update_transaction(conn, int(parts[2]), body)
    if len(parts) == 4 and parts[:2] == ["bank", "transactions"] and parts[3] == "move" and method == "POST":
        return move_transaction(conn, int(parts[2]), body)
    if len(parts) == 4 and parts[:2] == ["bank", "lines"] and parts[3] in ("accept", "match") and method == "POST":
        return (accept_line if parts[3] == "accept" else match_line)(conn, int(parts[2]), body)
    if parts == ["expense-accounts"] and method == "GET":
        return expense_accounts(conn, q)
    if len(parts) == 2 and parts[0] == "expense-accounts" and method == "PUT":
        return save_expense_account(conn, parts[1], body)
    if len(parts) == 2 and parts[0] == "expense-accounts" and method == "DELETE":
        return delete_expense_account(conn, parts[1], q)
    if len(parts) == 3 and parts[0] == "expense-accounts" and parts[2] == "usage" and method == "GET":
        return expense_account_usage(conn, parts[1])
    if len(parts) == 3 and parts[0] == "payees" and parts[2] == "entries" and method == "GET":
        return payee_entries(conn, parts[1], q)
    if len(parts) == 3 and parts[0] == "payees" and parts[2] == "note" and method == "PUT":
        return save_payee_note(conn, parts[1], body)
    if len(parts) == 3 and parts[0] == "payees" and parts[2] == "link" and method == "PUT":
        return save_payee_link(conn, parts[1], body)
    if len(parts) == 3 and parts[0] == "payees" and parts[2] == "link" and method == "DELETE":
        return delete_payee_link(conn, parts[1])
    if len(parts) == 3 and parts[0] == "payees" and parts[2] == "usage" and method == "GET":
        return payee_usage(conn, parts[1])
    if len(parts) == 2 and parts[0] == "payees" and method == "DELETE":
        return delete_payee(conn, parts[1])
    if len(parts) == 2 and parts[0] == "payees" and method == "PUT":
        return save_payee(conn, parts[1], body)
    return None
