"""Household spending attribution for the accounts service (V037): MxAcctMGR's Reporting ▸ Spending Analysis.

    GET    /spending/setup                         the family, the spending categories (with their CPI series), the
                                                   rules, the lifecycle triggers, and the expense and target accounts
                                                   rules can be set on
    PUT    /spending/members/<id>                  a family member, created (id 0) or changed {version, name, relation,
                                                   birthYear, birthMonth, notes, active, by}
    DELETE /spending/members/<id>                  take one off (their rules and tags keep no member)
    PUT    /spending/categories/<code>             a category's {cpiSeries, assumedInflation}
    PUT    /spending/rules                         an expense account's or target account's rule {expenseAccountId |
                                                   payeeId, category, driver, memberId, notes, by}; nothing set removes it
    PUT    /spending/triggers/<id>                 a lifecycle trigger, created (id 0) or changed {name, category, kind,
                                                   ageFrom, ageTo, everyYears, annualCost, notes, active, by}
    DELETE /spending/triggers/<id>                 take one off
    PUT    /spending/tags/<source>/<entryId>       one entry's own {category, driver, memberId, event, notes, by}
                                                   (source bank, card or ledger); nothing set removes the tag
    GET    /spending/analysis?start=&end=&priorStart=&priorEnd=
                                                   every spending dollar of both periods (srm.v_spending_entry), each
                                                   category's inflation between them (CPI, else its assumption) and
                                                   the dates each register covers

Every setup change answers with the setup. Drivers: inflation, family_growth, new_activity, lifecycle, preference,
one_time.
"""

import datetime as dt

from bank import fetch, _date, _num, Conflict

DRIVERS = ("inflation", "family_growth", "new_activity", "lifecycle", "preference", "one_time")
KINDS = ("recurring", "replacement", "peak", "transition")
SOURCES = {"bank": "bank_txn_id", "card": "card_txn_id", "ledger": "expense_entry_id"}


def _by(body):
    return str(body.get("by") or "MxAcctMGR")[:80]


def _text(body, key, n=200):
    return (str(body.get(key) or "")).strip()[:n] or None


def _opt_int(body, key):
    v = body.get(key)
    if v in (None, ""):
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        raise ValueError("%s must be a whole number" % key)


def _category(conn, body, key="category", required=False):
    code = (body.get(key) or "").strip().upper() or None
    if code and not fetch(conn, "SELECT 1 FROM srm.spending_category WHERE code = %s", (code,)):
        raise ValueError("no spending category %s" % code)
    if required and not code:
        raise ValueError("%s is required" % key)
    return code


def _driver(body):
    d = body.get("driver") or None
    if d and d not in DRIVERS:
        raise ValueError("driver must be one of " + ", ".join(DRIVERS))
    return d


# ------------------------------------------------------------------------------------------------------------ setup

def setup(conn):
    members = fetch(conn, """
        SELECT member_id AS id, name, relation, birth_year AS "birthYear", birth_month AS "birthMonth", notes, active,
               version FROM srm.household_member ORDER BY relation DESC, birth_year, name""")
    categories = fetch(conn, """
        SELECT c.code, c.name, c.cpi_series AS "cpiSeries", s.name AS "cpiName",
               c.assumed_inflation AS "assumedInflation", c.sort_order AS "sortOrder",
               (SELECT max(v.obs_date) FROM srm.market_series_value v WHERE v.series_code = c.cpi_series) AS "cpiThrough"
          FROM srm.spending_category c LEFT JOIN srm.market_series s ON s.series_code = c.cpi_series
         ORDER BY c.sort_order""")
    rules = fetch(conn, """
        SELECT r.rule_id AS id, r.expense_account_id AS "expenseAccountId", e.name AS "expenseAccount",
               r.payee_id AS "payeeId", p.name AS payee, r.category_code AS category, r.driver,
               r.member_id AS "memberId", r.notes, r.updated_by AS "updatedBy", r.updated_at AS "updatedAt"
          FROM srm.spending_rule r
          LEFT JOIN srm.expense_account e USING (expense_account_id)
          LEFT JOIN srm.payee p USING (payee_id)
         ORDER BY r.payee_id IS NOT NULL, coalesce(e.sort_order, 0), lower(coalesce(e.name, p.name))""")
    triggers = fetch(conn, """
        SELECT trigger_id AS id, name, category_code AS category, kind, age_from AS "ageFrom", age_to AS "ageTo",
               every_years AS "everyYears", annual_cost AS "annualCost", notes, active
          FROM srm.lifecycle_trigger ORDER BY sort_order, age_from, name""")
    accounts = fetch(conn, """
        SELECT expense_account_id AS id, name FROM srm.expense_account WHERE kind = 'expense' ORDER BY sort_order, name""")
    payees = fetch(conn, """
        SELECT payee_id AS id, name, expense_account_id AS "expenseAccountId" FROM srm.payee
         WHERE status <> 'closed' ORDER BY lower(name)""")
    series = fetch(conn, """
        SELECT series_code AS code, name FROM srm.market_series WHERE family = 'INFLATION' ORDER BY sort_order""")
    return {"members": members, "categories": categories, "rules": rules, "triggers": triggers,
            "expenseAccounts": accounts, "payees": payees, "cpiSeries": series, "drivers": list(DRIVERS)}


