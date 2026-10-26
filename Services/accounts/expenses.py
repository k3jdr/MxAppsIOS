"""Expense ledgers for the accounts service (MxAcctMGR's Banking ▸ Expense Ledgers): funded ledgers of purpose
spending, with their budget lines, subscriptions, equipment, training and trips (V030).

    GET  /expense-ledgers                           the expense ledgers with spent, funded and balance
    PUT  /expense-ledgers/<code>                    create or change one {name, purpose, owner, costCenter, openingDate,
                                                    openingBalance, budget, fundingPayees, fundingAmount, fundingDay, closedDate}
    GET  /expense-ledgers/<code>                    its book: lines (budget against actual), entries (running balance),
                                                    subscriptions, assets (depreciation), training, trips and alerts
    POST /expense-ledgers/<code>/entries            add an entry {date, kind, description, vendor, lineId, tripId, amount,
                                                    recurrence, status, approval, url, notes, cardTxnId, bankTxnId, by}
    PUT  /expense-entries/<id>                      change one {version, …}: refused (409) when someone changed it since
    POST /expense-entries/<id>/approve              {approval: pending | approved | rejected}
    POST /expense-entries/<id>/renew                a subscription's next charge (a month or a year on)
    POST /expense-entries/<id>/link                 link an entry to the card charge or check that paid it {version,
                                                    source: card | bank, txnId, by}: the purchase then counts once
    POST /expense-ledgers/<code>/entries/delete     delete entries for good {entries: [{id, version}], by}: all or none,
                                                    refused (409) when someone changed one since
    POST /expense-ledgers/<code>/fund               funding transfers {date, amount, payeeId, months, description}:
                                                    one a month from the date, those after today scheduled
    PUT  /expense-ledgers/<code>/lines/<id>         a budget line (id 0 adds one)
    PUT  /expense-ledgers/<code>/assets/<id>        an asset (id 0 adds one)
    PUT  /expense-ledgers/<code>/training/<id>      a training record (id 0 adds one)
    PUT  /expense-ledgers/<code>/trips/<id>         a trip (id 0 adds one)
    GET  /expense-ledgers/<code>/card-charges       recent card charges in no expense ledger, to add from

Amounts are signed as the balance reads them: positive is spent and not funded yet, negative lowers it (funding,
refunds). An entry is voided to take it out of the balance and keep it; deleting one (the user's choice) removes it
for good: a card charge or check it was linked to stays in its register, its spending tag goes with it (V037), assets
and training keep no entry, and a move of it in Year-End Tax (srm.tax_assignment, V040) is taken off.
"""

import calendar
import datetime as dt
import re

from bank import Conflict, fetch, _date, _num

CODE = re.compile(r"^[A-Za-z0-9_\-]{1,40}$")
KINDS = ("expense", "refund", "funding", "adjustment")
LINE_KINDS = ("equipment", "software", "facilities", "training", "travel", "subscriptions", "other")


def _by(body):
    return str(body.get("by") or "MxAcctMGR")[:80]


def _ledger(conn, code):
    rows = fetch(conn, "SELECT * FROM srm.expense_ledger WHERE upper(code) = upper(%s)", (code,))
    if not rows:
        raise LookupError("no expense ledger %s" % code)
    return rows[0]


def _opt_num(body, key):
    return _num(body[key], key) if body.get(key) not in (None, "") else None


def _opt_date(body, key):
    return _date(body[key], key) if body.get(key) else None


def _text(body, key, n=200):
    return (str(body.get(key) or "")).strip()[:n] or None


def _add_months(d, n):
    m = d.year * 12 + d.month - 1 + n
    y, m = m // 12, m % 12 + 1
    return dt.date(y, m, min(d.day, calendar.monthrange(y, m)[1]))


def _months_between(a, b):
    """Whole months from a to b (0 when b is before a month after a)."""
    n = (b.year - a.year) * 12 + b.month - a.month - (1 if b.day < a.day else 0)
    return max(0, n)


# ------------------------------------------------------------------------------------------------------------ ledgers

def ledgers(conn):
    rows = fetch(conn, """
        SELECT l.code, l.name, l.purpose, l.owner, l.cost_center AS "costCenter", l.opening_date AS "openingDate",
               l.opening_balance AS "openingBalance", l.budget, l.funding_payees AS "fundingPayees",
               l.funding_amount AS "fundingAmount", l.funding_day AS "fundingDay", l.closed_date AS "closedDate",
               l.version,
               coalesce(sum(e.amount) FILTER (WHERE e.status = 'actual' AND e.kind IN ('expense', 'refund', 'adjustment')), 0) AS spent,
               coalesce(-sum(e.amount) FILTER (WHERE e.status = 'actual' AND e.kind = 'funding'), 0) AS funded,
               coalesce(-sum(e.amount) FILTER (WHERE e.status = 'scheduled' AND e.kind = 'funding'), 0) AS scheduled,
               l.opening_balance + coalesce(sum(e.amount) FILTER (WHERE e.status = 'actual'), 0) AS balance,
               l.opening_balance + coalesce(sum(e.amount) FILTER (WHERE e.status <> 'void'), 0) AS projected,
               count(e.*) FILTER (WHERE e.approval = 'pending' AND e.status <> 'void') AS "pendingApproval"
          FROM srm.expense_ledger l LEFT JOIN srm.expense_entry e USING (ledger_id)
         GROUP BY l.ledger_id ORDER BY l.closed_date NULLS FIRST, l.name""")
    return {"ledgers": rows}


