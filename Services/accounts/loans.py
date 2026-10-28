"""Loan accounts for the accounts service: mortgages and vehicle loans (V053), their billing statements and forecast.

    GET    /loans                                   every loan with its balance, rate, payment and next due date
    PUT    /loans/<code>                            create (version 0) or change one {version, name, kind mortgage /
                                                    vehicle, lender, last4, collateral, originalAmount, interestRate,
                                                    termMonths, firstPaymentDate, maturityDate, paymentAmount,
                                                    escrowAmount, extraPrincipal, paymentPayees, statementFolder,
                                                    interestDeductible, status, paidOffDate, notes, by}
    DELETE /loans/<code>?confirm=<code>&by=         remove it with its statements (the PDFs stay in its folder)
    GET    /loans/<code>?extra=                     the loan with its statements, the lender's activity, the checks
                                                    that paid it, the forecast (extra: a monthly extra principal to
                                                    try) and each year's interest
    POST   /loans/<code>/statements                 read billing statements {files: [{fileName, text, pdf}], by}: text
                                                    is the PDF's text (MxAcctMGR reads it with PDFKit), pdf the file
                                                    in base64, saved in the loan's statement folder
    DELETE /loans/<code>/statements/<yyyy-mm-dd>    take a statement off, with the activity only it showed
    PUT    /loans/<code>/tax-years/<year>           the lender's Form 1098 {interestPaid, pointsPaid,
                                                    mortgageInsurance, propertyTax, notes, by}
    DELETE /loans/<code>/tax-years/<year>           take it off: the year counts from the statements again

A statement gives the principal balance after the last payment, the rate, the payment due and its split, the
year-to-date principal and interest, and what the lender applied since the statement before. The forecast runs from
the latest one: each month's interest is the balance times the rate over 12 (rounded to the cent), the rest of the
payment is principal, and the extra principal comes off too, until the balance is paid. A payment is expected as many
days from its due date as the loan's payments have been (the median), so a January payment made on December 31 counts
in the year before, as the lender's Form 1098 counts it. A year's interest is the year-to-date interest of its last
statement plus the activity after it in that year (a missing statement doesn't lose its interest), plus the forecast
for the payments still to come; once its Form 1098 is entered, that counts.
"""

import base64
import datetime as dt
import hashlib
import os
import re
import statistics
from decimal import Decimal, ROUND_HALF_UP

from bank import Conflict, fetch, _date, _num

KINDS = ("mortgage", "vehicle")
STATUSES = ("open", "paid_off")
DEFAULT_FOLDER = "~/MyCodeGIT/MxDataSRM/loans"
# Lenders a statement may name, the longest first.
LENDERS = ("Wells Fargo Home Mortgage", "Rocket Mortgage", "Mr. Cooper", "Chase Home Lending", "Bank of America",
           "Capital One Auto Finance", "Toyota Financial Services", "American Honda Finance", "Ally Financial",
           "Santander Consumer", "Navy Federal", "U.S. Bank", "Wells Fargo", "PNC", "Truist", "USAA", "Chase", "Ally")
MONEY = r"-?\(?-?\$\s?[\d,]+\.\d{2}\)?"


def _by(body):
    return str(body.get("by") or "MxAcctMGR")[:80]