def save_member(conn, mid, body):
    mid = int(mid)
    name = _text(body, "name", 80)
    if not name:
        raise ValueError("name is required")
    relation = body.get("relation") or "child"
    if relation not in ("child", "adult"):
        raise ValueError("relation must be child or adult")
    year = _opt_int(body, "birthYear")
    if not year or not 1900 <= year <= 2100:
        raise ValueError("birthYear is required (yyyy)")
    month = _opt_int(body, "birthMonth")
    if month is not None and not 1 <= month <= 12:
        raise ValueError("birthMonth must be 1–12")
    if fetch(conn, "SELECT 1 FROM srm.household_member WHERE lower(name) = lower(%s) AND member_id <> %s", (name, mid)):
        raise Conflict("there is already a family member named %s" % name)
    values = (name, relation, year, month, _text(body, "notes", 1000), bool(body.get("active", True)), _by(body))
    if mid == 0:
        fetch(conn, """INSERT INTO srm.household_member (name, relation, birth_year, birth_month, notes, active, updated_by)
                       VALUES (%s, %s, %s, %s, %s, %s, %s)""", values)
    else:
        cur = fetch(conn, "SELECT version FROM srm.household_member WHERE member_id = %s FOR UPDATE", (mid,))
        if not cur:
            raise LookupError("no family member %s" % mid)
        if "version" in body and int(body["version"]) != cur[0]["version"]:
            conn.rollback()
            raise Conflict("someone changed this family member since you opened it", version=cur[0]["version"])
        fetch(conn, """UPDATE srm.household_member SET name = %s, relation = %s, birth_year = %s, birth_month = %s,
                              notes = %s, active = %s, updated_by = %s, version = version + 1, updated_at = now()
                        WHERE member_id = %s""", values + (mid,))
    conn.commit()
    return setup(conn)


def delete_member(conn, mid):
    fetch(conn, "DELETE FROM srm.household_member WHERE member_id = %s", (int(mid),))
    conn.commit()
    return setup(conn)


def save_category(conn, code, body):
    code = code.upper()
    if not fetch(conn, "SELECT 1 FROM srm.spending_category WHERE code = %s", (code,)):
        raise LookupError("no spending category %s" % code)
    series = (body.get("cpiSeries") or "").strip().upper() or None
    if series and not fetch(conn, "SELECT 1 FROM srm.market_series WHERE series_code = %s", (series,)):
        raise ValueError("no market series %s" % series)
    rate = float(body.get("assumedInflation") if body.get("assumedInflation") not in (None, "") else 0.03)
    if not -0.5 < rate < 0.5:
        raise ValueError("assumedInflation is a fraction a year (0.03 for 3%)")
    fetch(conn, "UPDATE srm.spending_category SET cpi_series = %s, assumed_inflation = %s WHERE code = %s",
          (series, rate, code))
    conn.commit()
    return setup(conn)