def save_ledger(conn, code, body):
    if not CODE.match(code):
        raise ValueError("code must be 1–40 letters, digits, _ or -")
    name = _text(body, "name", 120)
    if not name:
        raise ValueError("name is required")
    payees = [int(p) for p in (body.get("fundingPayees") or []) if str(p).isdigit()]
    day = body.get("fundingDay")
    if day not in (None, "") and not (str(day).isdigit() and 1 <= int(day) <= 31):
        raise ValueError("fundingDay must be a day of the month (1–31)")
    cur = fetch(conn, "SELECT ledger_id, version FROM srm.expense_ledger WHERE upper(code) = upper(%s) FOR UPDATE", (code,))
    if cur and "version" in body and int(body["version"]) != cur[0]["version"]:
        conn.rollback()
        raise Conflict("someone changed this expense ledger since you opened it", version=cur[0]["version"])
    rows = fetch(conn, """
        INSERT INTO srm.expense_ledger (code, name, purpose, owner, cost_center, opening_date, opening_balance, budget,
                                        funding_payees, funding_amount, funding_day, closed_date, updated_by)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (code) DO UPDATE SET name = excluded.name, purpose = excluded.purpose, owner = excluded.owner,
               cost_center = excluded.cost_center, opening_date = excluded.opening_date,
               opening_balance = excluded.opening_balance, budget = excluded.budget,
               funding_payees = excluded.funding_payees, funding_amount = excluded.funding_amount,
               funding_day = excluded.funding_day, closed_date = excluded.closed_date, updated_by = excluded.updated_by,
               version = srm.expense_ledger.version + 1, updated_at = now()
        RETURNING ledger_id""",
                 (code.upper(), name, _text(body, "purpose", 500), _text(body, "owner", 80) or "Personal",
                  _text(body, "costCenter", 80), _date(body.get("openingDate") or dt.date.today()),
                  _num(body.get("openingBalance") or 0, "openingBalance"), _opt_num(body, "budget"), payees,
                  _opt_num(body, "fundingAmount"), int(day) if day not in (None, "") else None,
                  _opt_date(body, "closedDate"), _by(body)))
    fetch(conn, "SELECT srm.match_expense_funding(%s)", (rows[0]["ledger_id"],))
    conn.commit()
    return ledgers(conn)


# ------------------------------------------------------------------------------------------------------------ the book

ENTRY_SQL = """
    SELECT e.entry_id AS id, e.entry_date AS date, e.kind, e.description, e.vendor, e.line_id AS "lineId",
           ln.name AS line, ln.color AS "lineColor", e.trip_id AS "tripId", tr.name AS trip, e.payee_id AS "payeeId",
           p.name AS payee, e.amount, e.recurrence, e.status, e.approval, e.approved_by AS "approvedBy",
           e.approved_at AS "approvedAt", e.url, e.notes, e.card_txn_id AS "cardTxnId", ca.code AS "cardAccount",
           e.bank_txn_id AS "bankTxnId", ba.code AS "bankAccount", bt.txn_date AS "bankDate", e.version,
           e.entered_by AS "enteredBy", e.updated_by AS "updatedBy", e.updated_at AS "updatedAt"
      FROM srm.expense_entry e
      LEFT JOIN srm.expense_line ln ON ln.line_id = e.line_id
      LEFT JOIN srm.expense_trip tr ON tr.trip_id = e.trip_id
      LEFT JOIN srm.payee p ON p.payee_id = e.payee_id
      LEFT JOIN srm.card_txn ct ON ct.txn_id = e.card_txn_id
      LEFT JOIN srm.card_account ca ON ca.card_account_id = ct.card_account_id
      LEFT JOIN srm.bank_txn bt ON bt.txn_id = e.bank_txn_id
      LEFT JOIN srm.bank_account ba ON ba.bank_account_id = bt.bank_account_id"""