def _cents(x):
    return float(Decimal(str(x)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def _money(s):
    """$1,167.52, -$500.00 or ($500.00) as a number."""
    s = s.strip()
    neg = s.startswith("-") or s.startswith("(") or "-$" in s
    v = float(re.sub(r"[^\d.]", "", s))
    return -v if neg else v


def _day(s, ref=None):
    """mm/dd/yy, mm/dd/yyyy, or mm/dd in the year of ref (the year before when its month comes after ref's)."""
    parts = [int(p) for p in s.split("/")]
    if len(parts) == 3:
        y = parts[2] + (2000 if parts[2] < 100 else 0)
    else:
        y = ref.year - (1 if ref and parts[0] > ref.month else 0)
    return dt.date(y, parts[0], parts[1])


def _add_months(d, n):
    m = d.month - 1 + n
    y, m = d.year + m // 12, m % 12 + 1
    last = [31, 29 if y % 4 == 0 and (y % 100 or y % 400 == 0) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
    return dt.date(y, m, min(d.day, last))


# ------------------------------------------------------------------------------------------------- reading statements

def _first(text, *patterns):
    for p in patterns:
        m = re.search(p, text, re.I | re.M)
        if m:
            return m.group(1)
    return None


def _section(text, start, ends):
    """The lines after the first line starting with start, up to the first starting with one of ends."""
    m = re.search(r"^" + start + r".*$", text, re.I | re.M)
    if not m:
        return ""
    rest = text[m.end():]
    e = re.search(r"^(" + "|".join(ends) + ")", rest, re.I | re.M)
    return rest[:e.start()] if e else rest


def parse_statement(text):
    """A billing statement's figures from its text, refused (ValueError) when it has no statement date or principal
    balance. Reads the labels lenders print (Wells Fargo Home Mortgage's layout, and the usual alternatives)."""
    t = text.replace("\r", "")
    when = _first(t, r"Statement date:?\s+(\d{1,2}/\d{1,2}/\d{2,4})", r"Statement closing date:?\s+(\d{1,2}/\d{1,2}/\d{2,4})")
    balance = _first(t, r"Unpaid principal balance:?\s+(" + MONEY + ")", r"Current principal balance:?\s+(" + MONEY + ")",
                     r"Outstanding principal(?: balance)?:?\s+(" + MONEY + ")", r"^Principal balance:?\s+(" + MONEY + ")")
    if not when or not balance:
        raise ValueError("it isn't a loan billing statement MxAcctMGR reads: it needs a statement date and a principal balance")
    sdate = _day(when)
    out = {"statementDate": sdate, "principalBalance": _money(balance)}
    loan_no = _first(t, r"Loan number:?\s+([0-9Xx*\- ]{4,30})$", r"Account number:?\s+([0-9Xx*\- ]{4,30})$")
    digits = re.sub(r"\D", "", loan_no or "")
    out["last4"] = digits[-4:] if len(digits) >= 4 else None
    due = _first(t, r"Payment due date:?\s+(\d{1,2}/\d{1,2}/\d{2,4})", r"Due date:?\s+(\d{1,2}/\d{1,2}/\d{2,4})")
    out["dueDate"] = _day(due) if due else None
    amount_due = _first(t, r"Total amount due(?:\s+\d{1,2}/\d{1,2}/\d{2,4})?:?\s+(" + MONEY + ")", r"Amount due:?\s+(" + MONEY + ")")
    out["amountDue"] = _money(amount_due) if amount_due else None
    regular = _first(t, r"^Current payment:?\s+(" + MONEY + ")", r"Regular monthly payment:?\s+(" + MONEY + ")",
                     r"^Monthly payment(?: amount)?:?\s+(" + MONEY + ")", r"^Regular payment:?\s+(" + MONEY + ")")
    out["regularPayment"] = _money(regular) if regular else None
    # The payment due's split: Principal / Interest / Escrow lines before the current payment.
    split = _section(t, r"Explanation of amount due", [r"Current payment", r"Regular monthly payment", r"Total amount due"]) or t
    for key, label in (("duePrincipal", r"Principal"), ("dueInterest", r"Interest"), ("dueEscrow", r"Escrow")):
        v = _first(split, r"^" + label + r"[^\n$]*?\s(" + MONEY + r")\s*$")
        out[key] = _money(v) if v else None
    escrow_bal = _first(t, r"Escrow balance:?\s+(" + MONEY + ")")
    out["escrowBalance"] = _money(escrow_bal) if escrow_bal else None
    rate = _first(t, r"Interest rate:?\s+(\d{1,2}\.\d{1,4})\s*%")
    out["interestRate"] = float(rate) if rate else None
    maturity = _first(t, r"Maturity date(?: \(month/year\))?:?\s+(\d{1,2}/\d{2,4}(?:/\d{2,4})?)")
    if maturity:
        p = maturity.split("/")
        out["maturityDate"] = _day(maturity) if len(p) == 3 else dt.date(int(p[1]) + (2000 if int(p[1]) < 100 else 0), int(p[0]), 1)
    else:
        out["maturityDate"] = None
    # Year to date: the second amount on each line after "Since last statement Year-to-date".
    ytd = _section(t, r"Since last statement", [r"\*", r"Activity since", r"Informational", r"For your consideration"])
    for key, label in (("ytdReceived", r"Total received"), ("ytdPrincipal", r"Principal"), ("ytdInterest", r"Interest"),
                       ("ytdEscrow", r"Escrow")):
        m = re.search(r"^" + label + r"[^\n$]*?(" + MONEY + r")\s+(" + MONEY + r")\s*$", ytd, re.I | re.M)
        out[key] = _money(m.group(2)) if m else None
    out["lender"] = next((name for name in LENDERS if name.lower() in t.lower()), None)
    out["activity"] = _activity(t, sdate)
    return out


def _activity(t, sdate):
    """What the lender applied since the statement before: each line's date, description and amounts, the columns
    told apart by the description (a payment: total, principal, interest, escrow, other)."""
    block = _section(t, r"Activity since your last statement", [r"For your consideration", r"Informational", r"Please detach",
                                                                 r"Important", r"Past payments", r"Explanation"])
    rows = []
    for line in block.splitlines():
        m = re.match(r"^(\d{1,2}/\d{1,2}(?:/\d{2,4})?)\s+(.+?)\s+((?:" + MONEY + r"\s*)+)$", line.strip())
        if not m:
            continue
        desc = m.group(2).strip()
        amounts = [_money(a) for a in re.findall(MONEY, m.group(3))]
        total, rest = amounts[0], amounts[1:]
        row = {"date": _day(m.group(1), sdate), "description": desc, "total": total, "principal": 0.0, "interest": 0.0,
               "escrow": 0.0, "other": 0.0, "dueMonth": None}
        low = desc.lower()
        month = re.search(r"\b(\d{1,2})/(\d{4})\b", desc)
        if re.search(r"\bpayment\b", low) and not re.search(r"principal|escrow|late|fee", low):
            row["kind"] = "payment"
            for key, v in zip(("principal", "interest", "escrow", "other"), rest):
                row[key] = v
            if month:
                row["dueMonth"] = dt.date(int(month.group(2)), int(month.group(1)), 1)
        elif "principal" in low:
            row["kind"], row["principal"] = "principal", rest[0] if rest else total
        elif re.search(r"escrow|tax|insurance|hazard|pmi|mip", low):
            row["kind"], row["escrow"] = "escrow", rest[0] if rest else total
        elif re.search(r"late|fee|charge", low):
            row["kind"], row["other"] = "fee", rest[0] if rest else total
        else:
            row["kind"], row["other"] = "other", rest[0] if rest else total
        rows.append(row)
    return rows


# ------------------------------------------------------------------------------------------------- loans

LOAN_SELECT = """
    SELECT loan_id AS id, code, name, kind, lender, account_last4 AS last4, collateral, original_amount AS "originalAmount",
           interest_rate AS "interestRate", term_months AS "termMonths", first_payment_date AS "firstPaymentDate",
           maturity_date AS "maturityDate", payment_amount AS "paymentAmount", escrow_amount AS "escrowAmount",
           extra_principal AS "extraPrincipal", payment_payees AS "paymentPayees", statement_folder AS "statementFolder",
           interest_deductible AS "interestDeductible", status, paid_off_date AS "paidOffDate", notes, version,
           updated_by AS "updatedBy", updated_at AS "updatedAt"
      FROM srm.loan_account"""
STATEMENT_SELECT = """
    SELECT statement_id AS id, statement_date AS "statementDate", payment_due_date AS "dueDate", amount_due AS "amountDue",
           regular_payment AS "regularPayment", due_principal AS "duePrincipal", due_interest AS "dueInterest",
           due_escrow AS "dueEscrow", principal_balance AS "principalBalance", escrow_balance AS "escrowBalance",
           interest_rate AS "interestRate", maturity_date AS "maturityDate", ytd_received AS "ytdReceived",
           ytd_principal AS "ytdPrincipal", ytd_interest AS "ytdInterest", ytd_escrow AS "ytdEscrow", lender,
           loan_last4 AS last4, file_name AS "fileName", loaded_by AS "loadedBy", loaded_at AS "loadedAt"
      FROM srm.loan_statement WHERE loan_id = %s ORDER BY statement_date DESC"""
ACTIVITY_SELECT = """
    SELECT a.activity_id AS id, a.txn_date AS date, a.description, a.kind, a.due_month AS "dueMonth", a.total,
           a.principal, a.interest, a.escrow, a.other, s.statement_date AS "statementDate"
      FROM srm.loan_activity a JOIN srm.loan_statement s USING (statement_id)
     WHERE a.loan_id = %s ORDER BY a.txn_date DESC, a.kind DESC, a.activity_id DESC"""


def _floats(rows):
    for r in rows:
        for k, v in r.items():
            if isinstance(v, Decimal):
                r[k] = float(v)
    return rows


def _loan(conn, code, lock=False):
    rows = _floats(fetch(conn, LOAN_SELECT + " WHERE upper(code) = upper(%s)" + (" FOR UPDATE" if lock else ""), (code,)))
    if not rows:
        raise LookupError("no loan account %s" % code)
    return rows[0]


def _folder(loan):
    return os.path.expanduser(loan["statementFolder"] or os.path.join(DEFAULT_FOLDER, loan["code"]))


def loans(conn):
    out = []
    for l in _floats(fetch(conn, LOAN_SELECT + " ORDER BY status, kind, lower(name)")):
        s = _floats(fetch(conn, STATEMENT_SELECT + " LIMIT 1", (l["id"],)))
        latest = s[0] if s else None
        l["balance"] = latest["principalBalance"] if latest else None
        l["balanceAsOf"] = latest["statementDate"] if latest else None
        l["nextDue"] = latest["dueDate"] if latest else None
        l["statements"] = fetch(conn, "SELECT count(*) AS n FROM srm.loan_statement WHERE loan_id = %s", (l["id"],))[0]["n"]
        out.append(l)
    payees = fetch(conn, "SELECT payee_id AS id, name FROM srm.payee WHERE status <> 'closed' ORDER BY lower(name)")
    return {"loans": out, "payees": payees, "defaultFolder": DEFAULT_FOLDER}


def save_loan(conn, code, body):
    code = str(code).upper()
    if not re.match(r"^[A-Z0-9_-]{1,40}$", code):
        raise ValueError("code must be 1–40 letters, digits, _ or -")
    version = int(body.get("version") or 0)
    cur = fetch(conn, "SELECT loan_id, version, kind FROM srm.loan_account WHERE code = %s FOR UPDATE", (code,))
    if version == 0 and cur:
        raise Conflict("there is already a loan account %s" % code, version=cur[0]["version"])
    if version and not cur:
        raise LookupError("no loan account %s" % code)
    if cur and version != cur[0]["version"]:
        conn.rollback()
        raise Conflict("someone changed this loan since you opened it", version=cur[0]["version"])
    kind = body.get("kind") or (cur[0]["kind"] if cur else None)
    if kind not in KINDS:
        raise ValueError("kind must be mortgage or vehicle")
    name = " ".join(str(body.get("name") or "").split())[:120]
    if not name:
        raise ValueError("name is required")
    last4 = re.sub(r"\s", "", str(body.get("last4") or ""))[-4:] or None
    if last4 and not re.match(r"^[0-9A-Za-z]{2,4}$", last4):
        raise ValueError("last4 is the last four digits of the loan number")

    def num(key, lo=None):
        v = body.get(key)
        if v in (None, ""):
            return None
        v = _num(v, key)
        if lo is not None and v < lo:
            raise ValueError("%s must not be below %s" % (key, lo))
        return v

    def day(key):
        return _date(body[key], key) if body.get(key) else None

    payees = [int(p) for p in body.get("paymentPayees") or []]
    if payees:
        found = {r["payee_id"] for r in fetch(conn, "SELECT payee_id FROM srm.payee WHERE payee_id = ANY(%s)", (payees,))}
        missing = [p for p in payees if p not in found]
        if missing:
            raise ValueError("no target account %s" % missing[0])
    status = body.get("status") or "open"
    if status not in STATUSES:
        raise ValueError("status must be open or paid_off")
    term = body.get("termMonths")
    values = {
        "name": name, "kind": kind, "lender": (str(body.get("lender") or "").strip()[:120] or None), "account_last4": last4,
        "collateral": (str(body.get("collateral") or "").strip()[:200] or None), "original_amount": num("originalAmount", 0.01),
        "interest_rate": num("interestRate", 0), "term_months": int(term) if term not in (None, "") else None,
        "first_payment_date": day("firstPaymentDate"), "maturity_date": day("maturityDate"),
        "payment_amount": num("paymentAmount", 0.01), "escrow_amount": num("escrowAmount", 0) or 0,
        "extra_principal": num("extraPrincipal", 0) or 0, "payment_payees": payees,
        "statement_folder": (str(body.get("statementFolder") or "").strip()[:400] or None),
        "interest_deductible": bool(body["interestDeductible"]) if "interestDeductible" in body else kind == "mortgage",
        "status": status, "paid_off_date": day("paidOffDate"), "notes": (str(body.get("notes") or "").strip()[:2000] or None),
        "updated_by": _by(body)}
    cols = list(values)
    if cur:
        fetch(conn, "UPDATE srm.loan_account SET %s, version = version + 1, updated_at = now() WHERE code = %%(code)s"
              % ", ".join("%s = %%(%s)s" % (c, c) for c in cols), dict(values, code=code))
    else:
        fetch(conn, "INSERT INTO srm.loan_account (code, %s) VALUES (%%(code)s, %s)"
              % (", ".join(cols), ", ".join("%%(%s)s" % c for c in cols)), dict(values, code=code))
    conn.commit()
    return dict(loans(conn), code=code)


def remove_loan(conn, code, q):
    loan = _loan(conn, code, lock=True)
    if str(q.get("confirm") or "").upper() != loan["code"]:
        raise ValueError("confirm must be the loan's code, %s" % loan["code"])
    n = fetch(conn, """SELECT (SELECT count(*) FROM srm.loan_statement WHERE loan_id = %s) AS statements,
                              (SELECT count(*) FROM srm.loan_activity WHERE loan_id = %s) AS activity""", (loan["id"], loan["id"]))[0]
    fetch(conn, "DELETE FROM srm.loan_account WHERE loan_id = %s", (loan["id"],))
    conn.commit()
    return dict(loans(conn), removed={"code": loan["code"], "name": loan["name"], "statements": n["statements"],
                                      "activity": n["activity"], "folder": _folder(loan)})


# ------------------------------------------------------------------------------------------------- importing statements

def _save_pdf(loan, name, data):
    """Keeps the PDF in the loan's statement folder (as it is named; a different file of that name gets a number)."""
    folder = _folder(loan)
    os.makedirs(folder, exist_ok=True)
    base, ext = os.path.splitext(name)
    path, n = os.path.join(folder, name), 2
    while os.path.exists(path):
        with open(path, "rb") as f:
            if f.read() == data:
                return path
        path, n = os.path.join(folder, "%s (%d)%s" % (base, n, ext)), n + 1
    with open(path, "wb") as f:
        f.write(data)
    return path


def import_statements(conn, code, body):
    loan = _loan(conn, code, lock=True)
    by = _by(body)
    results = []
    for f in body.get("files") or []:
        name = os.path.basename(str(f.get("fileName") or "statement.pdf"))[:200]
        r = {"fileName": name}
        results.append(r)
        try:
            text = str(f.get("text") or "")
            if not text.strip():
                raise ValueError("it has no text to read (a scanned image?)")
            data = base64.b64decode(f["pdf"]) if f.get("pdf") else None
            sha = hashlib.sha256(data if data is not None else text.encode()).hexdigest()
            if fetch(conn, "SELECT 1 FROM srm.loan_statement WHERE loan_id = %s AND file_sha256 = %s", (loan["id"], sha)):
                r.update(status="already", message="read already")
                continue
            s = parse_statement(text)
            if loan["last4"] and s["last4"] and s["last4"] != loan["last4"]:
                raise ValueError("it is for loan ···%s, not ···%s" % (s["last4"], loan["last4"]))
            fetch(conn, "SAVEPOINT statement")
            try:
                if data is not None:
                    name = os.path.basename(_save_pdf(loan, name, data))
                sid = fetch(conn, """
                    INSERT INTO srm.loan_statement (loan_id, statement_date, payment_due_date, amount_due, regular_payment,
                           due_principal, due_interest, due_escrow, principal_balance, escrow_balance, interest_rate,
                           maturity_date, ytd_received, ytd_principal, ytd_interest, ytd_escrow, lender, loan_last4,
                           file_name, file_sha256, statement_text, loaded_by)
                    VALUES (%(loan)s, %(statementDate)s, %(dueDate)s, %(amountDue)s, %(regularPayment)s, %(duePrincipal)s,
                            %(dueInterest)s, %(dueEscrow)s, %(principalBalance)s, %(escrowBalance)s, %(interestRate)s,
                            %(maturityDate)s, %(ytdReceived)s, %(ytdPrincipal)s, %(ytdInterest)s, %(ytdEscrow)s, %(lender)s,
                            %(last4)s, %(file)s, %(sha)s, %(text)s, %(by)s)
                    ON CONFLICT (loan_id, statement_date) DO UPDATE SET payment_due_date = excluded.payment_due_date,
                           amount_due = excluded.amount_due, regular_payment = excluded.regular_payment,
                           due_principal = excluded.due_principal, due_interest = excluded.due_interest,
                           due_escrow = excluded.due_escrow, principal_balance = excluded.principal_balance,
                           escrow_balance = excluded.escrow_balance, interest_rate = excluded.interest_rate,
                           maturity_date = excluded.maturity_date, ytd_received = excluded.ytd_received,
                           ytd_principal = excluded.ytd_principal, ytd_interest = excluded.ytd_interest,
                           ytd_escrow = excluded.ytd_escrow, lender = excluded.lender, loan_last4 = excluded.loan_last4,
                           file_name = excluded.file_name, file_sha256 = excluded.file_sha256,
                           statement_text = excluded.statement_text, loaded_by = excluded.loaded_by, loaded_at = now()
                    RETURNING statement_id""", dict(s, loan=loan["id"], file=name, sha=sha, text=text, by=by))[0]["statement_id"]
                added = 0
                for a in s["activity"]:
                    added += len(fetch(conn, """
                        INSERT INTO srm.loan_activity (loan_id, statement_id, txn_date, description, kind, due_month, total,
                                                       principal, interest, escrow, other)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                        ON CONFLICT (loan_id, txn_date, description, total) DO NOTHING RETURNING activity_id""",
                        (loan["id"], sid, a["date"], a["description"][:200], a["kind"], a["dueMonth"], a["total"],
                         a["principal"], a["interest"], a["escrow"], a["other"])))
                fetch(conn, "RELEASE SAVEPOINT statement")
            except Exception:
                fetch(conn, "ROLLBACK TO SAVEPOINT statement")
                raise
            r.update(status="read", statementDate=s["statementDate"], balance=s["principalBalance"], activity=added,
                     message="statement of %s: balance %s" % (s["statementDate"].strftime("%m/%d/%Y"), "${:,.2f}".format(s["principalBalance"])))
        except (ValueError, KeyError) as e:
            r.update(status="refused", message=str(e).strip("'\""))
    _fill_terms(conn, loan, by)
    conn.commit()
    return dict(detail(conn, code, {}), imported=results)


def _fill_terms(conn, loan, by):
    """The terms the loan leaves empty, from its latest statement: rate, maturity, payment, escrow, lender, last four."""
    s = _floats(fetch(conn, STATEMENT_SELECT + " LIMIT 1", (loan["id"],)))
    if not s:
        return
    s = s[0]
    pi = None
    if s["duePrincipal"] is not None and s["dueInterest"] is not None:
        pi = _cents(s["duePrincipal"] + s["dueInterest"])
    elif s["regularPayment"] is not None:
        pi = _cents(s["regularPayment"] - (s["dueEscrow"] or 0))
    fetch(conn, """
        UPDATE srm.loan_account SET interest_rate = coalesce(interest_rate, %s), maturity_date = coalesce(maturity_date, %s),
               payment_amount = coalesce(payment_amount, %s),
               escrow_amount = CASE WHEN escrow_amount = 0 THEN coalesce(%s, 0) ELSE escrow_amount END,
               lender = coalesce(lender, %s), account_last4 = coalesce(account_last4, %s),
               version = version + 1, updated_by = %s, updated_at = now()
         WHERE loan_id = %s""",
          (s["interestRate"], s["maturityDate"], pi, s["dueEscrow"], s["lender"], s["last4"], by, loan["id"]))


def remove_statement(conn, code, day):
    loan = _loan(conn, code)
    d = _date(day, "statement date")
    if not fetch(conn, "DELETE FROM srm.loan_statement WHERE loan_id = %s AND statement_date = %s RETURNING statement_id", (loan["id"], d)):
        raise LookupError("no statement of %s" % d)
    conn.commit()
    return detail(conn, code, {})


# ------------------------------------------------------------------------------------------------- forecast

def _paid_offset(activity):
    """How many days from its due date the loan's payments are made (the median; 0 with none)."""
    days = [(a["date"] - a["dueMonth"]).days for a in activity if a["kind"] == "payment" and a["dueMonth"]]
    return max(-20, min(20, int(statistics.median(days)))) if days else 0


def _schedule(balance, rate, payment, escrow, extra, first_due, offset):
    """Each payment from first_due until the balance is paid: its due and expected dates, principal, interest, extra
    principal, escrow and the balance after. Refused when the payment doesn't cover the interest."""
    rows, b, monthly = [], balance, rate / 100 / 12
    for k in range(720):
        if b <= 0.005:
            break
        interest = _cents(b * monthly)
        if payment <= interest:
            raise ValueError("the payment (%s) doesn't cover the month's interest (%s)" % (payment, interest))
        principal = _cents(min(payment - interest, b))
        more = _cents(min(extra, b - principal))
        b = _cents(b - principal - more)
        due = _add_months(first_due, k)
        rows.append({"due": due, "paid": due + dt.timedelta(days=offset), "payment": _cents(principal + interest + escrow),
                     "principal": principal, "interest": interest, "extra": more, "escrow": escrow, "balance": b})
    return rows


def _summary(rows):
    by_year = {}
    for r in rows:
        y = by_year.setdefault(r["paid"].year, {"year": r["paid"].year, "payments": 0, "principal": 0.0, "interest": 0.0,
                                                 "extra": 0.0, "escrow": 0.0, "endBalance": 0.0})
        y["payments"] += 1
        for k in ("principal", "interest", "extra", "escrow"):
            y[k] = _cents(y[k] + r[k])
        y["endBalance"] = r["balance"]
    return {"payoff": rows[-1]["due"] if rows else None, "months": len(rows),
            "interestLeft": _cents(sum(r["interest"] for r in rows)),
            "paidLeft": _cents(sum(r["principal"] + r["interest"] + r["extra"] for r in rows)),
            "byYear": list(by_year.values())}


def forecast(loan, statements, activity, extra=None):
    """The payments to payoff from the latest statement (else from the loan's terms), with a monthly extra principal
    (the loan's own unless one is given), and the same with none, to compare."""
    extra = loan["extraPrincipal"] if extra is None else max(0.0, float(extra))
    latest = statements[0] if statements else None
    rate = (latest or {}).get("interestRate") or loan["interestRate"]
    payment = loan["paymentAmount"]
    if latest and payment is None and latest["duePrincipal"] is not None and latest["dueInterest"] is not None:
        payment = _cents(latest["duePrincipal"] + latest["dueInterest"])
    escrow = loan["escrowAmount"] or (latest or {}).get("dueEscrow") or 0.0
    offset = _paid_offset(activity)
    if latest:
        balance, first_due, basis = latest["principalBalance"], latest["dueDate"] or _add_months(latest["statementDate"], 1), "statement"
        as_of = latest["statementDate"]
    elif loan["originalAmount"] and loan["firstPaymentDate"]:
        balance, first_due, basis, as_of = loan["originalAmount"], loan["firstPaymentDate"], "terms", None
    else:
        return {"problem": "Import a statement, or enter the amount borrowed and the first payment date, for a forecast."}
    if rate is None or not payment:
        return {"problem": "Import a statement, or enter the rate and the monthly payment, for a forecast."}
    try:
        rows = _schedule(balance, rate, payment, escrow, extra, first_due, offset)
        base = rows if extra == 0 else _schedule(balance, rate, payment, escrow, 0.0, first_due, offset)
    except ValueError as e:
        return {"problem": str(e)}
    if basis == "terms":
        # From the first payment: what is still to come, as of the next payment after today.
        today = dt.date.today()
        rows = [r for r in rows if r["due"] >= today]
        base = [r for r in base if r["due"] >= today]
    out = {"basis": basis, "asOf": as_of, "balance": balance, "rate": rate, "payment": payment, "escrow": escrow,
           "extra": extra, "paidDayOffset": offset, "maturityDate": (latest or {}).get("maturityDate") or loan["maturityDate"],
           "rows": rows}
    out.update(_summary(rows))
    b = _summary(base)
    out["withoutExtra"] = {"payoff": b["payoff"], "months": b["months"], "interestLeft": b["interestLeft"]}
    out["interestSaved"] = _cents(b["interestLeft"] - out["interestLeft"])
    return out


# ------------------------------------------------------------------------------------------------- tax years

def years(conn, loan, statements, activity, fc):
    """Each year's interest and principal: the statements' (the last statement's year to date plus the activity after
    it that year), the forecast's for the payments still to come, and the Form 1098 when entered."""
    forms = {r["year"]: r for r in _floats(fetch(conn, """
        SELECT tax_year AS year, interest_paid AS "interestPaid", points_paid AS "pointsPaid",
               mortgage_insurance AS "mortgageInsurance", property_tax AS "propertyTax", notes,
               updated_by AS "updatedBy", updated_at AS "updatedAt"
          FROM srm.loan_tax_year WHERE loan_id = %s""", (loan["id"],)))}
    rows = fc.get("rows") or []
    span = {a["date"].year for a in activity} | {s["statementDate"].year for s in statements} | set(forms)
    if rows:
        span |= {dt.date.today().year}
    out = []
    for y in sorted(span, reverse=True):
        mine = [s for s in statements if s["statementDate"].year == y]
        last = mine[0] if mine else None
        moved = [a for a in activity if a["date"].year == y]
        after = [a for a in moved if last is None or a["date"] > last["statementDate"]]
        if last and last["ytdInterest"] is not None:
            interest = _cents(last["ytdInterest"] + sum(a["interest"] for a in after))
            principal = _cents((last["ytdPrincipal"] or 0) + sum(a["principal"] for a in after))
        else:
            interest = _cents(sum(a["interest"] for a in moved))
            principal = _cents(sum(a["principal"] for a in moved))
        shown = _cents(sum(a["interest"] for a in moved))
        ahead = [r for r in rows if r["paid"].year == y and (fc.get("asOf") is None or r["paid"] > fc["asOf"])]
        f_interest = _cents(sum(r["interest"] for r in ahead))
        f_principal = _cents(sum(r["principal"] + r["extra"] for r in ahead))
        form = forms.get(y)
        estimate = _cents(interest + f_interest)
        out.append({"year": y, "statementsInterest": interest, "statementsPrincipal": principal,
                    "activityInterest": shown, "missingStatements": bool(last and abs(shown - interest) > 0.01),
                    "partial": last is None and bool(moved),
                    "forecastInterest": f_interest, "forecastPrincipal": f_principal, "forecastPayments": len(ahead),
                    "estimate": estimate, "form1098": form,
                    "interest": form["interestPaid"] if form else estimate,
                    "source": "Form 1098" if form else ("statements and forecast" if ahead and interest else
                                                        "forecast" if ahead else "statements")})
    return out


def save_tax_year(conn, code, year, body):
    loan = _loan(conn, code)
    y = int(year)
    vals = {k: _num(body.get(k) or 0, k) for k in ("interestPaid", "pointsPaid", "mortgageInsurance", "propertyTax")}
    if any(v < 0 for v in vals.values()):
        raise ValueError("a Form 1098 amount is never negative")
    fetch(conn, """
        INSERT INTO srm.loan_tax_year (loan_id, tax_year, interest_paid, points_paid, mortgage_insurance, property_tax, notes, updated_by)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (loan_id, tax_year) DO UPDATE SET interest_paid = excluded.interest_paid, points_paid = excluded.points_paid,
               mortgage_insurance = excluded.mortgage_insurance, property_tax = excluded.property_tax, notes = excluded.notes,
               updated_by = excluded.updated_by, updated_at = now()""",
          (loan["id"], y, vals["interestPaid"], vals["pointsPaid"], vals["mortgageInsurance"], vals["propertyTax"],
           (str(body.get("notes") or "").strip()[:2000] or None), _by(body)))
    conn.commit()
    return detail(conn, code, {})


def remove_tax_year(conn, code, year):
    loan = _loan(conn, code)
    fetch(conn, "DELETE FROM srm.loan_tax_year WHERE loan_id = %s AND tax_year = %s", (loan["id"], int(year)))
    conn.commit()
    return detail(conn, code, {})


def tax_summary(conn, year):
    """Year-End Tax's mortgage interest: each loan whose interest is deductible, with that year's interest."""
    out = []
    for l in _floats(fetch(conn, LOAN_SELECT + " WHERE interest_deductible ORDER BY lower(name)")):
        statements = _floats(fetch(conn, STATEMENT_SELECT, (l["id"],)))
        activity = _floats(fetch(conn, ACTIVITY_SELECT, (l["id"],)))
        fc = forecast(l, statements, activity)
        y = next((r for r in years(conn, l, statements, activity, fc) if r["year"] == year), None)
        if y is None:
            continue
        out.append(dict(y, code=l["code"], name=l["name"], kind=l["kind"], lender=l["lender"]))
    return out


# ------------------------------------------------------------------------------------------------- the loan

def _checks(conn, loan, activity):
    """The checks to the loan's target accounts (three years), each with the statement activity it matches: the same
    total within five days."""
    if not loan["paymentPayees"]:
        return []
    rows = _floats(fetch(conn, """
        SELECT b.txn_id AS id, b.txn_date AS date, -b.amount AS amount, p.name AS payee, a.code AS register, b.memo, b.status
          FROM srm.bank_txn b JOIN srm.payee p USING (payee_id) JOIN srm.bank_account a USING (bank_account_id)
         WHERE b.payee_id = ANY(%s) AND b.status <> 'void' AND b.txn_date >= %s
         ORDER BY b.txn_date DESC, b.txn_id DESC""", (loan["paymentPayees"], dt.date.today() - dt.timedelta(days=3 * 366))))
    by_day = {}
    for a in activity:
        by_day[a["date"]] = _cents(by_day.get(a["date"], 0) + a["total"])
    used = set()
    for c in rows:
        hit = next((d for d in sorted(by_day, key=lambda d: abs((d - c["date"]).days))
                    if d not in used and abs((d - c["date"]).days) <= 5 and abs(by_day[d] - c["amount"]) < 0.01), None)
        c["onStatement"] = hit
        if hit:
            used.add(hit)
    return rows


def detail(conn, code, q):
    loan = _loan(conn, code)
    statements = _floats(fetch(conn, STATEMENT_SELECT, (loan["id"],)))
    activity = _floats(fetch(conn, ACTIVITY_SELECT, (loan["id"],)))
    extra = q.get("extra")
    fc = forecast(loan, statements, activity, None if extra in (None, "") else float(extra))
    payees = fetch(conn, "SELECT payee_id AS id, name FROM srm.payee WHERE payee_id = ANY(%s) ORDER BY lower(name)",
                   (loan["paymentPayees"] or [],))
    return {"loan": dict(loan, folder=_folder(loan), payees=payees), "statements": statements, "activity": activity,
            "checks": _checks(conn, loan, activity), "forecast": fc, "years": years(conn, loan, statements, activity, fc)}


def route(conn, method, parts, body, q):
    if parts == ["loans"] and method == "GET":
        return loans(conn)
    if len(parts) == 2:
        if method == "GET":
            return detail(conn, parts[1], q)
        if method == "PUT":
            return save_loan(conn, parts[1], body)
        if method == "DELETE":
            return remove_loan(conn, parts[1], q)
    if len(parts) == 3 and parts[2] == "statements" and method == "POST":
        return import_statements(conn, parts[1], body)
    if len(parts) == 4 and parts[2] == "statements" and method == "DELETE":
        return remove_statement(conn, parts[1], parts[3])
    if len(parts) == 4 and parts[2] == "tax-years":
        if method == "PUT":
            return save_tax_year(conn, parts[1], parts[3], body)
        if method == "DELETE":
            return remove_tax_year(conn, parts[1], parts[3])
    return None