def save_rule(conn, body):
    account, payee = _opt_int(body, "expenseAccountId"), _opt_int(body, "payeeId")
    if (account is None) == (payee is None):
        raise ValueError("a rule is for an expenseAccountId or a payeeId")
    key, value = ("expense_account_id", account) if account is not None else ("payee_id", payee)
    category, driver, member = _category(conn, body), _driver(body), _opt_int(body, "memberId")
    notes = _text(body, "notes", 1000)
    if not (category or driver or member or notes):
        fetch(conn, "DELETE FROM srm.spending_rule WHERE %s = %%s" % key, (value,))
    else:
        fetch(conn, """INSERT INTO srm.spending_rule (%s, category_code, driver, member_id, notes, updated_by)
                       VALUES (%%s, %%s, %%s, %%s, %%s, %%s)
                       ON CONFLICT (%s) DO UPDATE SET category_code = excluded.category_code, driver = excluded.driver,
                              member_id = excluded.member_id, notes = excluded.notes,
                              updated_by = excluded.updated_by, updated_at = now()""" % (key, key),
              (value, category, driver, member, notes, _by(body)))
    conn.commit()
    return setup(conn)


def save_trigger(conn, tid, body):
    tid = int(tid)
    name = _text(body, "name", 120)
    if not name:
        raise ValueError("name is required")
    kind = body.get("kind") or "recurring"
    if kind not in KINDS:
        raise ValueError("kind must be one of " + ", ".join(KINDS))
    a, b = _opt_int(body, "ageFrom"), _opt_int(body, "ageTo")
    if a is None or b is None or not 0 <= a <= b <= 30:
        raise ValueError("ageFrom and ageTo are ages 0–30, ageFrom first")
    every = _opt_int(body, "everyYears")
    if every is not None and not 1 <= every <= 10:
        raise ValueError("everyYears must be 1–10")
    values = (name, _category(conn, body, required=True), kind, a, b, every, _num(body.get("annualCost") or 0, "annualCost"),
              _text(body, "notes", 1000), bool(body.get("active", True)), _by(body))
    if tid == 0:
        fetch(conn, """INSERT INTO srm.lifecycle_trigger (name, category_code, kind, age_from, age_to, every_years,
                              annual_cost, notes, active, updated_by, sort_order)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                               (SELECT coalesce(max(sort_order), 0) + 1 FROM srm.lifecycle_trigger))""", values)
    else:
        if not fetch(conn, """UPDATE srm.lifecycle_trigger SET name = %s, category_code = %s, kind = %s, age_from = %s,
                                     age_to = %s, every_years = %s, annual_cost = %s, notes = %s, active = %s,
                                     updated_by = %s, updated_at = now()
                               WHERE trigger_id = %s RETURNING trigger_id""", values + (tid,)):
            raise LookupError("no lifecycle trigger %s" % tid)
    conn.commit()
    return setup(conn)


def delete_trigger(conn, tid):
    fetch(conn, "DELETE FROM srm.lifecycle_trigger WHERE trigger_id = %s", (int(tid),))
    conn.commit()
    return setup(conn)


def save_tag(conn, source, entry_id, body):
    column = SOURCES.get(source)
    if not column:
        raise ValueError("source must be bank, card or ledger")
    entry_id = int(entry_id)
    category, driver, member = _category(conn, body), _driver(body), _opt_int(body, "memberId")
    event, notes = _text(body, "event", 120), _text(body, "notes", 1000)
    if not (category or driver or member or event or notes):
        fetch(conn, "DELETE FROM srm.spending_tag WHERE %s = %%s" % column, (entry_id,))
    else:
        fetch(conn, """INSERT INTO srm.spending_tag (%s, category_code, driver, member_id, event, notes, updated_by)
                       VALUES (%%s, %%s, %%s, %%s, %%s, %%s, %%s)
                       ON CONFLICT (%s) DO UPDATE SET category_code = excluded.category_code, driver = excluded.driver,
                              member_id = excluded.member_id, event = excluded.event, notes = excluded.notes,
                              updated_by = excluded.updated_by, updated_at = now()""" % (column, column),
              (entry_id, category, driver, member, event, notes, _by(body)))
    conn.commit()
    rows = fetch(conn, ENTRY_SQL + " WHERE source = %s AND entry_id = %s", (source, entry_id))
    return {"entry": rows[0] if rows else None}