def _depreciation(a, today):
    """Monthly depreciation, accumulated to today (or disposal) and book value of an asset."""
    cost, salvage, life = float(a["cost"]), float(a["salvage"] or 0), a["useful_life_months"]
    if not a["in_service"] or not life:
        return {"monthly": None, "accumulated": 0.0, "bookValue": cost, "monthsInService": 0, "fullyDepreciated": False}
    end = a["disposed_date"] if a["disposed_date"] and a["disposed_date"] < today else today
    months = min(_months_between(a["in_service"], end) + (1 if end >= a["in_service"] else 0), life)
    if a["method"] == "straight-line":
        monthly = (cost - salvage) / life
        accumulated = monthly * months
    else:   # double declining balance, by month, never below salvage
        rate, book = 2.0 / life, cost
        for _ in range(months):
            book -= max(0.0, min(book * rate, book - salvage))
        accumulated, monthly = cost - book, max(0.0, min(book * rate, book - salvage))
    accumulated = min(accumulated, cost - salvage)
    return {"monthly": round(monthly, 2), "accumulated": round(accumulated, 2), "bookValue": round(cost - accumulated, 2),
            "monthsInService": months, "fullyDepreciated": accumulated >= cost - salvage - 0.005}


def book(conn, code):
    led = _ledger(conn, code)
    lid = led["ledger_id"]
    summary = [x for x in ledgers(conn)["ledgers"] if x["code"] == led["code"]][0]
    today = dt.date.today()
    entries = fetch(conn, ENTRY_SQL + " WHERE e.ledger_id = %s ORDER BY e.entry_date, e.entry_id", (lid,))
    balance = float(led["opening_balance"])
    for e in entries:
        if e["status"] != "void":
            balance += float(e["amount"])
        e["balance"] = round(balance, 2)
    year = today.year
    lines = fetch(conn, """
        SELECT ln.line_id AS id, ln.name, ln.kind, ln.budget, ln.expense_account_id AS "expenseAccountId",
               ea.name AS "expenseAccount", ln.color, ln.sort_order AS "sortOrder", ln.active,
               coalesce(sum(e.amount) FILTER (WHERE e.status = 'actual' AND e.kind <> 'funding'), 0) AS spent,
               coalesce(sum(e.amount) FILTER (WHERE e.status = 'actual' AND e.kind <> 'funding'
                                                AND extract(year FROM e.entry_date) = %s), 0) AS "spentThisYear",
               count(e.*) FILTER (WHERE e.status <> 'void' AND e.kind <> 'funding') AS entries
          FROM srm.expense_line ln
          LEFT JOIN srm.expense_account ea ON ea.expense_account_id = ln.expense_account_id
          LEFT JOIN srm.expense_entry e ON e.line_id = ln.line_id
         WHERE ln.ledger_id = %s GROUP BY ln.line_id, ea.name ORDER BY ln.sort_order, ln.name""", (year, lid))
    for ln in lines:
        ln["remaining"] = round(float(ln["budget"]) - float(ln["spent"]), 2) if ln["budget"] is not None else None

    # Subscriptions: each recurring item's latest charge, what it costs a year and when it renews next.
    subs, seen = [], {}
    for e in reversed(entries):
        if e["recurrence"] == "none" or e["status"] == "void" or e["kind"] != "expense":
            continue
        key = (e["description"] or "").lower()
        if key in seen:
            seen[key]["charges"] += 1
            continue
        step = 1 if e["recurrence"] == "monthly" else 12
        nxt = _add_months(e["date"], step)
        overdue = nxt <= today
        while nxt <= today:
            nxt = _add_months(nxt, step)
        sub = {"entryId": e["id"], "description": e["description"], "vendor": e["vendor"], "line": e["line"],
               "recurrence": e["recurrence"], "amount": float(e["amount"]), "lastCharged": e["date"],
               "annualCost": round(float(e["amount"]) * (12 if step == 1 else 1), 2), "nextRenewal": nxt,
               "unrecorded": overdue, "charges": 1, "url": e["url"]}
        seen[key] = sub
        subs.append(sub)
    subs.sort(key=lambda s: s["nextRenewal"])

    assets = fetch(conn, """
        SELECT a.asset_id AS id, a.entry_id AS "entryId", a.tag, a.name, a.serial_no AS "serialNo", a.location,
               a.assigned_to AS "assignedTo", a.in_service AS "inService", a.cost, a.useful_life_months AS "usefulLifeMonths",
               a.salvage, a.method, a.warranty_end AS "warrantyEnd", a.warranty_entry_id AS "warrantyEntryId",
               w.description AS "warrantyPlan", a.status, a.disposed_date AS "disposedDate",
               a.disposal_proceeds AS "disposalProceeds", a.notes, a.version, e.description AS purchase, e.url,
               a.in_service AS in_service, a.useful_life_months AS useful_life_months, a.disposed_date AS disposed_date
          FROM srm.expense_asset a
          LEFT JOIN srm.expense_entry e ON e.entry_id = a.entry_id
          LEFT JOIN srm.expense_entry w ON w.entry_id = a.warranty_entry_id
         WHERE a.ledger_id = %s ORDER BY a.in_service NULLS LAST, a.name""", (lid,))
    for a in assets:
        a.update(_depreciation(a, today))
        for k in ("in_service", "useful_life_months", "disposed_date"):
            a.pop(k, None)
    training = fetch(conn, """
        SELECT t.training_id AS id, t.entry_id AS "entryId", t.person, t.course, t.provider, t.kind,
               t.start_date AS "startDate", t.end_date AS "endDate", t.hours, t.status,
               t.certificate_expires AS "certificateExpires", t.notes, t.version, e.amount AS cost, e.description AS purchase
          FROM srm.expense_training t LEFT JOIN srm.expense_entry e ON e.entry_id = t.entry_id
         WHERE t.ledger_id = %s ORDER BY t.start_date NULLS LAST, t.course""", (lid,))
    trips = fetch(conn, """
        SELECT t.trip_id AS id, t.name, t.traveler, t.destination, t.purpose, t.depart_date AS "departDate",
               t.return_date AS "returnDate", t.per_diem_meals AS "perDiemMeals", t.per_diem_lodging AS "perDiemLodging",
               t.status, t.notes, t.version,
               coalesce(sum(e.amount) FILTER (WHERE e.status = 'actual' AND e.kind <> 'funding'), 0) AS spent,
               count(e.*) FILTER (WHERE e.status <> 'void') AS entries
          FROM srm.expense_trip t LEFT JOIN srm.expense_entry e ON e.trip_id = t.trip_id
         WHERE t.ledger_id = %s GROUP BY t.trip_id ORDER BY t.depart_date NULLS LAST, t.name""", (lid,))
    for t in trips:
        days = (t["returnDate"] - t["departDate"]).days + 1 if t["departDate"] and t["returnDate"] else None
        t["days"] = days
        allowance = None
        if days:
            allowance = days * float(t["perDiemMeals"] or 0) + (days - 1) * float(t["perDiemLodging"] or 0)
        t["allowance"] = round(allowance, 2) if allowance else None

    alerts = []
    for ln in lines:
        if ln["budget"] is not None and float(ln["spent"]) > float(ln["budget"]) + 0.005:
            alerts.append({"level": "warning", "text": "%s is over its budget by $%.2f" % (ln["name"], float(ln["spent"]) - float(ln["budget"]))})
    pending = [e for e in entries if e["approval"] == "pending" and e["status"] != "void"]
    if pending:
        alerts.append({"level": "info", "text": "%d entr%s waiting for approval" % (len(pending), "y" if len(pending) == 1 else "ies")})
    unrecorded = [s["description"] for s in subs if s["unrecorded"]]
    if unrecorded:
        alerts.append({"level": "info", "text": "Renewed since their last recorded charge (Renew records one): " + ", ".join(unrecorded)})
    for s in subs:
        if not s["unrecorded"] and (s["nextRenewal"] - today).days <= 30:
            alerts.append({"level": "info", "text": "%s renews %s ($%.2f)" % (s["description"], s["nextRenewal"].strftime("%m/%d/%y"), s["amount"])})
    for a in assets:
        if a["warrantyEnd"] and a["status"] != "disposed" and 0 <= (a["warrantyEnd"] - today).days <= 60:
            alerts.append({"level": "warning", "text": "%s's warranty ends %s" % (a["name"], a["warrantyEnd"].strftime("%m/%d/%y"))})
    for t in training:
        if t["certificateExpires"] and (t["certificateExpires"] - today).days <= 90:
            alerts.append({"level": "warning", "text": "%s's certificate (%s) expires %s" % (t["person"] or "A", t["course"], t["certificateExpires"].strftime("%m/%d/%y"))})
    upcoming = [e for e in entries if e["status"] == "scheduled" and (e["date"] - today).days <= 14]
    for e in upcoming:
        alerts.append({"level": "info", "text": "%s of $%.2f scheduled %s" % (e["description"], -float(e["amount"]), e["date"].strftime("%m/%d/%y"))})
    return {"ledger": summary, "lines": lines, "entries": entries, "subscriptions": subs, "assets": assets,
            "training": training, "trips": trips, "alerts": alerts,
            "subscriptionsAnnual": round(sum(s["annualCost"] for s in subs), 2)}


