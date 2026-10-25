"""Checking accounts for the accounts service: the shared check register, payees and expense accounts (V027).

    GET  /bank/accounts                          checking accounts with register, cleared and bank balances
    PUT  /bank/accounts/<code>                   create or change one {name, institution, last4, openingDate, openingBalance}
    GET  /bank/accounts/<code>/register          its entries (running balance) and the bank's lines not in it
    POST /bank/accounts/<code>/transactions      add an entry {date, kind, checkNo, payeeId|payee, expenseAccountId, memo, amount, by}
    PUT  /bank/transactions/<id>                 change one {version, …}: refused (409) when someone changed it since
    POST /bank/transactions/<id>/move            move it one line up or down in the register {direction: up | down}
    POST /bank/lines/<id>/accept                 add the bank's line to the register (its payee found by name), cleared
    POST /bank/lines/<id>/match                  match it to an entry {txnId}
    POST /bank/accounts/<code>/import            read the bank's downloads now (srm-loader POST /load/pnc-bank)
    GET  /expense-accounts                       expense accounts with their payees and this year's totals
    PUT  /expense-accounts/<id>                  create (id 0) or change one {name, kind, description}
    PUT  /payees/<id>                            create (id 0) or change an external account {version, name, institution, last4, …}
    PUT  /payees/<id>/note                       change only its note (the register's hover text) {note}

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
           p.notes AS "payeeNote",
           coalesce(t.expense_account_id, p.expense_account_id) AS "expenseAccountId",
           e.name AS "expenseAccount", t.memo, t.amount, t.status, t.bank_line_id AS "bankLineId",
           b.posted_date AS "bankDate", b.name AS "bankName", t.version, t.entered_by AS "enteredBy",
           t.created_at AS "enteredAt", t.updated_by AS "updatedBy", t.updated_at AS "updatedAt",
           t.register_seq AS line
      FROM srm.bank_txn t
      LEFT JOIN srm.payee p USING (payee_id)
      LEFT JOIN srm.expense_account e ON e.expense_account_id = coalesce(t.expense_account_id, p.expense_account_id)
      LEFT JOIN srm.bank_line b ON b.bank_line_id = t.bank_line_id"""


def register(conn, code):
    aid = _account_id(conn, code)
    acct = [a for a in accounts(conn)["accounts"] if a["code"].upper() == code.upper()][0]
    rows = fetch(conn, TXN_SQL + " WHERE t.bank_account_id = %s ORDER BY t.register_seq", (aid,))
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


def _payee(conn, body):
    """(payee_id, payee_name, expense_account_id default) from payeeId or a payee name (found or created)."""
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
        return rows[0]["payee_id"], rows[0]["name"], rows[0]["expense_account_id"]
    rows = fetch(conn, """INSERT INTO srm.payee (name, expense_account_id, updated_by) VALUES (%s, %s, %s)
                          RETURNING payee_id""", (name[:120], body.get("expenseAccountId") or None, body.get("by")))
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
                 dict(f, aid=aid, by=str(body.get("by") or "MxPortMGR")[:80]))
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
                  dict(f, id=txn_id, unmatch=unmatch, by=str(body.get("by") or "MxPortMGR")[:80]))
        aid = c.fetchone()[0]
    code = fetch(conn, "SELECT code FROM srm.bank_account WHERE bank_account_id = %s", (aid,))[0]["code"]
    conn.commit()
    return register(conn, code)


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
                                             "memo": b["memo"], "amount": amount, "by": body.get("by") or "MxPortMGR"},
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
                          updated_at = now() WHERE txn_id = %s""", (line_id, body.get("by") or "MxPortMGR", int(body["txnId"])))
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
               p.address, p.reference, p.phone, p.website, p.bank_names AS "bankNames", p.notes, p.active, p.version,
               p.institution, p.account_last4 AS last4,
               p.updated_by AS "updatedBy", p.updated_at AS "updatedAt",
               coalesce(sum(t.spent) FILTER (WHERE extract(year FROM t.txn_date) = %%s), 0) AS "yearTotal",
               max(t.txn_date) AS "lastPaid"
          FROM srm.payee p LEFT JOIN (%s) t USING (payee_id)
         GROUP BY p.payee_id ORDER BY lower(p.name)""" % SPEND, (year,))
    return {"year": year, "expenseAccounts": accts, "payees": payees}