# ------------------------------------------------------------------------------------------------------------ analysis

ENTRY_SQL = """
    SELECT source, entry_id AS "entryId", txn_date AS date, register, payee_id AS "payeeId", payee, description,
           expense_account_id AS "expenseAccountId", expense_account AS "expenseAccount", amount,
           category_code AS category, category_from AS "categoryFrom", driver, driver_from AS "driverFrom",
           member_id AS "memberId", event, notes, tagged
      FROM srm.v_spending_entry"""


def _year_back(d):
    try:
        return d.replace(year=d.year - 1)
    except ValueError:      # 29 February
        return d.replace(year=d.year - 1, day=28)


def inflation(conn, start, end):
    """Each category's price change from a year before the period to the period: the CPI's months in it over the same
    months a year earlier, else the category's assumption."""
    out = []
    for c in fetch(conn, "SELECT code, cpi_series, assumed_inflation FROM srm.spending_category ORDER BY sort_order"):
        row = {"category": c["code"], "series": c["cpi_series"], "assumed": float(c["assumed_inflation"]),
               "rate": float(c["assumed_inflation"]), "basis": "assumed", "months": 0, "through": None}
        if c["cpi_series"]:
            pairs = fetch(conn, """
                SELECT v.obs_date, v.value AS now, p.value AS before
                  FROM srm.market_series_value v
                  JOIN srm.market_series_value p ON p.series_code = v.series_code
                                                AND p.obs_date = (v.obs_date - interval '1 year')::date
                 WHERE v.series_code = %s AND v.obs_date BETWEEN date_trunc('month', %s::date) AND %s
                 ORDER BY v.obs_date""", (c["cpi_series"], start, end))
            if pairs:
                row.update(rate=float(sum(p["now"] for p in pairs) / sum(p["before"] for p in pairs) - 1),
                           basis="CPI", months=len(pairs), through=pairs[-1]["obs_date"])
        out.append(row)
    return out


def analysis(conn, q):
    end = _date(q.get("end") or dt.date.today(), "end")
    start = _date(q.get("start") or end.replace(month=1, day=1), "start")
    prior_end = _date(q.get("priorEnd") or _year_back(end), "priorEnd")
    prior_start = _date(q.get("priorStart") or _year_back(start), "priorStart")
    if start > end or prior_start > prior_end:
        raise ValueError("a period's start must be on or before its end")
    entries = fetch(conn, ENTRY_SQL + """ WHERE txn_date BETWEEN %s AND %s OR txn_date BETWEEN %s AND %s
                                          ORDER BY txn_date, source, entry_id""", (prior_start, prior_end, start, end))
    coverage = fetch(conn, """
        SELECT source, register, min(txn_date) AS first, max(txn_date) AS last, count(*) AS entries
          FROM srm.v_spending_entry GROUP BY source, register ORDER BY source, register""")
    return {"start": start, "end": end, "priorStart": prior_start, "priorEnd": prior_end, "entries": entries,
            "inflation": inflation(conn, start, end), "coverage": coverage}


def route(conn, method, parts, body, q):
    """The spending endpoints' answer, or None when the path isn't one of them."""
    if parts == ["spending", "setup"] and method == "GET":
        return setup(conn)
    if parts == ["spending", "analysis"] and method == "GET":
        return analysis(conn, q)
    if parts == ["spending", "rules"] and method == "PUT":
        return save_rule(conn, body)
    if len(parts) == 3 and parts[1] == "members":
        if method == "PUT":
            return save_member(conn, parts[2], body)
        if method == "DELETE":
            return delete_member(conn, parts[2])
    if len(parts) == 3 and parts[1] == "categories" and method == "PUT":
        return save_category(conn, parts[2], body)
    if len(parts) == 3 and parts[1] == "triggers":
        if method == "PUT":
            return save_trigger(conn, parts[2], body)
        if method == "DELETE":
            return delete_trigger(conn, parts[2])
    if len(parts) == 4 and parts[1] == "tags" and method == "PUT":
        return save_tag(conn, parts[2], parts[3], body)
    return None