# ------------------------------------------------------------------------------------------------------------ entries

def _entry_fields(conn, lid, body, cur=None):
    cur = cur or {}
    get = lambda k, d=None: body.get(k, cur.get(k, d))   # noqa: E731
    kind = get("kind", "expense")
    if kind not in KINDS:
        raise ValueError("kind must be one of " + ", ".join(KINDS))
    amount = _num(get("amount"), "amount")
    if amount == 0:
        raise ValueError("amount must not be zero")
    if kind == "expense":
        amount = abs(amount)
    elif kind in ("refund", "funding"):
        amount = -abs(amount)
    description = (str(get("description") or "")).strip()[:200]
    if not description:
        raise ValueError("description is required")
    recurrence = get("recurrence", "none") or "none"
    if recurrence not in ("none", "monthly", "yearly"):
        raise ValueError("recurrence must be none, monthly or yearly")
    status = get("status", "actual")
    if status not in ("actual", "scheduled", "void"):
        raise ValueError("status must be actual, scheduled or void")
    approval = get("approval", "none")
    if approval not in ("none", "pending", "approved", "rejected"):
        raise ValueError("approval must be none, pending, approved or rejected")
    line_id = get("lineId")
    if line_id and not fetch(conn, "SELECT 1 FROM srm.expense_line WHERE line_id = %s AND ledger_id = %s", (int(line_id), lid)):
        raise ValueError("lineId must be a line of this expense ledger")
    trip_id = get("tripId")
    if trip_id and not fetch(conn, "SELECT 1 FROM srm.expense_trip WHERE trip_id = %s AND ledger_id = %s", (int(trip_id), lid)):
        raise ValueError("tripId must be a trip of this expense ledger")
    return {"entry_date": _date(get("date") or dt.date.today()), "kind": kind, "description": description,
            "vendor": (str(get("vendor") or "")).strip()[:120] or None,
            "line_id": int(line_id) if line_id and kind != "funding" else None, "trip_id": int(trip_id) if trip_id else None,
            "payee_id": int(get("payeeId")) if get("payeeId") else None, "amount": amount, "recurrence": recurrence,
            "status": status, "approval": approval, "url": (str(get("url") or "")).strip()[:500] or None,
            "notes": (str(get("notes") or "")).strip()[:2000] or None}