def save_expense_account(conn, eid, body):
    name = (body.get("name") or "").strip()
    if not name:
        raise ValueError("name is required")
    kind = body.get("kind") or "expense"
    if kind not in ("expense", "income", "transfer"):
        raise ValueError("kind must be expense, income or transfer")
    if int(eid) == 0:
        fetch(conn, """INSERT INTO srm.expense_account (name, kind, description, sort_order)
                       VALUES (%s, %s, %s, coalesce((SELECT max(sort_order) FROM srm.expense_account WHERE kind = %s), 100) + 1)""",
              (name[:80], kind, body.get("description"), kind))
    else:
        fetch(conn, "UPDATE srm.expense_account SET name = %s, kind = %s, description = %s WHERE expense_account_id = %s",
              (name[:80], kind, body.get("description"), int(eid)))
    conn.commit()
    return expense_accounts(conn)


def save_payee(conn, pid, body):
    name = (body.get("name") or "").strip()
    if not name:
        raise ValueError("name is required")
    last4 = (body.get("last4") or "").strip() or None
    if last4 and not re.match(r"^[0-9A-Za-z]{4}$", last4):
        raise ValueError("last4 is the external account's last four characters (never the whole number)")
    values = (name[:120], body.get("expenseAccountId") or None,
              _num(body["defaultAmount"], "defaultAmount") if body.get("defaultAmount") not in (None, "") else None,
              body.get("address"), body.get("reference"), body.get("phone"), body.get("website"),
              [n for n in (body.get("bankNames") or []) if isinstance(n, str) and n.strip()], body.get("notes"),
              bool(body.get("active", True)), (body.get("institution") or "").strip()[:120] or None, last4,
              str(body.get("by") or "MxPortMGR")[:80])
    if int(pid) == 0:
        if fetch(conn, "SELECT 1 FROM srm.payee WHERE lower(name) = lower(%s)", (name,)):
            raise Conflict("there is already a payee %s" % name)
        fetch(conn, """INSERT INTO srm.payee (name, expense_account_id, default_amount, address, reference, phone, website,
                                              bank_names, notes, active, institution, account_last4, updated_by)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""", values)
    else:
        cur = fetch(conn, "SELECT version, updated_by, updated_at FROM srm.payee WHERE payee_id = %s FOR UPDATE", (int(pid),))
        if not cur:
            raise LookupError("no payee %s" % pid)
        if int(body.get("version", -1)) != cur[0]["version"]:
            conn.rollback()
            raise Conflict("%s changed this payee since you opened it" % (cur[0]["updated_by"] or "someone"),
                           version=cur[0]["version"])
        fetch(conn, """UPDATE srm.payee SET name = %s, expense_account_id = %s, default_amount = %s, address = %s,
                              reference = %s, phone = %s, website = %s, bank_names = %s, notes = %s, active = %s,
                              institution = %s, account_last4 = %s, updated_by = %s, version = version + 1, updated_at = now() WHERE payee_id = %s""",
              values + (int(pid),))
    conn.commit()
    return expense_accounts(conn)


def save_payee_note(conn, pid, body):
    """Only the external account's note (the register's hover text, edited in place); answers with the payee."""
    rows = fetch(conn, """UPDATE srm.payee SET notes = %s, version = version + 1, updated_by = %s, updated_at = now()
                           WHERE payee_id = %s RETURNING payee_id, notes, version""",
                 ((body.get("note") or "").strip()[:2000] or None, str(body.get("by") or "MxPortMGR")[:80], int(pid)))
    if not rows:
        raise LookupError("no payee %s" % pid)
    conn.commit()
    return {"id": rows[0]["payee_id"], "note": rows[0]["notes"], "version": rows[0]["version"]}


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
    if len(parts) == 3 and parts[0] == "payees" and parts[2] == "note" and method == "PUT":
        return save_payee_note(conn, parts[1], body)
    if len(parts) == 2 and parts[0] == "payees" and method == "PUT":
        return save_payee(conn, parts[1], body)
    return None