def add_entry(conn, code, body, commit=True):
    led = _ledger(conn, code)
    f = _entry_fields(conn, led["ledger_id"], body)
    for key, table in (("cardTxnId", "card_txn_id"), ("bankTxnId", "bank_txn_id")):
        if body.get(key) and fetch(conn, "SELECT 1 FROM srm.expense_entry WHERE %s = %%s" % table, (int(body[key]),)):
            raise Conflict("that %s is already in an expense ledger" % ("card charge" if key == "cardTxnId" else "checking entry"))
    rows = fetch(conn, """
        INSERT INTO srm.expense_entry (ledger_id, line_id, trip_id, entry_date, kind, description, vendor, payee_id, amount,
                                       recurrence, status, approval, url, notes, card_txn_id, bank_txn_id, entered_by, updated_by)
        VALUES (%(lid)s, %(line_id)s, %(trip_id)s, %(entry_date)s, %(kind)s, %(description)s, %(vendor)s, %(payee_id)s,
                %(amount)s, %(recurrence)s, %(status)s, %(approval)s, %(url)s, %(notes)s, %(card)s, %(bank)s, %(by)s, %(by)s)
        RETURNING entry_id""",
                 dict(f, lid=led["ledger_id"], card=body.get("cardTxnId") or None, bank=body.get("bankTxnId") or None, by=_by(body)))
    if not commit:
        return rows[0]["entry_id"]
    fetch(conn, "SELECT srm.match_expense_funding(%s)", (led["ledger_id"],))
    conn.commit()
    return {"id": rows[0]["entry_id"], **book(conn, code)}


def _locked_entry(conn, eid):
    rows = fetch(conn, """SELECT e.*, l.code FROM srm.expense_entry e JOIN srm.expense_ledger l USING (ledger_id)
                           WHERE e.entry_id = %s FOR UPDATE OF e""", (eid,))
    if not rows:
        raise LookupError("no expense entry %s" % eid)
    return rows[0]


def _check_version(conn, row, body, what="entry"):
    if "version" not in body:
        raise ValueError("version is required: the version the edit was made from")
    if int(body["version"]) != row["version"]:
        conn.rollback()
        raise Conflict("%s changed this %s on %s (version %d) since you opened it (version %d)"
                       % (row["updated_by"] or "someone", what, row["updated_at"].strftime("%Y-%m-%d at %H:%M"),
                          row["version"], int(body["version"])), version=row["version"])


def update_entry(conn, eid, body):
    row = _locked_entry(conn, eid)
    _check_version(conn, row, body)
    cur = {"kind": row["kind"], "amount": float(row["amount"]), "description": row["description"], "vendor": row["vendor"],
           "lineId": row["line_id"], "tripId": row["trip_id"], "payeeId": row["payee_id"], "date": row["entry_date"].isoformat(),
           "recurrence": row["recurrence"], "status": row["status"], "approval": row["approval"], "url": row["url"],
           "notes": row["notes"]}
    f = _entry_fields(conn, row["ledger_id"], body, cur)
    fetch(conn, """
        UPDATE srm.expense_entry SET line_id = %(line_id)s, trip_id = %(trip_id)s, entry_date = %(entry_date)s,
               kind = %(kind)s, description = %(description)s, vendor = %(vendor)s, payee_id = %(payee_id)s,
               amount = %(amount)s, recurrence = %(recurrence)s, status = %(status)s, approval = %(approval)s,
               url = %(url)s, notes = %(notes)s,
               bank_txn_id = CASE WHEN %(status)s = 'void' THEN NULL ELSE bank_txn_id END,
               card_txn_id = CASE WHEN %(status)s = 'void' THEN NULL ELSE card_txn_id END,
               version = version + 1, updated_by = %(by)s, updated_at = now()
         WHERE entry_id = %(id)s""", dict(f, id=eid, by=_by(body)))
    fetch(conn, "SELECT srm.match_expense_funding(%s)", (row["ledger_id"],))
    conn.commit()
    return book(conn, row["code"])


def delete_entries(conn, code, body):
    """Deletes entries of one ledger for good, each at the version it was seen at; answers with the book."""
    led = _ledger(conn, code)
    chosen = body.get("entries") or []
    if not isinstance(chosen, list) or not chosen:
        raise ValueError("entries is a list of {id, version}")
    for c in chosen:
        row = _locked_entry(conn, int(c.get("id") or 0))
        if row["ledger_id"] != led["ledger_id"]:
            conn.rollback()
            raise ValueError("entry %s is in %s, not %s" % (row["entry_id"], row["code"], led["code"]))
        _check_version(conn, row, c)
    ids = [int(c["id"]) for c in chosen]
    fetch(conn, "DELETE FROM srm.tax_assignment WHERE source = 'ledger' AND entry_id = ANY(%s)", (ids,))
    fetch(conn, "DELETE FROM srm.expense_entry WHERE entry_id = ANY(%s)", (ids,))
    fetch(conn, "SELECT srm.match_expense_funding(%s)", (led["ledger_id"],))
    conn.commit()
    return book(conn, led["code"])


def link_entry(conn, eid, body):
    """Links an entry to the card charge or check that paid it (Spending Analysis ▸ Admin's overlap finder), as Add
    from Card Charges does a new one: Spending Analysis then counts the purchase once, as the charge. Answers with the
    book."""
    row = _locked_entry(conn, eid)
    _check_version(conn, row, body)
    source, txn = body.get("source"), int(body.get("txnId") or 0)
    if source not in ("card", "bank"):
        raise ValueError("source must be card or bank")
    if row["status"] == "void":
        raise ValueError("a void entry can't be linked")
    if row["card_txn_id"] or row["bank_txn_id"]:
        raise ValueError("this entry is already linked to a card charge or check")
    table, column = ("srm.card_txn", "card_txn_id") if source == "card" else ("srm.bank_txn", "bank_txn_id")
    if not fetch(conn, "SELECT 1 FROM %s WHERE txn_id = %%s AND status <> 'void'" % table, (txn,)):
        raise LookupError("no %s entry %s" % ("card" if source == "card" else "checking", txn))
    taken = fetch(conn, """SELECT e.description, l.code FROM srm.expense_entry e JOIN srm.expense_ledger l USING (ledger_id)
                            WHERE e.%s = %%s""" % column, (txn,))
    if taken:
        raise ValueError("that %s is already linked to %s in %s" % ("charge" if source == "card" else "check",
                                                                    taken[0]["description"], taken[0]["code"]))
    fetch(conn, """UPDATE srm.expense_entry SET %s = %%s, version = version + 1, updated_by = %%s, updated_at = now()
                    WHERE entry_id = %%s""" % column, (txn, _by(body), eid))
    conn.commit()
    return book(conn, row["code"])


def approve_entry(conn, eid, body):
    row = _locked_entry(conn, eid)
    approval = body.get("approval")
    if approval not in ("pending", "approved", "rejected", "none"):
        raise ValueError("approval must be pending, approved, rejected or none")
    by = _by(body)
    if approval in ("approved", "rejected") and row["entered_by"] and row["entered_by"] == by and row["approval"] == "pending":
        raise ValueError("an entry waiting for approval is approved by someone other than who entered it")
    decided = approval in ("approved", "rejected")
    fetch(conn, """UPDATE srm.expense_entry SET approval = %s, approved_by = %s, approved_at = CASE WHEN %s THEN now() END,
                          version = version + 1, updated_by = %s, updated_at = now() WHERE entry_id = %s""",
          (approval, by if decided else None, decided, by, eid))
    conn.commit()
    return book(conn, row["code"])


def renew_entry(conn, eid, body):
    """A subscription's next charge: the same item a month or a year after its latest charge."""
    row = _locked_entry(conn, eid)
    if row["recurrence"] == "none":
        raise ValueError("only a monthly or yearly item renews")
    latest = fetch(conn, """SELECT max(entry_date) AS d FROM srm.expense_entry WHERE ledger_id = %s
                             AND lower(description) = lower(%s) AND status <> 'void' AND kind = 'expense'""",
                   (row["ledger_id"], row["description"]))[0]["d"]
    date = _date(body["date"]) if body.get("date") else _add_months(latest, 1 if row["recurrence"] == "monthly" else 12)
    return add_entry(conn, row["code"], {
        "date": date.isoformat(), "kind": "expense", "description": row["description"], "vendor": row["vendor"],
        "lineId": row["line_id"], "amount": _num(body.get("amount") or row["amount"], "amount"),
        "recurrence": row["recurrence"], "url": row["url"], "by": _by(body)})


def fund(conn, code, body):
    """Funding transfers: `months` of them a month apart from `date`; those after today are scheduled."""
    led = _ledger(conn, code)
    amount = abs(_num(body.get("amount"), "amount"))
    if amount == 0:
        raise ValueError("amount must not be zero")
    months = int(body.get("months") or 1)
    if not 1 <= months <= 60:
        raise ValueError("months must be 1–60")
    start = _date(body.get("date") or dt.date.today())
    payee = body.get("payeeId") or (led["funding_payees"][0] if led["funding_payees"] else None)
    name = fetch(conn, "SELECT name FROM srm.payee WHERE payee_id = %s", (payee,))[0]["name"] if payee else None
    today = dt.date.today()
    for i in range(months):
        d = _add_months(start, i)
        add_entry(conn, code, {"date": d.isoformat(), "kind": "funding", "description": body.get("description") or name or "Funding",
                               "payeeId": payee, "amount": amount, "status": "scheduled" if d > today else "actual",
                               "by": _by(body)}, commit=False)
    fetch(conn, "SELECT srm.match_expense_funding(%s)", (led["ledger_id"],))
    conn.commit()
    return book(conn, code)


# ------------------------------------------------------------------------------------------------------------ lines, assets, training, trips

def _save_row(conn, code, table, key, rid, body, columns, label):
    """Adds (rid 0) or changes one row of `table` in a ledger; `columns` maps column -> value. Rows with a version are
    version-checked."""
    led = _ledger(conn, code)
    rid = int(rid)
    if rid == 0:
        cols = ["ledger_id"] + list(columns)
        fetch(conn, "INSERT INTO srm.%s (%s) VALUES (%s)" % (table, ", ".join(cols), ", ".join(["%s"] * len(cols))),
              [led["ledger_id"]] + list(columns.values()))
    else:
        rows = fetch(conn, "SELECT * FROM srm.%s WHERE %s = %%s AND ledger_id = %%s FOR UPDATE" % (table, key), (rid, led["ledger_id"]))
        if not rows:
            raise LookupError("no %s %s in %s" % (label, rid, led["code"]))
        if "version" in rows[0]:
            _check_version(conn, rows[0], body, label)
            columns = dict(columns, version=rows[0]["version"] + 1)
        sets = ", ".join("%s = %%s" % c for c in columns)
        extra = ", updated_at = now()" if "updated_at" in rows[0] else ""
        fetch(conn, "UPDATE srm.%s SET %s%s WHERE %s = %%s" % (table, sets, extra, key), list(columns.values()) + [rid])
    conn.commit()
    return book(conn, code)


def save_line(conn, code, rid, body):
    kind = body.get("kind") or "other"
    if kind not in LINE_KINDS:
        raise ValueError("kind must be one of " + ", ".join(LINE_KINDS))
    name = _text(body, "name", 80)
    if not name:
        raise ValueError("name is required")
    color = _text(body, "color", 7)
    if color and not re.match(r"^#[0-9A-Fa-f]{6}$", color):
        raise ValueError("color is #rrggbb")
    return _save_row(conn, code, "expense_line", "line_id", rid, body, {
        "name": name, "kind": kind, "budget": _opt_num(body, "budget"), "expense_account_id": body.get("expenseAccountId") or None,
        "color": color, "sort_order": int(body.get("sortOrder") or 100), "active": bool(body.get("active", True))}, "line")


def save_asset(conn, code, rid, body):
    name = _text(body, "name", 120)
    if not name:
        raise ValueError("name is required")
    method = body.get("method") or "straight-line"
    if method not in ("straight-line", "declining-balance"):
        raise ValueError("method must be straight-line or declining-balance")
    status = body.get("status") or "in service"
    if status not in ("in service", "in repair", "retired", "disposed"):
        raise ValueError("status must be in service, in repair, retired or disposed")
    life = body.get("usefulLifeMonths")
    return _save_row(conn, code, "expense_asset", "asset_id", rid, body, {
        "entry_id": body.get("entryId") or None, "tag": _text(body, "tag", 40), "name": name,
        "serial_no": _text(body, "serialNo", 80), "location": _text(body, "location", 120),
        "assigned_to": _text(body, "assignedTo", 120), "in_service": _opt_date(body, "inService"),
        "cost": _num(body.get("cost") or 0, "cost"), "useful_life_months": int(life) if life not in (None, "") else None,
        "salvage": _num(body.get("salvage") or 0, "salvage"), "method": method, "warranty_end": _opt_date(body, "warrantyEnd"),
        "warranty_entry_id": body.get("warrantyEntryId") or None, "status": status,
        "disposed_date": _opt_date(body, "disposedDate"), "disposal_proceeds": _opt_num(body, "disposalProceeds"),
        "notes": _text(body, "notes", 2000), "updated_by": _by(body)}, "asset")


def save_training(conn, code, rid, body):
    course = _text(body, "course", 160)
    if not course:
        raise ValueError("course is required")
    kind = body.get("kind") or "course"
    if kind not in ("course", "subscription", "lessons", "conference", "certification"):
        raise ValueError("kind must be course, subscription, lessons, conference or certification")
    status = body.get("status") or "enrolled"
    if status not in ("planned", "enrolled", "in progress", "completed", "dropped"):
        raise ValueError("status must be planned, enrolled, in progress, completed or dropped")
    return _save_row(conn, code, "expense_training", "training_id", rid, body, {
        "entry_id": body.get("entryId") or None, "person": _text(body, "person", 120), "course": course,
        "provider": _text(body, "provider", 120), "kind": kind, "start_date": _opt_date(body, "startDate"),
        "end_date": _opt_date(body, "endDate"), "hours": _opt_num(body, "hours"), "status": status,
        "certificate_expires": _opt_date(body, "certificateExpires"), "notes": _text(body, "notes", 2000),
        "updated_by": _by(body)}, "training record")


def save_trip(conn, code, rid, body):
    name = _text(body, "name", 120)
    if not name:
        raise ValueError("name is required")
    status = body.get("status") or "planned"
    if status not in ("planned", "booked", "completed", "cancelled"):
        raise ValueError("status must be planned, booked, completed or cancelled")
    depart, ret = _opt_date(body, "departDate"), _opt_date(body, "returnDate")
    if depart and ret and ret < depart:
        raise ValueError("the return date comes before the departure")
    return _save_row(conn, code, "expense_trip", "trip_id", rid, body, {
        "name": name, "traveler": _text(body, "traveler", 120), "destination": _text(body, "destination", 120),
        "purpose": _text(body, "purpose", 500), "depart_date": depart, "return_date": ret,
        "per_diem_meals": _opt_num(body, "perDiemMeals"), "per_diem_lodging": _opt_num(body, "perDiemLodging"),
        "status": status, "notes": _text(body, "notes", 2000), "updated_by": _by(body)}, "trip")


def card_charges(conn, code):
    _ledger(conn, code)
    return {"charges": fetch(conn, """
        SELECT t.txn_id AS id, a.code AS "cardAccount", a.name AS card, t.txn_date AS date,
               coalesce(p.name, t.payee_name) AS payee, t.memo, t.amount, e.name AS "expenseAccount"
          FROM srm.card_txn t JOIN srm.card_account a USING (card_account_id)
          LEFT JOIN srm.payee p ON p.payee_id = t.payee_id
          LEFT JOIN srm.expense_account e ON e.expense_account_id = t.expense_account_id
         WHERE t.kind IN ('charge', 'credit') AND t.status <> 'void' AND t.txn_date >= current_date - 365
           AND NOT EXISTS (SELECT 1 FROM srm.expense_entry x WHERE x.card_txn_id = t.txn_id)
         ORDER BY t.txn_date DESC LIMIT 300""")}


def route(conn, method, parts, body, q):
    """The expense ledger endpoints' answer, or None when the path isn't one of them."""
    if parts == ["expense-ledgers"] and method == "GET":
        return ledgers(conn)
    if len(parts) == 2 and parts[0] == "expense-ledgers":
        if method == "GET":
            return book(conn, parts[1])
        if method == "PUT":
            return save_ledger(conn, parts[1], body)
    if len(parts) == 3 and parts[0] == "expense-ledgers":
        if parts[2] == "entries" and method == "POST":
            return add_entry(conn, parts[1], body)
        if parts[2] == "fund" and method == "POST":
            return fund(conn, parts[1], body)
        if parts[2] == "card-charges" and method == "GET":
            return card_charges(conn, parts[1])
    if len(parts) == 4 and parts[0] == "expense-ledgers" and parts[2:] == ["entries", "delete"] and method == "POST":
        return delete_entries(conn, parts[1], body)
    if len(parts) == 4 and parts[0] == "expense-ledgers" and method == "PUT":
        save = {"lines": save_line, "assets": save_asset, "training": save_training, "trips": save_trip}.get(parts[2])
        if save:
            return save(conn, parts[1], parts[3], body)
    if len(parts) == 2 and parts[0] == "expense-entries" and method == "PUT":
        return update_entry(conn, int(parts[1]), body)
    if len(parts) == 3 and parts[0] == "expense-entries" and method == "POST":
        if parts[2] == "approve":
            return approve_entry(conn, int(parts[1]), body)
        if parts[2] == "renew":
            return renew_entry(conn, int(parts[1]), body)
        if parts[2] == "link":
            return link_entry(conn, int(parts[1]), body)
    return None
