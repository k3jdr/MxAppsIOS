"""Household spending attribution for the accounts service (V037): MxAcctMGR's Reporting ▸ Spending Analysis.

    GET    /spending/setup                         the family, the spending categories (with their CPI series), the
                                                   rules, the lifecycle triggers, and the expense and target accounts
                                                   rules can be set on
    PUT    /spending/members/<id>                  a family member, created (id 0) or changed {version, name, relation,
                                                   birthYear, birthMonth, notes, active, by}
    DELETE /spending/members/<id>                  take one off (their rules and tags keep no member)
    POST   /spending/categories                    add a category {name, code (else made from the name), description,
                                                   cpiSeries, assumedInflation, by}; it goes last, before Other
    PUT    /spending/categories/<code>             a category's {name, description, cpiSeries, assumedInflation, by}:
                                                   only the fields sent change
    GET    /spending/categories/<code>/usage       its rules, tags and lifecycle triggers, and the entries now in it
    DELETE /spending/categories/<code>?moveTo=&by= take one off (V047): its rules, tags, lifecycle triggers and notes
                                                   move to moveTo first (required with triggers; without it rules and
                                                   tags lose their category)
    PUT    /spending/category-order                {codes: [...]}: every category, in the order shown
    POST   /spending/drivers                       add a driver (V047) {title, code (else made from the title), help,
                                                   effect, by}; effect inflation, usage, lifecycle, behavior, one_time
                                                   or taxes: what its growth beyond inflation counts as
    PUT    /spending/drivers/<code>                a driver's {title, help, effect, by}: only the fields sent change
    GET    /spending/drivers/<code>/usage          its rules and tags, and the entries it is now the driver of
    DELETE /spending/drivers/<code>?moveTo=&by=    take one off: its rules and tags move to moveTo first (none: they
                                                   lose their driver)
    PUT    /spending/driver-order                  {codes: [...]}: every driver, in the order shown
    PUT    /spending/rules                         an expense account's, target account's or statement text's rule
                                                   {expenseAccountId | payeeId | pattern, id (to change a statement
                                                   text), category, driver, memberId, notes, by}; nothing set removes it
    PUT    /spending/rules/<id>/link               a statement text rule's link (V043) {address, text, hoverText,
                                                   hoverRtf, title, by}, as a target account's (PUT /payees/<id>/link)
    DELETE /spending/rules/<id>/link               take it off
    PUT    /spending/triggers/<id>                 a lifecycle trigger, created (id 0) or changed {name, category, kind,
                                                   ageFrom, ageTo, everyYears, annualCost, notes, active, by}
    DELETE /spending/triggers/<id>                 take one off
    PUT    /spending/tags/<source>/<entryId>       one entry's own {category, driver, memberId, event, notes, by}
                                                   (source bank, card or ledger); nothing set removes the tag. With
                                                   merge: true only the fields sent change, the rest of its tag stays
    GET    /spending/analysis?start=&end=&priorStart=&priorEnd=
                                                   every spending dollar of both periods (srm.v_spending_entry) from
                                                   the registers included (V038), each category's inflation between
                                                   them (CPI, else its assumption) and the dates each register covers;
                                                   an Amazon charge or credit matched to its order (V046) carries
                                                   amazonOrders and amazonItems [{name, asin, quantity, amount,
                                                   orderId, orderedAt}] — what was bought
    GET    /spending/sources?start=&end=&priorStart=&priorEnd=
                                                   the spending sources — each checking account, credit card and
                                                   cash ledger: included or not, where its data comes from (drop
                                                   folders, the downloads there, the line and register tables), its
                                                   last import, its entries' dates and its spending in both periods —
                                                   Amazon's order export (amazon: its drop folders and downloads, the
                                                   orders it holds, its last load, how many Amazon charges it matched,
                                                   those it didn't and the shipments no charge paid) —
                                                   and every SRM table and view the analysis reads, with its rows,
                                                   newest data and last change
    PUT    /spending/sources/<source>/<code>       include or leave out a register {included, by} (source bank, card
                                                   or ledger); answers with the sources
    GET    /spending/transfers?start=&end=&priorStart=&priorEnd=
                                                   target accounts left out of the analysis because their category is a
                                                   transfer or income account (what moved each period), the ones that
                                                   look like they should be (each with why: a card is paid with it, a
                                                   cash ledger is funded from it, its name), and the accounts to file
                                                   them under
    PUT    /spending/transfers/<payeeId>           file a target account and its checks and card entries under
                                                   {expenseAccountId, by}: a transfer or income account leaves them out,
                                                   an expense account puts them back; answers as GET, with `refiled`
    GET    /spending/sources/<source>/<code>/links what disconnecting it undoes (its links to the other sources) and
                                                   what stays with its register
    POST   /spending/sources/<source>/<code>/disconnect
                                                   take it out of Spending Analysis (V049) {by}: its register stays in
                                                   the security master; its links to the other sources (card payments
                                                   to checks, cash-ledger entries to charges and checks) are undone and
                                                   kept, and the payment and funding matches leave it alone
    POST   /spending/sources/<source>/<code>/reconnect
                                                   bring it back {by}: the links kept are put back where both sides are
                                                   still there and free; nothing is read from a download
    POST   /spending/amazon/load                   read Amazon's order export again (srm-loader amazon-orders); with
                                                   {filename, data (base64)}, first save that export — the zip as
                                                   downloaded or a Retail.OrderHistory CSV — in its drop folder;
                                                   answers with the sources and the load {status, message, file}
    GET    /spending/amazon/known?ids=A,B          which of these Amazon orders are kept, with items, and where from
    POST   /spending/amazon/attach                 MxAcctMGR's Amazon Order Lookup: {charges: [{source, entryId,
                                                   orderIds}], orders: [{orderId, orderedAt, total, payment, items:
                                                   [{name, asin, quantity, price}]}], by} — keeps each order its page
                                                   gave (an order read from the export stays as it is) and attaches
                                                   the orders Amazon's Transactions list names to each charge, in
                                                   place of what it had; answers with the entries
    POST   /spending/amazon/unlink/<source>/<id>   take the orders off a charge for good (the export doesn't match it
                                                   again); answers with the entry
    GET    /spending/feedback?author=&status=      notes on the page from its read-only web page (V039), newest first
    POST   /spending/feedback                      add one {author, kind, tab, section, category, entrySource, entryId,
                                                   suggestion, message, context}
    PUT    /spending/feedback/<id>                 answer one {status, reply, by}
    POST   /spending/feedback/<id>/undo            undo a change made on the family page (V041) {by}
    PUT    /spending/change/entry/<source>/<id>    the family page's change to an entry {author, category, driver}:
                                                   the entry's tag, and a 'change' note with what it was before
    PUT    /spending/change/trigger/<id>           the family page's change to a lifecycle trigger {author, category,
                                                   kind}, and a 'change' note
    POST   /spending/expense-account               file card and check entries under another expense account {entries:
                                                   [{source, id}], expenseAccountId, fileFuture, targetName, by}: with
                                                   fileFuture, their target account (or a new one named targetName,
                                                   with their statement names) is filed under it too, so future
                                                   downloads land there; answers with the setup and how many changed
    GET    /spending/overlaps                      Admin: cash-ledger entries not linked to a card charge or check that
                                                   match one (same amount within a week, the charge or check linked to
                                                   no entry): counted twice while the ledger is included
    GET    /spending/tax?year=                     Year-End Tax (V040): the tax items, every payment of theirs that
                                                   counts toward the year (with its tax year and quarter), and the
                                                   year's summary — expenses paid and deductible, estimated payments
                                                   by jurisdiction and quarter, real estate taxes, refunds, savings
    PUT    /spending/tax/items/<id>                a tax item, created (id 0) or changed {payeeId | ledgerLineId |
                                                   namePattern, label, section, taxCategory, jurisdiction,
                                                   deductibleShare, quarterly, notes, active, by}
    DELETE /spending/tax/items/<id>                take one off
    PUT    /spending/tax/assign/<source>/<entryId> move a payment to {taxYear, quarter, note}; no taxYear undoes it

Every setup change answers with the setup. The drivers are srm.spending_driver's (V047), with the effect each counts
as; the setup lists them as {code, title, help, effect, sortOrder}.
"""

import base64
import datetime as dt
import hashlib
import json
import os
import re
import urllib.request

from bank import fetch, nest_link, _date, _num, Conflict

# The attribution formula's terms, which a driver's growth beyond inflation counts toward (srm.spending_driver.effect).
EFFECTS = ("inflation", "usage", "lifecycle", "behavior", "one_time", "taxes")
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


def _driver(conn, body):
    d = body.get("driver") or None
    if d and not fetch(conn, "SELECT 1 FROM srm.spending_driver WHERE code = %s", (d,)):
        raise ValueError("no spending driver %s" % d)
    return d


def _drivers(conn):
    return fetch(conn, """SELECT code, title, help, effect, sort_order AS "sortOrder" FROM srm.spending_driver
                           ORDER BY sort_order, lower(title)""")


# ------------------------------------------------------------------------------------------------------------ setup

def setup(conn, details=False):
    """The family, categories, rules, triggers and what rules can be set on. With details (MxAcctMGR's, not the
    family page's login): each target account's bank, last four digits, logon page, nickname, notes and link
    (srm.payee_link, V032), and each statement text rule's link (V043)."""
    members = fetch(conn, """
        SELECT member_id AS id, name, relation, birth_year AS "birthYear", birth_month AS "birthMonth", notes, active,
               version FROM srm.household_member ORDER BY relation DESC, birth_year, name""")
    categories = fetch(conn, """
        SELECT c.code, c.name, c.description, c.cpi_series AS "cpiSeries", s.name AS "cpiName",
               c.assumed_inflation AS "assumedInflation", c.sort_order AS "sortOrder",
               (SELECT max(v.obs_date) FROM srm.market_series_value v WHERE v.series_code = c.cpi_series) AS "cpiThrough"
          FROM srm.spending_category c LEFT JOIN srm.market_series s ON s.series_code = c.cpi_series
         ORDER BY c.sort_order""")
    link_columns, link_join = ("", "")
    if details:
        link_columns = ', rl.address AS "linkAddress", rl.display_text AS "linkText", rl.hover_rtf AS "linkTip", ' \
                       'rl.link_title AS "linkTitle"'
        link_join = " LEFT JOIN srm.spending_rule_link rl USING (rule_id)"
    rules = fetch(conn, """
        SELECT r.rule_id AS id, r.expense_account_id AS "expenseAccountId", e.name AS "expenseAccount",
               r.payee_id AS "payeeId", p.name AS payee, r.pattern, r.category_code AS category, r.driver,
               r.member_id AS "memberId", r.notes, r.updated_by AS "updatedBy", r.updated_at AS "updatedAt"%s
          FROM srm.spending_rule r
          LEFT JOIN srm.expense_account e USING (expense_account_id)
          LEFT JOIN srm.payee p USING (payee_id)%s
         ORDER BY r.payee_id IS NOT NULL, r.pattern IS NOT NULL, coalesce(e.sort_order, 0),
                  lower(coalesce(e.name, p.name, r.pattern))""" % (link_columns, link_join))
    if details:
        rules = [nest_link(r, "link") for r in rules]
    triggers = fetch(conn, """
        SELECT trigger_id AS id, name, category_code AS category, kind, age_from AS "ageFrom", age_to AS "ageTo",
               every_years AS "everyYears", annual_cost AS "annualCost", notes, active
          FROM srm.lifecycle_trigger ORDER BY sort_order, age_from, name""")
    accounts = fetch(conn, """
        SELECT expense_account_id AS id, name, description FROM srm.expense_account WHERE kind = 'expense'
         ORDER BY sort_order, name""")
    if details:
        payees = [nest_link(p, "link") for p in fetch(conn, """
            SELECT p.payee_id AS id, p.name, p.expense_account_id AS "expenseAccountId", p.institution,
                   p.account_last4 AS last4, p.logon_url AS "logonUrl", p.nickname, p.notes,
                   pl.address AS "linkAddress", pl.display_text AS "linkText", pl.hover_rtf AS "linkTip",
                   pl.link_title AS "linkTitle"
              FROM srm.payee p LEFT JOIN srm.payee_link pl USING (payee_id)
             WHERE p.status <> 'closed' ORDER BY lower(p.name)""")]
    else:
        payees = fetch(conn, """
            SELECT payee_id AS id, name, expense_account_id AS "expenseAccountId" FROM srm.payee
             WHERE status <> 'closed' ORDER BY lower(name)""")
    series = fetch(conn, """
        SELECT series_code AS code, name FROM srm.market_series WHERE family = 'INFLATION' ORDER BY sort_order""")
    return {"members": members, "categories": categories, "rules": rules, "triggers": triggers,
            "expenseAccounts": accounts, "payees": payees, "cpiSeries": series, "drivers": _drivers(conn)}


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
    return setup(conn, details=True)


def delete_member(conn, mid):
    fetch(conn, "DELETE FROM srm.household_member WHERE member_id = %s", (int(mid),))
    conn.commit()
    return setup(conn, details=True)


# ------------------------------------------------------------------------------------------------ categories and drivers
# Both kept in the security master (V047) and changed on Spending Analysis ▸ Admin. A category's code and a driver's
# are what rules, tags and lifecycle triggers store: made from the name when added, and never changed after.

def _new_code(body, name, upper):
    """The code a new category (A_Z) or driver (a_z) is stored by: the one sent, else its name's letters."""
    code = (body.get("code") or "").strip() or re.sub(r"[^A-Za-z]+", "_", name).strip("_")
    code = code.upper() if upper else code.lower()
    if not re.fullmatch(r"[A-Z_]+" if upper else r"[a-z_]+", code):
        raise ValueError("code is letters and _ only")
    return code


def _series(conn, body):
    series = (body.get("cpiSeries") or "").strip().upper() or None
    if series and not fetch(conn, "SELECT 1 FROM srm.market_series WHERE series_code = %s", (series,)):
        raise ValueError("no market series %s" % series)
    return series


def _rate(body):
    rate = float(body.get("assumedInflation") if body.get("assumedInflation") not in (None, "") else 0.03)
    if not -0.5 < rate < 0.5:
        raise ValueError("assumedInflation is a fraction a year (0.03 for 3%)")
    return rate


def _effect(body):
    effect = body.get("effect") or ""
    if effect not in EFFECTS:
        raise ValueError("effect must be one of " + ", ".join(EFFECTS))
    return effect


def _unique(conn, table, column, value, code, what):
    """No other category (driver) has this name, ignoring case; code: the one being changed (None: one being added)."""
    if fetch(conn, "SELECT 1 FROM %s WHERE lower(%s) = lower(%%s) AND code IS DISTINCT FROM %%s" % (table, column),
             (value, code)):
        raise Conflict("there is already a %s named %s" % (what, value))


def add_category(conn, body):
    name = _text(body, "name", 60)
    if not name:
        raise ValueError("name is required")
    _unique(conn, "srm.spending_category", "name", name, None, "category")
    code = _new_code(body, name, upper=True)
    if fetch(conn, "SELECT 1 FROM srm.spending_category WHERE code = %s", (code,)):
        raise Conflict("there is already a category coded %s: give this one a code of its own" % code)
    # Last, but before Other when Other is last.
    last = fetch(conn, "SELECT code, sort_order FROM srm.spending_category ORDER BY sort_order DESC LIMIT 1")
    sort = (last[0]["sort_order"] if last else 0) + 1
    if last and last[0]["code"] == "OTHER":
        sort -= 1
        fetch(conn, "UPDATE srm.spending_category SET sort_order = sort_order + 1 WHERE code = 'OTHER'")
    fetch(conn, """INSERT INTO srm.spending_category (code, name, description, cpi_series, assumed_inflation, sort_order,
                                                      updated_by)
                   VALUES (%s, %s, %s, %s, %s, %s, %s)""",
          (code, name, _text(body, "description", 400), _series(conn, body), _rate(body), sort, _by(body)))
    conn.commit()
    return setup(conn, details=True)


def save_category(conn, code, body):
    """A category's name, description, CPI series and assumed inflation: only the fields sent change (Family &
    Lifecycle sends the series and the assumption)."""
    code = code.upper()
    if not fetch(conn, "SELECT 1 FROM srm.spending_category WHERE code = %s", (code,)):
        raise LookupError("no spending category %s" % code)
    sets, params = [], []
    if "name" in body:
        name = _text(body, "name", 60)
        if not name:
            raise ValueError("name is required")
        _unique(conn, "srm.spending_category", "name", name, code, "category")
        sets.append("name = %s"); params.append(name)
    if "description" in body:
        sets.append("description = %s"); params.append(_text(body, "description", 400))
    if "cpiSeries" in body:
        sets.append("cpi_series = %s"); params.append(_series(conn, body))
    if "assumedInflation" in body:
        sets.append("assumed_inflation = %s"); params.append(_rate(body))
    if sets:
        fetch(conn, "UPDATE srm.spending_category SET %s, updated_by = %%s, updated_at = now() WHERE code = %%s"
              % ", ".join(sets), params + [_by(body), code])
    conn.commit()
    return setup(conn, details=True)


# What stores a category, and the column that does.
CATEGORY_USES = (("rules", "srm.spending_rule"), ("tags", "srm.spending_tag"), ("lifecycle triggers", "srm.lifecycle_trigger"))
DRIVER_USES = (("rules", "srm.spending_rule"), ("tags", "srm.spending_tag"))


def category_usage(conn, code):
    code = code.upper()
    rows = fetch(conn, "SELECT name FROM srm.spending_category WHERE code = %s", (code,))
    if not rows:
        raise LookupError("no spending category %s" % code)
    uses = {what: fetch(conn, "SELECT count(*) AS n FROM %s WHERE category_code = %%s" % table, (code,))[0]["n"]
            for what, table in CATEGORY_USES}
    now = fetch(conn, "SELECT count(*) AS n, coalesce(sum(amount), 0) AS amount FROM srm.v_spending_entry "
                      "WHERE category_code = %s", (code,))[0]
    return {"code": code, "name": rows[0]["name"], "uses": uses, "inUse": sum(uses.values()), "entries": now["n"],
            "amount": float(now["amount"])}


def driver_usage(conn, code):
    rows = fetch(conn, "SELECT title FROM srm.spending_driver WHERE code = %s", (code,))
    if not rows:
        raise LookupError("no spending driver %s" % code)
    uses = {what: fetch(conn, "SELECT count(*) AS n FROM %s WHERE driver = %%s" % table, (code,))[0]["n"]
            for what, table in DRIVER_USES}
    now = fetch(conn, "SELECT count(*) AS n, coalesce(sum(amount), 0) AS amount FROM srm.v_spending_entry "
                      "WHERE driver = %s", (code,))[0]
    return {"code": code, "name": rows[0]["title"], "uses": uses, "inUse": sum(uses.values()), "entries": now["n"],
            "amount": float(now["amount"])}


def _drop_empty(conn):
    """Rules and tags that set nothing once a category or driver came off them (a rule with a link keeps it)."""
    fetch(conn, """DELETE FROM srm.spending_tag WHERE category_code IS NULL AND driver IS NULL AND member_id IS NULL
                      AND event IS NULL AND notes IS NULL""")
    fetch(conn, """DELETE FROM srm.spending_rule r WHERE category_code IS NULL AND driver IS NULL AND member_id IS NULL
                      AND notes IS NULL AND NOT EXISTS (SELECT 1 FROM srm.spending_rule_link l WHERE l.rule_id = r.rule_id)""")


def delete_category(conn, code, q):
    """Takes a category off. Its rules, tags, lifecycle triggers and family-page notes move to moveTo first (required
    when it has triggers, which always have a category); with no moveTo its rules and tags lose their category."""
    usage = category_usage(conn, code)
    code, by = usage["code"], str(q.get("by") or "MxAcctMGR")[:80]
    move_to = (q.get("moveTo") or "").strip().upper() or None
    if move_to and (move_to == code or not fetch(conn, "SELECT 1 FROM srm.spending_category WHERE code = %s", (move_to,))):
        raise ValueError("moveTo must be another category")
    if usage["uses"]["lifecycle triggers"] and not move_to:
        raise ValueError("%s has lifecycle triggers: choose a category to move them to" % usage["name"])
    if fetch(conn, "SELECT count(*) AS n FROM srm.spending_category")[0]["n"] <= 1:
        raise ValueError("%s is the only category" % usage["name"])
    for _, table in CATEGORY_USES:
        fetch(conn, "UPDATE %s SET category_code = %%s, updated_by = %%s, updated_at = now() WHERE category_code = %%s"
              % table, (move_to, by, code))
    if move_to:
        fetch(conn, "UPDATE srm.spending_feedback SET category_code = %s WHERE category_code = %s", (move_to, code))
    _drop_empty(conn)
    fetch(conn, "DELETE FROM srm.spending_category WHERE code = %s", (code,))
    conn.commit()
    return setup(conn, details=True)


def add_driver(conn, body):
    title = _text(body, "title", 60)
    if not title:
        raise ValueError("title is required")
    _unique(conn, "srm.spending_driver", "title", title, None, "driver")
    code = _new_code(body, title, upper=False)
    if fetch(conn, "SELECT 1 FROM srm.spending_driver WHERE code = %s", (code,)):
        raise Conflict("there is already a driver coded %s: give this one a code of its own" % code)
    sort = fetch(conn, "SELECT coalesce(max(sort_order), 0) + 1 AS n FROM srm.spending_driver")[0]["n"]
    fetch(conn, """INSERT INTO srm.spending_driver (code, title, help, effect, sort_order, updated_by)
                   VALUES (%s, %s, %s, %s, %s, %s)""",
          (code, title, _text(body, "help", 400), _effect(body), sort, _by(body)))
    conn.commit()
    return setup(conn, details=True)


def save_driver(conn, code, body):
    """A driver's title, what it means and the effect it counts as: only the fields sent change."""
    if not fetch(conn, "SELECT 1 FROM srm.spending_driver WHERE code = %s", (code,)):
        raise LookupError("no spending driver %s" % code)
    sets, params = [], []
    if "title" in body:
        title = _text(body, "title", 60)
        if not title:
            raise ValueError("title is required")
        _unique(conn, "srm.spending_driver", "title", title, code, "driver")
        sets.append("title = %s"); params.append(title)
    if "help" in body:
        sets.append("help = %s"); params.append(_text(body, "help", 400))
    if "effect" in body:
        sets.append("effect = %s"); params.append(_effect(body))
    if sets:
        fetch(conn, "UPDATE srm.spending_driver SET %s, updated_by = %%s, updated_at = now() WHERE code = %%s"
              % ", ".join(sets), params + [_by(body), code])
    conn.commit()
    return setup(conn, details=True)


def delete_driver(conn, code, q):
    """Takes a driver off. Its rules and tags move to moveTo first; with none they lose their driver (and then count
    as usage)."""
    usage = driver_usage(conn, code)
    by = str(q.get("by") or "MxAcctMGR")[:80]
    move_to = (q.get("moveTo") or "").strip() or None
    if move_to and (move_to == code or not fetch(conn, "SELECT 1 FROM srm.spending_driver WHERE code = %s", (move_to,))):
        raise ValueError("moveTo must be another driver")
    for _, table in DRIVER_USES:
        fetch(conn, "UPDATE %s SET driver = %%s, updated_by = %%s, updated_at = now() WHERE driver = %%s" % table,
              (move_to, by, code))
    _drop_empty(conn)
    fetch(conn, "DELETE FROM srm.spending_driver WHERE code = %s", (usage["code"],))
    conn.commit()
    return setup(conn, details=True)


def set_order(conn, table, body):
    """Every category's or driver's place, as the codes are listed."""
    codes = [str(c) for c in body.get("codes") or []]
    have = {r["code"] for r in fetch(conn, "SELECT code FROM %s" % table)}
    if len(codes) != len(have) or set(codes) != have:
        raise ValueError("codes must list each one once")
    for n, c in enumerate(codes, 1):
        fetch(conn, "UPDATE %s SET sort_order = %%s WHERE code = %%s" % table, (n, c))
    conn.commit()
    return setup(conn, details=True)


def save_rule(conn, body):
    account, payee = _opt_int(body, "expenseAccountId"), _opt_int(body, "payeeId")
    pattern = " ".join(str(body.get("pattern") or "").split())[:200] or None
    if [account, payee, pattern].count(None) != 2:
        raise ValueError("a rule is for an expenseAccountId, a payeeId or a pattern")
    if pattern is not None:
        return _save_text_rule(conn, body, pattern)
    key, value = ("expense_account_id", account) if account is not None else ("payee_id", payee)
    category, driver, member = _category(conn, body), _driver(conn, body), _opt_int(body, "memberId")
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
    return setup(conn, details=True)


def _save_text_rule(conn, body, pattern):
    """A statement text's rule (V042): every entry whose payee, statement name or description contains the text,
    ignoring case. With an id it changes that rule, its text included."""
    if len(pattern) < 3:
        raise ValueError("statement text is at least 3 characters")
    category, driver, member = _category(conn, body), _driver(conn, body), _opt_int(body, "memberId")
    notes = _text(body, "notes", 1000)
    rid = _opt_int(body, "id")
    if rid:
        found = fetch(conn, "SELECT rule_id FROM srm.spending_rule WHERE rule_id = %s AND pattern IS NOT NULL", (rid,))
        if not found:
            raise LookupError("no statement text rule %s" % rid)
    else:
        found = fetch(conn, "SELECT rule_id FROM srm.spending_rule WHERE lower(pattern) = lower(%s)", (pattern,))
    rid = found[0]["rule_id"] if found else None
    if fetch(conn, "SELECT 1 FROM srm.spending_rule WHERE lower(pattern) = lower(%s) AND rule_id <> %s", (pattern, rid or 0)):
        raise ValueError('there is already a rule for "%s"' % pattern)
    if not (category or driver or member or notes):
        if rid:
            fetch(conn, "DELETE FROM srm.spending_rule WHERE rule_id = %s", (rid,))
    elif rid:
        fetch(conn, """UPDATE srm.spending_rule SET pattern = %s, category_code = %s, driver = %s, member_id = %s,
                              notes = %s, updated_by = %s, updated_at = now() WHERE rule_id = %s""",
              (pattern, category, driver, member, notes, _by(body), rid))
    else:
        fetch(conn, """INSERT INTO srm.spending_rule (pattern, category_code, driver, member_id, notes, updated_by)
                       VALUES (%s, %s, %s, %s, %s, %s)""", (pattern, category, driver, member, notes, _by(body)))
    conn.commit()
    return setup(conn, details=True)


def save_rule_link(conn, rid, body):
    """A statement text rule's link (srm.spending_rule_link, V043), made or changed, as a target account's is
    (bank.save_payee_link); answers with the setup."""
    address = (body.get("address") or "").strip()
    if not address:
        raise ValueError("the link needs an address")
    blank = lambda k, n: (body.get(k) or "").strip()[:n] or None
    rows = fetch(conn, """
        INSERT INTO srm.spending_rule_link (rule_id, address, display_text, hover_text, hover_rtf, link_title, updated_at,
                                            updated_by)
        SELECT rule_id, %s, %s, %s, %s, %s, now(), %s FROM srm.spending_rule WHERE rule_id = %s AND pattern IS NOT NULL
        ON CONFLICT (rule_id) DO UPDATE SET address = excluded.address, display_text = excluded.display_text,
            hover_text = excluded.hover_text, hover_rtf = excluded.hover_rtf, link_title = excluded.link_title,
            updated_at = now(), updated_by = excluded.updated_by
        RETURNING rule_id""",
                 (address[:2000], blank("text", 200), blank("hoverText", 4000), body.get("hoverRtf") or None,
                  blank("title", 300), _by(body), int(rid)))
    if not rows:
        raise LookupError("no statement text rule %s" % rid)
    conn.commit()
    return setup(conn, details=True)


def delete_rule_link(conn, rid):
    fetch(conn, "DELETE FROM srm.spending_rule_link WHERE rule_id = %s", (int(rid),))
    conn.commit()
    return setup(conn, details=True)


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
    return setup(conn, details=True)


def delete_trigger(conn, tid):
    fetch(conn, "DELETE FROM srm.lifecycle_trigger WHERE trigger_id = %s", (int(tid),))
    conn.commit()
    return setup(conn, details=True)


def save_tag(conn, source, entry_id, body):
    column = SOURCES.get(source)
    if not column:
        raise ValueError("source must be bank, card or ledger")
    entry_id = int(entry_id)
    category, driver, member = _category(conn, body), _driver(conn, body), _opt_int(body, "memberId")
    event, notes = _text(body, "event", 120), _text(body, "notes", 1000)
    if body.get("merge"):
        # Only the fields sent change; the rest of the entry's own tag stays (MxAcctMGR's Entries: Set Category or
        # Set Driver on several entries keeps each one's other tagged values). An empty value follows the rules again.
        tag = fetch(conn, "SELECT category_code, driver, member_id, event, notes FROM srm.spending_tag WHERE %s = %%s"
                    % column, (entry_id,))
        before = tag[0] if tag else {}
        if "category" not in body: category = before.get("category_code")
        if "driver" not in body: driver = before.get("driver")
        if "memberId" not in body: member = before.get("member_id")
        if "event" not in body: event = before.get("event")
        if "notes" not in body: notes = before.get("notes")
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
    rows = fetch(conn, _entry_sql(conn) + " WHERE source = %s AND entry_id = %s", (source, entry_id))
    return {"entry": rows[0] if rows else None}


# ------------------------------------------------------------------------------------------------------------ analysis

ENTRY_SQL = """
    SELECT source, entry_id AS "entryId", txn_date AS date, register, payee_id AS "payeeId", payee, description,
           expense_account_id AS "expenseAccountId", expense_account AS "expenseAccount", amount,
           category_code AS category, category_from AS "categoryFrom", driver, driver_from AS "driverFrom",
           member_id AS "memberId", event, notes, tagged, rule_pattern AS "rulePattern"
      FROM srm.v_spending_entry"""
# The same, with what each matched Amazon charge or credit bought (V046).
AMAZON_ENTRY_SQL = ENTRY_SQL.replace("""
      FROM srm.v_spending_entry""", """, amazon_orders AS "amazonOrders", amazon_items AS "amazonItems",
           amazon_matched_by AS "amazonMatchedBy"
      FROM (SELECT e.*, a.orders AS amazon_orders, a.items AS amazon_items, a.matched_by AS amazon_matched_by
              FROM srm.v_spending_entry e LEFT JOIN srm.v_amazon_charge a USING (source, entry_id)) e""")


def _readable(conn, name):
    """The security master has this table or view and the role may read it."""
    return fetch(conn, """SELECT CASE WHEN to_regclass(%s) IS NULL THEN false
                                      ELSE has_table_privilege(to_regclass(%s), 'SELECT') END AS ok""", (name, name))[0]["ok"]


def _entry_sql(conn):
    """The entry query: with what Amazon charges bought where the security master has the Amazon orders (V046) and
    this role may read them (a REVOKE keeps them off the family page)."""
    return AMAZON_ENTRY_SQL if _readable(conn, "srm.v_amazon_charge") else ENTRY_SQL


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


def _window(q):
    """The period analysed and the one it is compared with: this year to date and the same dates a year earlier."""
    end = _date(q.get("end") or dt.date.today(), "end")
    start = _date(q.get("start") or end.replace(month=1, day=1), "start")
    prior_end = _date(q.get("priorEnd") or _year_back(end), "priorEnd")
    prior_start = _date(q.get("priorStart") or _year_back(start), "priorStart")
    if start > end or prior_start > prior_end:
        raise ValueError("a period's start must be on or before its end")
    return start, end, prior_start, prior_end


def _left_out(conn):
    """The registers that don't feed the analysis: left out (srm.spending_source, V038) or disconnected (V049)."""
    return {(r["source"], r["register"]) for r in
            fetch(conn, "SELECT source, register FROM srm.spending_source WHERE NOT included OR NOT connected")}


def analysis(conn, q):
    start, end, prior_start, prior_end = _window(q)
    out = _left_out(conn)
    entries = [e for e in fetch(conn, _entry_sql(conn) + """ WHERE txn_date BETWEEN %s AND %s OR txn_date BETWEEN %s AND %s
                                                      ORDER BY txn_date, source, entry_id""",
                                (prior_start, prior_end, start, end))
               if (e["source"], e["register"]) not in out]
    coverage = [c for c in fetch(conn, """
        SELECT source, register, min(txn_date) AS first, max(txn_date) AS last, count(*) AS entries
          FROM srm.v_spending_entry GROUP BY source, register ORDER BY source, register""")
                if (c["source"], c["register"]) not in out]
    return {"start": start, "end": end, "priorStart": prior_start, "priorEnd": prior_end, "entries": entries,
            "inflation": inflation(conn, start, end), "coverage": coverage}


# ------------------------------------------------------------------------------------------------------------ sources

def _drop_folders(module):
    """A download loader's drop folders, as its .local.json names them (else its defaults)."""
    folders = module.DEFAULT_FOLDERS
    try:
        with open(module.CONFIG_FILE) as f:
            folders = json.load(f).get("dropFolders") or folders
    except (OSError, ValueError):
        pass
    return list(folders)


def _home(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home + os.sep) else path


def _names_account(path, last4):
    """A QFX / OFX download whose account id (<ACCTID>) ends in these four digits."""
    try:
        with open(path, "rb") as f:
            head = f.read(65536).decode("latin-1")
    except OSError:
        return False
    i = head.upper().find("<ACCTID>")
    return i >= 0 and head[i + 8:i + 40].split("<")[0].strip().endswith(last4)


def _downloads(folders, code, last4):
    """The account's downloads in the drop folders, as the loaders find them: everything in its sub-folder (named by its
    code), and elsewhere in the folder (two levels down at most) a file whose name carries its last four digits
    (Chase1234_Activity…) or a QFX / OFX naming its account. Newest first."""
    found = {}
    for folder in folders:
        root = os.path.expanduser(folder)
        paths = []
        sub = os.path.join(root, code.upper())
        if os.path.isdir(sub):
            for d, _, names in os.walk(sub):
                paths += [os.path.join(d, n) for n in names]
        if last4 and os.path.isdir(root):
            for d, dirs, names in os.walk(root):
                if d.count(os.sep) - root.count(os.sep) >= 2:
                    dirs[:] = []
                dirs[:] = [x for x in dirs if not x.startswith((".", "_"))]
                for n in names:
                    p = os.path.join(d, n)
                    if last4 in n or (n.lower().endswith((".qfx", ".ofx")) and _names_account(p, last4)):
                        paths.append(p)
        for p in paths:
            if p.lower().endswith((".csv", ".qfx", ".ofx")) and os.path.isfile(p):
                st = os.stat(p)
                found[p] = {"path": _home(p), "name": os.path.basename(p), "bytes": st.st_size,
                            "modified": dt.datetime.fromtimestamp(st.st_mtime).astimezone().isoformat(timespec="seconds")}
    return sorted(found.values(), key=lambda f: f["modified"], reverse=True)


def _run(conn, load_id=None, loader=None):
    """A load run: the one that read a register's newest lines, or a loader's latest."""
    if load_id is None and loader is None:
        return None
    rows = fetch(conn, """
        SELECT load_id AS "loadId", loader, status, started_at AS "startedAt", finished_at AS "finishedAt",
               rows_read AS "rowsRead", rows_inserted AS "rowsInserted", message
          FROM srm.load_run WHERE """ + ("load_id = %s" if load_id is not None else "loader = %s ORDER BY load_id DESC LIMIT 1"),
                 (load_id if load_id is not None else loader,))
    return rows[0] if rows else None


# The SRM tables and views the analysis reads, what each gives it, and how to tell how fresh it is: rows, the newest
# data (a transaction, line or observation date) and the last change (an edit, or the load that wrote the newest rows).
TABLES = [
    ("srm.v_spending_entry", "view", "Every spending dollar of the three registers, with its category, driver and member resolved — what the analysis adds up",
     "SELECT count(*) AS rows, max(txn_date) AS newest, NULL::timestamptz AS changed FROM srm.v_spending_entry"),
    ("srm.bank_txn", "table", "The check register: checks, debits and fees in an expense account count as spending",
     "SELECT count(*) AS rows, max(txn_date) AS newest, max(updated_at) AS changed FROM srm.bank_txn WHERE status <> 'void'"),
    ("srm.bank_line", "table", "The bank's own lines from its downloads (pnc-bank); they clear register entries, they aren't spending themselves",
     "SELECT count(*) AS rows, max(posted_date) AS newest, (SELECT finished_at FROM srm.load_run WHERE load_id = max(l.load_id)) AS changed FROM srm.bank_line l"),
    ("srm.card_txn", "table", "The credit card registers: charges, credits, fees and interest (payments are left out)",
     "SELECT count(*) AS rows, max(txn_date) AS newest, max(updated_at) AS changed FROM srm.card_txn WHERE status <> 'void'"),
    ("srm.card_line", "table", "The card companies' lines from their downloads (card-downloads), posted to the card registers",
     "SELECT count(*) AS rows, max(posted_date) AS newest, (SELECT finished_at FROM srm.load_run WHERE load_id = max(l.load_id)) AS changed FROM srm.card_line l"),
    ("srm.expense_entry", "table", "The cash ledgers' items, entered by hand; those that are a card or check entry count there instead",
     "SELECT count(*) AS rows, max(entry_date) AS newest, max(updated_at) AS changed FROM srm.expense_entry WHERE status = 'actual' AND kind IN ('expense', 'refund')"),
    ("srm.expense_account", "table", "The expense accounts entries are filed in: the expense-account rules hang on them",
     "SELECT count(*) AS rows, NULL::date AS newest, NULL::timestamptz AS changed FROM srm.expense_account WHERE kind = 'expense'"),
    ("srm.payee", "table", "The target accounts: an entry's expense account when it has none of its own, and the target-account rules",
     "SELECT count(*) AS rows, NULL::date AS newest, max(updated_at) AS changed FROM srm.payee"),
    ("srm.spending_rule", "table", "Category, driver and member of an expense account's, target account's or statement text's spending",
     "SELECT count(*) AS rows, NULL::date AS newest, max(updated_at) AS changed FROM srm.spending_rule"),
    ("srm.spending_tag", "table", "One entry's own category, driver, member or event, overriding the rules",
     "SELECT count(*) AS rows, NULL::date AS newest, max(updated_at) AS changed FROM srm.spending_tag"),
    ("srm.spending_source", "table", "The registers left out of the analysis (no row: included)",
     "SELECT count(*) AS rows, NULL::date AS newest, max(updated_at) AS changed FROM srm.spending_source"),
    ("srm.spending_category", "table", "The spending categories with the CPI series each one's inflation follows",
     "SELECT count(*) AS rows, NULL::date AS newest, NULL::timestamptz AS changed FROM srm.spending_category"),
    ("srm.market_series_value", "table", "Consumer prices: the CPI-U series of family INFLATION, loaded from FRED by fred-yields",
     """SELECT count(*) AS rows, max(obs_date) AS newest,
               (SELECT max(finished_at) FROM srm.load_run WHERE loader = 'fred_yields' AND status IN ('succeeded', 'partial')) AS changed
          FROM srm.market_series_value WHERE series_code IN (SELECT series_code FROM srm.market_series WHERE family = 'INFLATION')"""),
    ("srm.household_member", "table", "The family: children's birth years drive the forward curve",
     "SELECT count(*) AS rows, NULL::date AS newest, max(updated_at) AS changed FROM srm.household_member"),
    ("srm.lifecycle_trigger", "table", "What a child's age brings and costs a year: the forward curve",
     "SELECT count(*) AS rows, NULL::date AS newest, max(updated_at) AS changed FROM srm.lifecycle_trigger"),
]

REGISTERS = {
    "bank": """
        SELECT a.code, a.name, a.institution, a.account_last4 AS last4, a.opening_date AS "openingDate",
               a.closed_date AS "closedDate", t.entries, t.first, t.last, t.edited,
               t.from_bank AS "fromDownloads", l.lines, l.first_line AS "firstLine", l.last_line AS "lastLine", l.load_id
          FROM srm.bank_account a
          LEFT JOIN LATERAL (SELECT count(*) AS entries, min(txn_date) AS first, max(txn_date) AS last,
                                    max(updated_at) AS edited, count(bank_line_id) AS from_bank
                               FROM srm.bank_txn WHERE bank_account_id = a.bank_account_id AND status <> 'void') t ON true
          LEFT JOIN LATERAL (SELECT count(*) AS lines, min(posted_date) AS first_line, max(posted_date) AS last_line,
                                    max(load_id) AS load_id
                               FROM srm.bank_line WHERE bank_account_id = a.bank_account_id) l ON true
         ORDER BY a.closed_date NULLS FIRST, a.name""",
    "card": """
        SELECT a.code, a.name, a.issuer AS institution, a.account_last4 AS last4, a.opening_date AS "openingDate",
               a.closed_date AS "closedDate", t.entries, t.first, t.last, t.edited,
               t.downloaded AS "fromDownloads", l.lines, l.first_line AS "firstLine", l.last_line AS "lastLine", l.load_id
          FROM srm.card_account a
          LEFT JOIN LATERAL (SELECT count(*) AS entries, min(txn_date) AS first, max(txn_date) AS last,
                                    max(updated_at) AS edited, count(*) FILTER (WHERE entered_by = 'card download') AS downloaded
                               FROM srm.card_txn WHERE card_account_id = a.card_account_id AND status <> 'void') t ON true
          LEFT JOIN LATERAL (SELECT count(*) AS lines, min(coalesce(trans_date, posted_date)) AS first_line,
                                    max(posted_date) AS last_line, max(load_id) AS load_id
                               FROM srm.card_line WHERE card_account_id = a.card_account_id) l ON true
         ORDER BY a.closed_date NULLS FIRST, a.name""",
    "ledger": """
        SELECT l.code, l.name, l.owner AS institution, NULL AS last4, l.opening_date AS "openingDate",
               l.closed_date AS "closedDate", t.entries, t.first, t.last, t.edited, 0 AS "fromDownloads",
               0 AS lines, NULL::date AS "firstLine", NULL::date AS "lastLine", NULL::bigint AS load_id
          FROM srm.expense_ledger l
          LEFT JOIN LATERAL (SELECT count(*) AS entries, min(entry_date) AS first, max(entry_date) AS last,
                                    max(updated_at) AS edited
                               FROM srm.expense_entry WHERE ledger_id = l.ledger_id AND status = 'actual'
                                AND kind IN ('expense', 'refund')) t ON true
         ORDER BY l.closed_date NULLS FIRST, l.name""",
}
LANDS_IN = {"bank": ("srm.bank_line", "srm.bank_txn"), "card": ("srm.card_line", "srm.card_txn"),
            "ledger": (None, "srm.expense_entry")}
LOADER = {"bank": ("pnc-bank", "pnc_bank"), "card": ("card-downloads", "card_downloads")}

# Amazon's order export (V046), in the tables list when the security master has it.
AMAZON_TABLES = [
    ("srm.amazon_order", "table", "Amazon orders from the Request Your Data export (amazon-orders), with their shipments and items: what was bought behind the Amazon charges",
     """SELECT count(*) AS rows, max(ordered_at)::date AS newest,
               (SELECT finished_at FROM srm.load_run WHERE load_id = max(o.load_id)) AS changed FROM srm.amazon_order o"""),
    ("srm.amazon_match", "table", "Which Amazon charge paid which shipment or order, and which credit refunded which item (amazon-orders matches them by amount and date)",
     "SELECT count(*) AS rows, NULL::date AS newest, max(matched_at) AS changed FROM srm.amazon_match"),
]
# Amazon charges that are orders: not memberships, video, e-books, audiobooks or AWS (as amazon_orders.is_order_charge).
AMAZON_TEXT = "concat_ws(' ', e.payee, e.description)"
AMAZON_ORDER_CHARGE = (AMAZON_TEXT + " ~* 'amazon|amzn' AND " + AMAZON_TEXT + " !~* 'prime video|amazon prime|primevideo|"
                       "prime membership|kindle|audible|web services|\\maws\\M|amazon music|amazon digital|amzn digital'")


def _amazon_downloads(folders):
    """The zips and CSV files in Amazon's drop folders (and below, as the loader reads them), newest first."""
    found = []
    for folder in folders:
        root = os.path.expanduser(folder)
        for d, dirs, names in os.walk(root):
            dirs[:] = [x for x in dirs if not x.startswith((".", "_"))]
            for n in names:
                p = os.path.join(d, n)
                if n.lower().endswith((".zip", ".csv")) and not n.startswith(".") and os.path.isfile(p):
                    st = os.stat(p)
                    found.append({"path": _home(p), "name": n, "bytes": st.st_size,
                                  "modified": dt.datetime.fromtimestamp(st.st_mtime).astimezone().isoformat(timespec="seconds")})
    return sorted(found, key=lambda f: f["modified"], reverse=True)


def _amazon(conn, start, end, folders):
    """Amazon's order export (V046): where it comes from, what it holds and its last load; the period's Amazon charges
    in the analysis, how many it matched and the newest one after its last order (a newer export is due); and the
    period's charges and credits no order matched and shipments no charge paid. None before V046 (or when the role
    may not read them)."""
    if not (_readable(conn, "srm.amazon_order") and _readable(conn, "srm.v_amazon_charge")):
        return None
    o = fetch(conn, """SELECT count(*) AS orders, min(ordered_at)::date AS "firstOrder", max(ordered_at)::date AS "lastOrder",
                              (SELECT count(*) FROM srm.amazon_item) AS items
                         FROM srm.amazon_order""")[0]
    c = fetch(conn, """
        SELECT count(*) FILTER (WHERE e.txn_date BETWEEN %s AND %s) AS "chargesNow",
               count(a.entry_id) FILTER (WHERE e.txn_date BETWEEN %s AND %s) AS "matchedNow",
               coalesce(sum(e.amount) FILTER (WHERE e.txn_date BETWEEN %s AND %s), 0) AS "spentNow",
               coalesce(sum(e.amount) FILTER (WHERE e.txn_date BETWEEN %s AND %s AND a.entry_id IS NOT NULL), 0) AS "matchedSpentNow",
               count(*) AS charges, count(a.entry_id) AS matched, max(e.txn_date) AS "newestCharge",
               count(*) FILTER (WHERE a.entry_id IS NULL AND e.txn_date > %s) AS "afterExport"
          FROM srm.v_spending_entry e
          LEFT JOIN srm.v_amazon_charge a USING (source, entry_id)
         WHERE e.source IN ('card', 'bank') AND """ + AMAZON_ORDER_CHARGE,
              (start, end) * 4 + (o["lastOrder"] or dt.date(1900, 1, 1),))[0]
    unmatched = fetch(conn, """
        SELECT e.source, e.entry_id AS "entryId", e.txn_date AS date, e.register, e.payee, e.amount
          FROM srm.v_spending_entry e
         WHERE e.source IN ('card', 'bank') AND e.txn_date BETWEEN %s AND %s AND """ + AMAZON_ORDER_CHARGE + """
           AND NOT EXISTS (SELECT FROM srm.v_amazon_charge a WHERE a.source = e.source AND a.entry_id = e.entry_id)
         ORDER BY e.txn_date DESC LIMIT 200""", (start, end))
    shipments = fetch(conn, """
        SELECT s.shipment_id AS "shipmentId", s.order_id AS "orderId", o.ordered_at::date AS ordered,
               s.shipped_at::date AS shipped, s.charge_amount AS amount, s.shipment_status AS status, o.payment,
               string_agg(CASE WHEN i.quantity > 1 THEN i.quantity || ' × ' ELSE '' END || i.product_name, E'\n'
                          ORDER BY i.item_id) AS items
          FROM srm.amazon_shipment s
          JOIN srm.amazon_order o USING (order_id)
          JOIN srm.amazon_item i USING (shipment_id)
         WHERE coalesce(s.shipped_at, o.ordered_at)::date BETWEEN %s AND %s AND s.charge_amount > 0
           AND coalesce(o.currency, 'USD') = 'USD' AND coalesce(o.order_status, '') !~* 'cancel'
           AND coalesce(s.shipment_status, '') !~* 'cancel'
           AND NOT EXISTS (SELECT FROM srm.amazon_match m WHERE m.shipment_id = s.shipment_id AND m.how IN ('shipment', 'shipments'))
           AND NOT EXISTS (SELECT FROM srm.amazon_match m WHERE m.order_id = s.order_id AND m.how = 'order')
         GROUP BY s.shipment_id, o.order_id
         ORDER BY coalesce(s.shipped_at, o.ordered_at) DESC LIMIT 200""", (start, end))
    return dict(o, **c,
                loader="amazon-orders", dropFolders=folders, foldersListed=folders is not None,
                downloads=_amazon_downloads(folders) if folders else [],
                lastImport=_run(conn, loader="amazon_orders"),
                unmatchedCharges=unmatched, unmatchedShipments=shipments)


def sources(conn, q):
    start, end, prior_start, prior_end = _window(q)
    try:
        from srmlib.loaders import card_downloads, pnc_bank   # SRM's folder is on sys.path (accounts_service.SRM)
        folders = {"bank": _drop_folders(pnc_bank), "card": _drop_folders(card_downloads)}
    except ImportError:
        folders = {}    # a machine without the loaders (the web page's server): no drop folders to list
    try:
        from srmlib.loaders import amazon_orders
        amazon_folders = _drop_folders(amazon_orders)
    except ImportError:
        amazon_folders = None
    choice = {(r["source"], r["register"]): r for r in fetch(conn, """
        SELECT source, register, included, updated_by AS "updatedBy", updated_at AS "updatedAt", connected,
               disconnected_by AS "disconnectedBy", disconnected_at AS "disconnectedAt" FROM srm.spending_source""")}
    # What removed cards' lines had, waiting for a card with the same last four digits to read them again (V049).
    waiting = {r["card_key"]: r["n"] for r in fetch(conn, "SELECT card_key, count(*) AS n FROM srm.card_line_memory GROUP BY 1")}
    spent = {(r["source"], r["register"]): r for r in fetch(conn, """
        SELECT source, register, min(txn_date) AS first, max(txn_date) AS last,
               count(*) FILTER (WHERE txn_date BETWEEN %s AND %s) AS "entriesNow",
               coalesce(sum(amount) FILTER (WHERE txn_date BETWEEN %s AND %s), 0) AS "spentNow",
               count(*) FILTER (WHERE txn_date BETWEEN %s AND %s) AS "entriesBefore",
               coalesce(sum(amount) FILTER (WHERE txn_date BETWEEN %s AND %s), 0) AS "spentBefore"
          FROM srm.v_spending_entry GROUP BY source, register""", (start, end) * 2 + (prior_start, prior_end) * 2)}
    out = []
    for kind, sql in REGISTERS.items():
        for r in fetch(conn, sql):
            key = (kind, r["code"])
            c, s = choice.get(key, {}), spent.get(key, {})
            lines_table, register_table = LANDS_IN[kind]
            # A checking account's source is its register in the security master, entered by hand: the bank's
            # downloads only clear its entries (Banking ▸ Checking Accounts), so no folders or loader are listed.
            files = kind == "card" and kind in folders
            out.append(dict(
                {k: v for k, v in r.items() if k != "load_id"}, source=kind,
                included=c.get("included", True), choiceBy=c.get("updatedBy"), choiceAt=c.get("updatedAt"),
                connected=c.get("connected", True), disconnectedBy=c.get("disconnectedBy"),
                disconnectedAt=c.get("disconnectedAt"),
                remembered=waiting.get((r["last4"] or "").strip() or r["code"], 0) if kind == "card" else 0,
                linesTable=lines_table if kind == "card" else None, registerTable=register_table,
                loader=LOADER.get(kind, (None,))[0] if kind == "card" else None,
                dropFolders=folders.get(kind, []) if files else [],
                downloads=_downloads(folders[kind], r["code"], r["last4"]) if files else [],
                foldersListed=files,
                lastImport=_run(conn, load_id=r["load_id"]) if r["load_id"] and kind == "card" else None,
                spendingFirst=s.get("first"), spendingLast=s.get("last"),
                entriesNow=s.get("entriesNow", 0), spentNow=s.get("spentNow", 0),
                entriesBefore=s.get("entriesBefore", 0), spentBefore=s.get("spentBefore", 0)))
    amazon = _amazon(conn, start, end, amazon_folders)
    tables = []
    for name, kind, role, sql in TABLES + (AMAZON_TABLES if amazon is not None else []):
        row = fetch(conn, sql)[0]
        tables.append(dict(name=name, kind=kind, role=role, **row))
    loaders = [r for r in (_run(conn, loader=n) for n in ("pnc_bank", "card_downloads", "amazon_orders", "fred_yields")) if r]
    return {"start": start, "end": end, "priorStart": prior_start, "priorEnd": prior_end, "sources": out,
            "tables": tables, "loaders": loaders, "amazon": amazon, "now": dt.datetime.now().astimezone()}


# srm-loader runs the loader, so the load shows in the shared activity log (MxDataHUB Activity, MxJobsMGR).
AMAZON_LOADER = os.environ.get("SRM_LOADER_URL", "http://127.0.0.1:8770") + "/load/amazon-orders"


def load_amazon(conn, body, q):
    """Saves an Amazon order export in the first drop folder (when one is sent), then runs srm.py load amazon-orders
    through srm-loader; answers with the sources and how the load went."""
    from srmlib.loaders import amazon_orders   # SRM's folder is on sys.path (accounts_service.SRM)
    saved = None
    if body.get("data"):
        name = os.path.basename(str(body.get("filename") or "")).strip()
        if not name.lower().endswith((".zip", ".csv")) or name.startswith("."):
            raise ValueError("an Amazon order export is a .zip (as downloaded) or a Retail.OrderHistory .csv")
        try:
            data = base64.b64decode(body["data"], validate=True)
        except ValueError:
            raise ValueError("data must be the file in base64")
        folder = os.path.expanduser(_drop_folders(amazon_orders)[0])
        os.makedirs(folder, exist_ok=True)
        saved = os.path.join(folder, name)
        tmp = os.path.join(folder, ".part-" + name)    # the loader doesn't read dot files
        with open(tmp, "wb") as f:
            f.write(data)
        try:
            found = [t for _, t in amazon_orders.texts(tmp) if amazon_orders.read_csv(t) is not None]
        except Exception:
            found = []
        if not found:
            os.remove(tmp)
            raise ValueError("%s holds no Amazon order history (Retail.OrderHistory CSV with Order ID, Order Date, "
                             "Product Name and Total Owed columns)" % name)
        os.replace(tmp, saved)
    req = urllib.request.Request(AMAZON_LOADER, data=b"", method="POST")
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            out = json.load(r)
    except Exception as e:
        raise ValueError("srm-loader didn't run amazon-orders: %s" % e)
    run = (out.get("runs") or [{}])[-1]
    return dict(sources(conn, q), load={"status": run.get("status") or out.get("status"),
                                        "message": run.get("message") or out.get("error"),
                                        "file": saved and _home(saved)})


AMAZON_ORDER_ID = re.compile(r"^[0-9D]\d{2}-\d{7}-\d{7}$")


def _amazon_ids(values):
    ids = [str(v).strip() for v in values or [] if str(v).strip()]
    bad = [i for i in ids if not AMAZON_ORDER_ID.match(i)]
    if bad:
        raise ValueError("not an Amazon order number: %s" % ", ".join(bad[:3]))
    return ids


def amazon_known(conn, q):
    """Which of these orders are kept (so the lookup reads only the others' pages)."""
    ids = _amazon_ids((q.get("ids") or "").split(","))
    rows = fetch(conn, """SELECT order_id AS "orderId", origin, items FROM srm.amazon_order WHERE order_id = ANY(%s)""", (ids,))
    return {"known": rows}


def _entry(conn, source, entry_id):
    rows = fetch(conn, _entry_sql(conn) + " WHERE source = %s AND entry_id = %s", (source, entry_id))
    return rows[0] if rows else None


def attach_amazon(conn, body):
    """The Amazon Order Lookup's results: each order its page gave (unless the export has it), and each charge's orders
    from Amazon's Transactions list, in place of the matches it had."""
    orders = body.get("orders") or []
    for o in orders:
        oid = _amazon_ids([o.get("orderId")])[0]
        known = fetch(conn, "SELECT origin FROM srm.amazon_order WHERE order_id = %s", (oid,))
        if known and known[0]["origin"] == "export":
            continue     # the export's rows are fuller (shipments, tax): they stay
        items = [i for i in (o.get("items") or []) if str(i.get("name") or "").strip()]
        if not items:
            continue
        ordered = o.get("orderedAt")
        try:
            ordered = dt.date.fromisoformat(str(ordered)[:10]) if ordered else None
        except ValueError:
            ordered = None
        total = round(float(o["total"]), 2) if o.get("total") is not None else None
        payment = str(o.get("payment") or "").strip()[:120] or None
        last4 = payment[-4:] if payment and payment[-4:].isdigit() else None
        digest = "order page:" + hashlib.sha1(json.dumps(o, sort_keys=True, default=str).encode()).hexdigest()
        fetch(conn, """INSERT INTO srm.amazon_order (order_id, website, ordered_at, origin, payment, payment_last4, items,
                                                     total_owed, content_hash, file_name)
                       VALUES (%s, 'Amazon.com', coalesce(%s::date, now()::date), 'order page', %s, %s, %s, %s, %s,
                               'amazon.com order page')
                       ON CONFLICT (order_id) DO UPDATE SET ordered_at = excluded.ordered_at, payment = excluded.payment,
                              payment_last4 = excluded.payment_last4, items = excluded.items,
                              total_owed = excluded.total_owed, content_hash = excluded.content_hash, updated_at = now()""",
              (oid, ordered, payment, last4, len(items), total, digest))
        fetch(conn, "DELETE FROM srm.amazon_item WHERE order_id = %s", (oid,))
        for i in items:
            qty = int(i.get("quantity") or 1)
            price = round(float(i["price"]), 2) if i.get("price") is not None else None
            fetch(conn, """INSERT INTO srm.amazon_item (order_id, product_name, asin, quantity, unit_price, total_owed)
                           VALUES (%s, %s, %s, %s, %s, %s)""",
                  (oid, str(i["name"]).strip()[:500], (str(i.get("asin") or "").strip() or None), qty, price,
                   round(price * qty, 2) if price is not None else None))
    out = []
    for c in body.get("charges") or []:
        source, entry_id = c.get("source"), int(c.get("entryId") or 0)
        if source not in ("card", "bank"):
            raise ValueError("source must be card or bank")
        ids = _amazon_ids(c.get("orderIds"))
        column = "card_txn_id" if source == "card" else "bank_txn_id"
        kept = [r["order_id"] for r in fetch(conn, "SELECT order_id FROM srm.amazon_order WHERE order_id = ANY(%s)", (ids,))]
        if ids and not kept:
            raise LookupError("none of %s is kept: its page gave no items" % ", ".join(ids))
        txn = fetch(conn, "SELECT txn_date FROM srm.%s WHERE txn_id = %%s" % ("card_txn" if source == "card" else "bank_txn"),
                    (entry_id,))
        if not txn:
            raise LookupError("no %s entry %s" % (source, entry_id))
        fetch(conn, "DELETE FROM srm.amazon_match WHERE %s = %%s" % column, (entry_id,))
        for oid in kept:
            fetch(conn, """INSERT INTO srm.amazon_match (%s, order_id, how, days, matched_by)
                           SELECT %%s, %%s, 'transaction', %%s - ordered_at::date, 'amazon-lookup'
                             FROM srm.amazon_order WHERE order_id = %%s""" % column,
                  (entry_id, oid, txn[0]["txn_date"], oid))
        out.append((source, entry_id))
    conn.commit()
    return {"entries": [e for e in (_entry(conn, s_, i) for s_, i in out) if e]}


def unlink_amazon(conn, source, entry_id, body):
    """Takes the orders off a charge, for good: an 'unlinked' row keeps the loader from matching it again (the lookup
    can still attach orders to it)."""
    if source not in ("card", "bank"):
        raise ValueError("source must be card or bank")
    entry_id = int(entry_id)
    column = "card_txn_id" if source == "card" else "bank_txn_id"
    had = fetch(conn, "SELECT order_id FROM srm.amazon_match WHERE %s = %%s AND how <> 'unlinked' LIMIT 1" % column, (entry_id,))
    if had:
        fetch(conn, "DELETE FROM srm.amazon_match WHERE %s = %%s" % column, (entry_id,))
        fetch(conn, """INSERT INTO srm.amazon_match (%s, order_id, how, matched_by) VALUES (%%s, %%s, 'unlinked', %%s)"""
              % column, (entry_id, had[0]["order_id"], _by(body) or "MxAcctMGR"))
    conn.commit()
    return {"entry": _entry(conn, source, entry_id)}


def set_source(conn, source, code, body, q):
    if source not in SOURCES:
        raise ValueError("source must be bank, card or ledger")
    table = {"bank": "bank_account", "card": "card_account", "ledger": "expense_ledger"}[source]
    rows = fetch(conn, "SELECT code FROM srm.%s WHERE upper(code) = upper(%%s)" % table, (code,))
    if not rows:
        raise LookupError("no %s %s" % ({"bank": "checking account", "card": "credit card", "ledger": "cash ledger"}[source], code))
    fetch(conn, """INSERT INTO srm.spending_source (source, register, included, updated_by) VALUES (%s, %s, %s, %s)
                   ON CONFLICT (source, register) DO UPDATE SET included = excluded.included,
                          updated_by = excluded.updated_by, updated_at = now()""",
          (source, rows[0]["code"], bool(body.get("included", True)), _by(body)))
    conn.commit()
    return sources(conn, q)


# ------------------------------------------------------------------------------------------------- transfers and income
# A target account filed under a transfer or income account (srm.expense_account.kind) is not spending: the view leaves
# its checks and card entries out. Sources ▸ Transfers & Income lists those and suggests the ones that would count a
# dollar twice — the target account checking pays a card with (its charges count), a cash ledger's funding account
# (its items count), and names that look like moving money: transfers, investment buys and sells, pay and deposits.

TRANSFER_NAME = re.compile(r"^tx\b|\btransfer\b|\bach\b|\bvanguard (buy|sell)\b|\bzelle\b|\bvenmo\b|\bhysa\b", re.I)
PAY_NAME = re.compile(r"\bpay \[|\bpayroll\b|\bsalary\b|\bdirect dep", re.I)
DEPOSIT_NAME = re.compile(r"\bdeposit\b", re.I)
# What each target account moved, signed as spending: a check out is positive, a deposit in negative.
TARGET_ACTIVITY = """
    SELECT payee_id, txn_date, -amount AS spent FROM srm.bank_txn WHERE status <> 'void' AND payee_id IS NOT NULL
    UNION ALL
    SELECT payee_id, txn_date, amount FROM srm.card_txn WHERE status <> 'void' AND kind <> 'payment' AND payee_id IS NOT NULL"""


def transfers(conn, q):
    start, end, prior_start, prior_end = _window(q)
    rows = fetch(conn, """
        WITH act AS (%s)
        SELECT p.payee_id AS id, p.name, p.expense_account_id AS "expenseAccountId", e.name AS "expenseAccount",
               e.kind, count(a.payee_id) AS entries, max(a.txn_date) AS "lastDate",
               coalesce(sum(a.spent) FILTER (WHERE a.txn_date BETWEEN %%s AND %%s), 0) AS now,
               coalesce(sum(a.spent) FILTER (WHERE a.txn_date BETWEEN %%s AND %%s), 0) AS before,
               coalesce(sum(a.spent) FILTER (WHERE a.spent > 0), 0) AS "paidOut",
               coalesce(-sum(a.spent) FILTER (WHERE a.spent < 0), 0) AS "cameIn",
               (SELECT array_agg(c.code ORDER BY c.code) FROM srm.card_account c WHERE c.payee_id = p.payee_id) AS cards,
               (SELECT array_agg(l.code ORDER BY l.code) FROM srm.expense_ledger l WHERE p.payee_id = ANY (l.funding_payees)) AS ledgers
          FROM srm.payee p
          LEFT JOIN srm.expense_account e ON e.expense_account_id = p.expense_account_id
          LEFT JOIN act a ON a.payee_id = p.payee_id
         GROUP BY p.payee_id, e.expense_account_id
        HAVING count(a.payee_id) > 0""" % TARGET_ACTIVITY, (start, end, prior_start, prior_end))
    left_out, suggested = [], []
    for r in rows:
        for k in ("now", "before", "paidOut", "cameIn"):
            r[k] = float(r[k])
        if r["kind"] in ("transfer", "income"):
            left_out.append(r)
            continue
        why = []
        if r["cards"]:
            why.append({"kind": "card", "text": "checking pays %s with it: its charges count on the card" % ", ".join(r["cards"])})
        if r["ledgers"]:
            why.append({"kind": "ledger", "text": "it funds %s: the ledger's items count" % ", ".join(r["ledgers"])})
        if PAY_NAME.search(r["name"]):
            why.append({"kind": "pay", "text": "its name looks like pay coming in"})
        elif TRANSFER_NAME.search(r["name"]):
            why.append({"kind": "name", "text": "its name looks like money moved between accounts"})
        elif DEPOSIT_NAME.search(r["name"]):
            why.append({"kind": "deposit", "text": "its name looks like a deposit"})
        if not why:
            continue
        kinds = {w["kind"] for w in why}
        r["why"] = why
        r["certain"] = bool(kinds & {"card", "ledger"})
        r["suggest"] = "income" if kinds == {"pay"} else "transfer"
        suggested.append(r)
    left_out.sort(key=lambda r: (-abs(r["now"]) - abs(r["before"]), r["name"].lower()))
    suggested.sort(key=lambda r: (not r["certain"], -(r["paidOut"] + r["cameIn"]), r["name"].lower()))
    accounts = fetch(conn, """SELECT expense_account_id AS id, name, kind FROM srm.expense_account
                               ORDER BY kind <> 'transfer', kind <> 'income', sort_order, name""")
    return {"start": start, "end": end, "priorStart": prior_start, "priorEnd": prior_end,
            "leftOut": left_out, "suggested": suggested, "accounts": accounts}


def file_target(conn, pid, body, q):
    """Files a target account, and its checks and card entries (a card's payments aside), under an expense account:
    a transfer or income account leaves them out of the analysis, an expense account puts them back."""
    pid = int(pid)
    account = _opt_int(body, "expenseAccountId")
    if account is None or not fetch(conn, "SELECT 1 FROM srm.expense_account WHERE expense_account_id = %s", (account,)):
        raise ValueError("expenseAccountId must be an expense account")
    by = _by(body)
    if not fetch(conn, """UPDATE srm.payee SET expense_account_id = %s, version = version + 1, updated_by = %s, updated_at = now()
                           WHERE payee_id = %s RETURNING payee_id""", (account, by, pid)):
        raise LookupError("no target account %s" % pid)
    refiled = len(fetch(conn, """UPDATE srm.bank_txn SET expense_account_id = %s, version = version + 1, updated_by = %s,
                                        updated_at = now()
                                  WHERE payee_id = %s AND status <> 'void' AND expense_account_id IS DISTINCT FROM %s
                              RETURNING txn_id""", (account, by, pid, account)))
    refiled += len(fetch(conn, """UPDATE srm.card_txn SET expense_account_id = %s, version = version + 1, updated_by = %s,
                                         updated_at = now()
                                   WHERE payee_id = %s AND status <> 'void' AND kind <> 'payment'
                                     AND expense_account_id IS DISTINCT FROM %s
                               RETURNING txn_id""", (account, by, pid, account)))
    conn.commit()
    return dict(transfers(conn, q), refiled={"id": pid, "entries": refiled})


# ------------------------------------------------------------------------------------------------- disconnect, reconnect
# A source taken out of Spending Analysis keeps its register (V049); its links to the other sources are undone and
# kept in srm.source_link, to put back when it is reconnected.

SOURCE_TABLES = {"bank": ("bank_account", "bank_account_id", "checking account"),
                 "card": ("card_account", "card_account_id", "credit card"),
                 "ledger": ("expense_ledger", "ledger_id", "cash ledger")}
# Each source's links to the others: (kind, query of card_txn_id, bank_txn_id, expense_entry_id for the source's id).
SOURCE_LINKS = {
    "bank": [("payment", """SELECT c.txn_id AS card, c.bank_txn_id AS bank, NULL::bigint AS entry FROM srm.card_txn c
                             JOIN srm.bank_txn b ON b.txn_id = c.bank_txn_id WHERE b.bank_account_id = %s"""),
             ("ledger_bank", """SELECT NULL::bigint AS card, e.bank_txn_id AS bank, e.entry_id AS entry FROM srm.expense_entry e
                                JOIN srm.bank_txn b ON b.txn_id = e.bank_txn_id WHERE b.bank_account_id = %s""")],
    "card": [("payment", """SELECT c.txn_id AS card, c.bank_txn_id AS bank, NULL::bigint AS entry FROM srm.card_txn c
                             WHERE c.card_account_id = %s AND c.bank_txn_id IS NOT NULL"""),
             ("ledger_card", """SELECT e.card_txn_id AS card, NULL::bigint AS bank, e.entry_id AS entry FROM srm.expense_entry e
                                JOIN srm.card_txn c ON c.txn_id = e.card_txn_id WHERE c.card_account_id = %s""")],
    "ledger": [("ledger_card", """SELECT e.card_txn_id AS card, NULL::bigint AS bank, e.entry_id AS entry FROM srm.expense_entry e
                                  WHERE e.ledger_id = %s AND e.card_txn_id IS NOT NULL"""),
               ("ledger_bank", """SELECT NULL::bigint AS card, e.bank_txn_id AS bank, e.entry_id AS entry FROM srm.expense_entry e
                                  WHERE e.ledger_id = %s AND e.bank_txn_id IS NOT NULL""")],
}
LINK_WORDS = {"payment": "card payments linked to the checks that paid them",
              "ledger_card": "cash-ledger entries linked to card charges",
              "ledger_bank": "cash-ledger entries linked to checks"}


def _source_row(conn, source, code):
    if source not in SOURCE_TABLES:
        raise ValueError("source must be bank, card or ledger")
    table, key, what = SOURCE_TABLES[source]
    rows = fetch(conn, "SELECT %s AS id, code, name FROM srm.%s WHERE upper(code) = upper(%%s)" % (key, table), (code,))
    if not rows:
        raise LookupError("no %s %s" % (what, code))
    state = fetch(conn, "SELECT connected FROM srm.spending_source WHERE source = %s AND register = %s",
                  (source, rows[0]["code"]))
    return dict(rows[0], connected=state[0]["connected"] if state else True)


def source_links(conn, source, code):
    """What disconnecting the source undoes, and what stays with its register."""
    r = _source_row(conn, source, code)
    links = {kind: len(fetch(conn, sql, (r["id"],))) for kind, sql in SOURCE_LINKS[source]}
    kept = fetch(conn, "SELECT count(*) AS n FROM srm.source_link WHERE source = %s AND register = %s", (source, r["code"]))[0]["n"]
    entries = fetch(conn, "SELECT count(*) AS n FROM srm.v_spending_entry WHERE source = %s AND register = %s",
                    (source, r["code"]))[0]["n"]
    return {"source": source, "code": r["code"], "name": r["name"], "connected": r["connected"],
            "links": [{"kind": k, "what": LINK_WORDS[k], "count": n} for k, n in links.items()],
            "kept": kept, "spendingEntries": entries}


def disconnect_source(conn, source, code, body, q):
    r = _source_row(conn, source, code)
    if not r["connected"]:
        raise ValueError("%s is already disconnected" % r["name"])
    by = _by(body)
    for kind, sql in SOURCE_LINKS[source]:
        for link in fetch(conn, sql, (r["id"],)):
            fetch(conn, """INSERT INTO srm.source_link (source, register, kind, card_txn_id, bank_txn_id, expense_entry_id, undone_by)
                           VALUES (%s, %s, %s, %s, %s, %s, %s)""",
                  (source, r["code"], kind, link["card"], link["bank"], link["entry"], by))
            if kind == "payment":
                fetch(conn, """UPDATE srm.card_txn SET bank_txn_id = NULL, version = version + 1, updated_by = %s,
                                      updated_at = now() WHERE txn_id = %s""", (by, link["card"]))
            else:
                column = "card_txn_id" if kind == "ledger_card" else "bank_txn_id"
                fetch(conn, """UPDATE srm.expense_entry SET %s = NULL, version = version + 1, updated_by = %%s,
                                      updated_at = now() WHERE entry_id = %%s""" % column, (by, link["entry"]))
    fetch(conn, """INSERT INTO srm.spending_source (source, register, connected, disconnected_by, disconnected_at, updated_by)
                   VALUES (%s, %s, false, %s, now(), %s)
                   ON CONFLICT (source, register) DO UPDATE SET connected = false, disconnected_by = excluded.disconnected_by,
                          disconnected_at = now(), updated_by = excluded.updated_by, updated_at = now()""",
          (source, r["code"], by, by))
    conn.commit()
    return sources(conn, q)


def reconnect_source(conn, source, code, body, q):
    """Back in Spending Analysis, from the security master; each link kept is put back where both sides are still
    there and neither has been linked to something else since. Answers with the sources and what was put back."""
    r = _source_row(conn, source, code)
    if r["connected"]:
        raise ValueError("%s is connected" % r["name"])
    by = _by(body)
    restored = skipped = 0
    for link in fetch(conn, "SELECT * FROM srm.source_link WHERE source = %s AND register = %s ORDER BY link_id",
                      (source, r["code"])):
        if link["kind"] == "payment":
            done = fetch(conn, """UPDATE srm.card_txn SET bank_txn_id = %s, version = version + 1, updated_by = %s, updated_at = now()
                                   WHERE txn_id = %s AND bank_txn_id IS NULL
                                     AND EXISTS (SELECT 1 FROM srm.bank_txn WHERE txn_id = %s AND status <> 'void')
                                     AND NOT EXISTS (SELECT 1 FROM srm.card_txn WHERE bank_txn_id = %s)
                               RETURNING txn_id""",
                         (link["bank_txn_id"], by, link["card_txn_id"], link["bank_txn_id"], link["bank_txn_id"]))
        else:
            column, table, other = (("card_txn_id", "srm.card_txn", link["card_txn_id"]) if link["kind"] == "ledger_card"
                                    else ("bank_txn_id", "srm.bank_txn", link["bank_txn_id"]))
            done = fetch(conn, """UPDATE srm.expense_entry SET %s = %%s, version = version + 1, updated_by = %%s, updated_at = now()
                                   WHERE entry_id = %%s AND %s IS NULL
                                     AND EXISTS (SELECT 1 FROM %s WHERE txn_id = %%s)
                                     AND NOT EXISTS (SELECT 1 FROM srm.expense_entry WHERE %s = %%s)
                               RETURNING entry_id""" % (column, column, table, column),
                         (other, by, link["expense_entry_id"], other, other))
        restored, skipped = (restored + 1, skipped) if done else (restored, skipped + 1)
    fetch(conn, "DELETE FROM srm.source_link WHERE source = %s AND register = %s", (source, r["code"]))
    fetch(conn, """UPDATE srm.spending_source SET connected = true, disconnected_by = NULL, disconnected_at = NULL,
                          updated_by = %s, updated_at = now() WHERE source = %s AND register = %s""", (by, source, r["code"]))
    conn.commit()
    return dict(sources(conn, q), reconnected={"code": r["code"], "restored": restored, "skipped": skipped})


# ------------------------------------------------------------------------------------------------------------ feedback

FEEDBACK_KINDS = ("layout", "number", "rule", "entry", "idea", "question")   # 'change' notes come from change_*
FEEDBACK_STATUSES = ("new", "seen", "planned", "done", "declined")


def feedback(conn, q=None):
    q = q or {}
    where, params = [], []
    if q.get("author"):
        where.append("lower(author) = lower(%s)")
        params.append(q["author"])
    if q.get("status"):
        where.append("status = %s")
        params.append(q["status"])
    rows = fetch(conn, """
        SELECT feedback_id AS id, created_at AS "createdAt", author, kind, tab, section, category_code AS category,
               entry_source AS "entrySource", entry_id AS "entryId", suggestion, message, context, status, reply,
               replied_by AS "repliedBy", replied_at AS "repliedAt"
          FROM srm.spending_feedback""" + (" WHERE " + " AND ".join(where) if where else "") + """
         ORDER BY created_at DESC LIMIT 500""", params)
    return {"feedback": rows}


def add_feedback(conn, body, client=None):
    author, message = _text(body, "author", 80), _text(body, "message", 4000)
    if not author:
        raise ValueError("author is required")
    if not message:
        raise ValueError("message is required")
    kind = body.get("kind") or "idea"
    if kind not in FEEDBACK_KINDS:
        raise ValueError("kind must be one of " + ", ".join(FEEDBACK_KINDS))
    source = body.get("entrySource") or None
    if source and source not in SOURCES:
        raise ValueError("entrySource must be bank, card or ledger")
    context = body.get("context") if isinstance(body.get("context"), dict) else None
    fetch(conn, """INSERT INTO srm.spending_feedback (author, kind, tab, section, category_code, entry_source, entry_id,
                          suggestion, message, context, client)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb, %s)""",
          (author, kind, _text(body, "tab", 40), _text(body, "section", 120), _category(conn, body),
           source, _opt_int(body, "entryId") if source else None, _text(body, "suggestion", 400), message,
           json.dumps(context, default=str) if context else None, (client or "")[:60] or None))
    conn.commit()
    return feedback(conn, {"author": author})


def answer_feedback(conn, fid, body):
    status = body.get("status") or "seen"
    if status not in FEEDBACK_STATUSES:
        raise ValueError("status must be one of " + ", ".join(FEEDBACK_STATUSES))
    if not fetch(conn, """UPDATE srm.spending_feedback SET status = %s, reply = %s, replied_by = %s,
                                 replied_at = CASE WHEN %s IS NULL THEN replied_at ELSE now() END
                           WHERE feedback_id = %s RETURNING feedback_id""",
                 (status, _text(body, "reply", 4000), _by(body), _text(body, "reply", 4000), int(fid))):
        raise LookupError("no feedback %s" % fid)
    conn.commit()
    return feedback(conn)


# ------------------------------------------------------------------------------------------------------------ tax

TAX_SECTIONS = ("expense", "payment", "real_estate", "refund", "savings")
JURISDICTIONS = ("federal", "state", "local")


def tax_period(section, quarterly, day):
    """The tax year (and estimated-tax quarter) a payment counts toward: a refund toward the year before the one it
    arrives in; an estimated payment toward its quarter (January → Q4 of the year before, February–April → Q1,
    May–June → Q2, July–September → Q3, October–December → Q4); anything else toward the year it was paid."""
    if section == "refund":
        return day.year - 1, None
    if not quarterly:
        return day.year, None
    if day.month == 1:
        return day.year - 1, 4
    return day.year, 1 if day.month <= 4 else 2 if day.month <= 6 else 3 if day.month <= 9 else 4


def _like(pattern):
    return "%" + pattern.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"


def tax(conn, q):
    today = dt.date.today()
    year = int(q.get("year") or (today.year - 1 if today.month <= 4 else today.year))
    items = fetch(conn, """
        SELECT i.item_id AS id, i.payee_id AS "payeeId", p.name AS payee, i.ledger_line_id AS "ledgerLineId",
               ln.name AS "ledgerLine", l.code AS ledger, i.name_pattern AS "namePattern", i.label, i.section,
               i.tax_category AS "taxCategory", i.jurisdiction, i.deductible_share AS "deductibleShare", i.quarterly,
               i.notes, i.sort_order AS "sortOrder", i.active
          FROM srm.tax_item i
          LEFT JOIN srm.payee p ON p.payee_id = i.payee_id
          LEFT JOIN srm.expense_line ln ON ln.line_id = i.ledger_line_id
          LEFT JOIN srm.expense_ledger l ON l.ledger_id = ln.ledger_id
         ORDER BY i.sort_order, i.label""")
    live = [i for i in items if i["active"]]
    payees = [i["payeeId"] for i in live if i["payeeId"]]
    lines = [i["ledgerLineId"] for i in live if i["ledgerLineId"]]
    likes = [_like(i["namePattern"]) for i in live if i["namePattern"]]
    # Three years of candidates: a payment can count toward the year before (January, refunds) or be moved by hand.
    lo, hi = dt.date(year - 1, 1, 1), dt.date(year + 1, 12, 31)
    rows = []
    if payees or likes:
        rows += fetch(conn, """
            SELECT 'bank' AS source, b.txn_id AS "entryId", b.txn_date AS date, coalesce(p.name, b.payee_name) AS payee,
                   b.payee_id AS "payeeId", b.memo AS description, -b.amount AS amount, a.code AS register,
                   NULL::bigint AS "lineId"
              FROM srm.bank_txn b JOIN srm.bank_account a USING (bank_account_id)
              LEFT JOIN srm.payee p ON p.payee_id = b.payee_id
             WHERE b.status <> 'void' AND b.txn_date BETWEEN %s AND %s
               AND (b.payee_id = ANY(%s) OR coalesce(p.name, b.payee_name, '') ILIKE ANY(%s))""", (lo, hi, payees, likes))
        rows += fetch(conn, """
            SELECT 'card' AS source, c.txn_id AS "entryId", c.txn_date AS date, coalesce(p.name, c.payee_name) AS payee,
                   c.payee_id AS "payeeId", c.memo AS description, c.amount, a.code AS register, NULL::bigint AS "lineId"
              FROM srm.card_txn c JOIN srm.card_account a USING (card_account_id)
              LEFT JOIN srm.payee p ON p.payee_id = c.payee_id
             WHERE c.status <> 'void' AND c.kind <> 'payment' AND c.txn_date BETWEEN %s AND %s
               AND (c.payee_id = ANY(%s) OR coalesce(p.name, c.payee_name, '') ILIKE ANY(%s))""", (lo, hi, payees, likes))
    ledger = []
    if lines:
        ledger = fetch(conn, """
            SELECT 'ledger' AS source, e.entry_id AS "entryId", e.entry_date AS date, coalesce(e.vendor, e.description) AS payee,
                   NULL::integer AS "payeeId", e.description, e.amount, l.code AS register, e.line_id AS "lineId",
                   e.card_txn_id AS "cardTxnId", e.bank_txn_id AS "bankTxnId"
              FROM srm.expense_entry e JOIN srm.expense_ledger l USING (ledger_id)
             WHERE e.status = 'actual' AND e.kind IN ('expense', 'refund') AND e.line_id = ANY(%s)
               AND e.entry_date BETWEEN %s AND %s""", (lines, lo, hi))
    # A ledger item that is also a card or check entry counts once, as the ledger's.
    claimed = {("card", e["cardTxnId"]) for e in ledger if e.get("cardTxnId")} | {("bank", e["bankTxnId"]) for e in ledger if e.get("bankTxnId")}
    moved = {(r["source"], r["entry_id"]): r for r in fetch(conn, "SELECT source, entry_id, tax_year, quarter, note FROM srm.tax_assignment")}
    by_line = {i["ledgerLineId"]: i for i in live if i["ledgerLineId"]}
    by_payee = {}
    for i in live:
        if i["payeeId"]:
            by_payee.setdefault(i["payeeId"], i)
    patterns = [i for i in live if i["namePattern"]]
    entries = []
    for e in ledger + [r for r in rows if (r["source"], r["entryId"]) not in claimed]:
        item = by_line.get(e["lineId"]) if e["source"] == "ledger" else by_payee.get(e["payeeId"]) or next(
            (i for i in patterns if i["namePattern"].lower() in (e["payee"] or "").lower()), None)
        if not item:
            continue
        ty, qtr = tax_period(item["section"], item["quarterly"], e["date"])
        m = moved.get((e["source"], e["entryId"]))
        if m:
            ty, qtr = m["tax_year"], m["quarter"]
        if ty != year:
            continue
        entries.append({"source": e["source"], "entryId": e["entryId"], "date": e["date"], "payee": e["payee"],
                        "description": e["description"], "register": e["register"], "amount": float(e["amount"]),
                        "itemId": item["id"], "taxYear": ty, "quarter": qtr, "moved": bool(m),
                        "note": m["note"] if m else None})
    entries.sort(key=lambda e: (e["date"], e["source"], e["entryId"]))
    # The year's summary, per item and per section.
    totals = {}
    for e in entries:
        totals[e["itemId"]] = totals.get(e["itemId"], 0) + e["amount"]
    for i in items:
        i["paid"] = round(totals.get(i["id"], 0), 2)
        i["entries"] = sum(1 for e in entries if e["itemId"] == i["id"])
        i["deductible"] = round(i["paid"] * float(i["deductibleShare"]), 2) if i["section"] in ("expense", "real_estate") else None
    payments = {j: {"q1": 0.0, "q2": 0.0, "q3": 0.0, "q4": 0.0, "other": 0.0, "total": 0.0} for j in JURISDICTIONS}
    section_of = {i["id"]: i for i in items}
    for e in entries:
        i = section_of[e["itemId"]]
        if i["section"] == "payment" and i["jurisdiction"]:
            p = payments[i["jurisdiction"]]
            p["q%d" % e["quarter"] if e["quarter"] else "other"] += e["amount"]
            p["total"] += e["amount"]
    expense = [i for i in items if i["section"] == "expense"]
    savings = [e for e in entries if section_of[e["itemId"]]["section"] == "savings"]
    summary = {
        "expensesPaid": round(sum(i["paid"] for i in expense), 2),
        "expensesDeductible": round(sum(i["deductible"] or 0 for i in expense), 2),
        "payments": {j: {k: round(v, 2) for k, v in p.items()} for j, p in payments.items()},
        "paymentsTotal": round(sum(p["total"] for p in payments.values()), 2),
        "realEstate": round(sum(i["paid"] for i in items if i["section"] == "real_estate"), 2),
        "refunds": round(-sum(i["paid"] for i in items if i["section"] == "refund"), 2),
        "savingsSetAside": round(sum(e["amount"] for e in savings if e["amount"] > 0), 2),
        "savingsTakenOut": round(-sum(e["amount"] for e in savings if e["amount"] < 0), 2),
    }
    # Registers the tax items draw on whose entries start after the year does: the year is incomplete there.
    used = {(r["source"], r["register"]) for r in rows + ledger}
    starts = fetch(conn, """
        SELECT 'bank' AS source, a.code AS register, a.name, min(b.txn_date) AS first
          FROM srm.bank_account a LEFT JOIN srm.bank_txn b ON b.bank_account_id = a.bank_account_id AND b.status <> 'void'
         GROUP BY a.code, a.name
        UNION ALL
        SELECT 'card', a.code, a.name, min(c.txn_date)
          FROM srm.card_account a LEFT JOIN srm.card_txn c ON c.card_account_id = a.card_account_id AND c.status <> 'void'
         GROUP BY a.code, a.name
        UNION ALL
        SELECT 'ledger', l.code, l.name, min(e.entry_date)
          FROM srm.expense_ledger l LEFT JOIN srm.expense_entry e ON e.ledger_id = l.ledger_id AND e.status = 'actual'
         GROUP BY l.code, l.name""")
    partial = [r for r in starts if (r["source"], r["register"]) in used and r["first"] and r["first"] > dt.date(year, 1, 7)]
    lines_all = fetch(conn, """
        SELECT ln.line_id AS id, ln.name, l.code AS ledger FROM srm.expense_line ln JOIN srm.expense_ledger l USING (ledger_id)
         WHERE ln.active ORDER BY l.code, ln.sort_order, ln.name""")
    return {"year": year, "items": items, "entries": entries, "summary": summary, "partialRegisters": partial,
            "ledgerLines": lines_all}


def save_tax_item(conn, iid, body):
    iid = int(iid)
    payee, line = _opt_int(body, "payeeId"), _opt_int(body, "ledgerLineId")
    pattern = _text(body, "namePattern", 80)
    if sum(x is not None for x in (payee, line, pattern)) != 1:
        raise ValueError("a tax item is for one payeeId, ledgerLineId or namePattern")
    label = _text(body, "label", 120)
    if not label:
        raise ValueError("label is required")
    section = body.get("section") or "expense"
    if section not in TAX_SECTIONS:
        raise ValueError("section must be one of " + ", ".join(TAX_SECTIONS))
    jurisdiction = body.get("jurisdiction") or None
    if jurisdiction and jurisdiction not in JURISDICTIONS:
        raise ValueError("jurisdiction must be federal, state or local")
    share = float(body.get("deductibleShare") if body.get("deductibleShare") not in (None, "") else 1)
    if not 0 <= share <= 1:
        raise ValueError("deductibleShare is a fraction from 0 to 1 (0.15 for 15%)")
    values = (payee, line, pattern, label, section, _text(body, "taxCategory", 60) or "Other", jurisdiction, share,
              bool(body.get("quarterly", False)), _text(body, "notes", 1000), bool(body.get("active", True)), _by(body))
    if iid == 0:
        fetch(conn, """INSERT INTO srm.tax_item (payee_id, ledger_line_id, name_pattern, label, section, tax_category,
                              jurisdiction, deductible_share, quarterly, notes, active, updated_by, sort_order)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                               (SELECT coalesce(max(sort_order), 0) + 1 FROM srm.tax_item))""", values)
    elif not fetch(conn, """UPDATE srm.tax_item SET payee_id = %s, ledger_line_id = %s, name_pattern = %s, label = %s,
                                   section = %s, tax_category = %s, jurisdiction = %s, deductible_share = %s,
                                   quarterly = %s, notes = %s, active = %s, updated_by = %s, updated_at = now()
                             WHERE item_id = %s RETURNING item_id""", values + (iid,)):
        raise LookupError("no tax item %s" % iid)
    conn.commit()


def delete_tax_item(conn, iid):
    fetch(conn, "DELETE FROM srm.tax_item WHERE item_id = %s", (int(iid),))
    conn.commit()


def assign_tax(conn, source, entry_id, body):
    if source not in SOURCES:
        raise ValueError("source must be bank, card or ledger")
    year, quarter = _opt_int(body, "taxYear"), _opt_int(body, "quarter")
    if year is None:
        fetch(conn, "DELETE FROM srm.tax_assignment WHERE source = %s AND entry_id = %s", (source, int(entry_id)))
    else:
        if quarter is not None and not 1 <= quarter <= 4:
            raise ValueError("quarter must be 1–4")
        fetch(conn, """INSERT INTO srm.tax_assignment (source, entry_id, tax_year, quarter, note, updated_by)
                       VALUES (%s, %s, %s, %s, %s, %s)
                       ON CONFLICT (source, entry_id) DO UPDATE SET tax_year = excluded.tax_year, quarter = excluded.quarter,
                              note = excluded.note, updated_by = excluded.updated_by, updated_at = now()""",
              (source, int(entry_id), year, quarter, _text(body, "note", 400), _by(body)))
    conn.commit()


# ------------------------------------------------------------------------------------------------------------ changes
# The family page's own changes (V041): an entry's category or driver (its tag) and a lifecycle trigger's category or
# kind. Each is applied at once and listed for John as a 'change' note that MxAcctMGR can undo.

KIND_TITLES = {"recurring": "Recurring", "replacement": "Replacement", "peak": "Peak event", "transition": "Transition"}
TAG_COLUMN = {"category": "category_code", "driver": "driver"}


def _signed(author):
    """Who a family-page change is from, as the tables record it ("Ann (family page)"; unnamed: "Family page")."""
    return author if "family page" in author.lower() else author + " (family page)"


def _names(conn):
    return {r["code"]: r["name"] for r in fetch(conn, "SELECT code, name FROM srm.spending_category")}


def _change_note(conn, author, tab, section, message, context, category=None, source=None, entry_id=None, client=None):
    fetch(conn, """INSERT INTO srm.spending_feedback (author, kind, tab, section, category_code, entry_source, entry_id,
                          message, context, client)
                   VALUES (%s, 'change', %s, %s, %s, %s, %s, %s, %s::jsonb, %s)""",
          (author, tab, section, category, source, entry_id, message, json.dumps(context, default=str), (client or "")[:60] or None))


def _write_tag(conn, column, entry_id, values, by):
    """An entry's tag with these values (category_code, driver, member_id, event, notes); none set removes it."""
    if not any(values.get(k) for k in ("category_code", "driver", "member_id", "event", "notes")):
        fetch(conn, "DELETE FROM srm.spending_tag WHERE %s = %%s" % column, (entry_id,))
        return
    fetch(conn, """INSERT INTO srm.spending_tag (%s, category_code, driver, member_id, event, notes, updated_by)
                   VALUES (%%s, %%s, %%s, %%s, %%s, %%s, %%s)
                   ON CONFLICT (%s) DO UPDATE SET category_code = excluded.category_code, driver = excluded.driver,
                          member_id = excluded.member_id, event = excluded.event, notes = excluded.notes,
                          updated_by = excluded.updated_by, updated_at = now()""" % (column, column),
          (entry_id, values.get("category_code"), values.get("driver"), values.get("member_id"), values.get("event"),
           values.get("notes"), by))


def change_entry(conn, source, entry_id, body, client=None):
    column = SOURCES.get(source)
    if not column:
        raise ValueError("source must be bank, card or ledger")
    author = _text(body, "author", 80)
    if not author:
        raise ValueError("author is required: who is making the change")
    fields = [f for f in ("category", "driver") if f in body]
    if not fields:
        raise ValueError("a change sets category or driver")
    entry_id = int(entry_id)
    rows = fetch(conn, _entry_sql(conn) + " WHERE source = %s AND entry_id = %s", (source, entry_id))
    if not rows:
        raise LookupError("no spending entry %s %s" % (source, entry_id))
    entry = rows[0]
    tag = fetch(conn, "SELECT category_code, driver, member_id, event, notes FROM srm.spending_tag WHERE %s = %%s" % column, (entry_id,))
    before = tag[0] if tag else {}
    values = dict(before)
    if "category" in fields:
        values["category_code"] = _category(conn, body)            # empty: follow the rules again
    if "driver" in fields:
        values["driver"] = _driver(conn, body)
    _write_tag(conn, column, entry_id, values, _signed(author))
    after = fetch(conn, _entry_sql(conn) + " WHERE source = %s AND entry_id = %s", (source, entry_id))[0]
    names, titles = _names(conn), {d["code"]: d["title"] for d in _drivers(conn)}
    show = {"category": lambda v: names.get(v, "Not assigned") if v else "Not assigned",
            "driver": lambda v: titles.get(v, "no driver") if v else "no driver"}
    what = "%s %s %s" % (entry["date"].strftime("%m/%d/%Y"), entry["payee"] or entry["description"] or "", "${:,.2f}".format(float(entry["amount"])))
    for f in fields:
        old, new = entry[f], after[f]
        if old == new:
            continue
        _change_note(conn, author, body.get("tab") or "entries", "Entry: " + what,
                     "Changed the %s of %s from %s to %s." % (f, what, show[f](old), show[f](new)),
                     {"change": "entry", "source": source, "entryId": entry_id, "field": f, "from": old, "to": new,
                      "tagBefore": before.get(TAG_COLUMN[f]), "date": entry["date"], "payee": entry["payee"],
                      "amount": float(entry["amount"]), "category": old if f == "category" else entry["category"],
                      "driver": old if f == "driver" else entry["driver"]},
                     category=after["category"], source=source, entry_id=entry_id, client=client)
    conn.commit()
    return {"entry": after}


def change_trigger(conn, tid, body, client=None):
    author = _text(body, "author", 80)
    if not author:
        raise ValueError("author is required: who is making the change")
    rows = fetch(conn, "SELECT trigger_id, name, category_code, kind FROM srm.lifecycle_trigger WHERE trigger_id = %s", (int(tid),))
    if not rows:
        raise LookupError("no lifecycle trigger %s" % tid)
    t = rows[0]
    changes = {}
    if "category" in body:
        changes["category_code"] = _category(conn, body, required=True)
    if "kind" in body:
        if body["kind"] not in KINDS:
            raise ValueError("kind must be one of " + ", ".join(KINDS))
        changes["kind"] = body["kind"]
    changes = {k: v for k, v in changes.items() if v != t[k]}
    if changes:
        fetch(conn, "UPDATE srm.lifecycle_trigger SET %s, updated_by = %%s, updated_at = now() WHERE trigger_id = %%s"
              % ", ".join("%s = %%s" % k for k in changes), tuple(changes.values()) + (_signed(author), t["trigger_id"]))
        names = _names(conn)
        for k, v in changes.items():
            field, old, new = ("category", names.get(t[k], t[k]), names.get(v, v)) if k == "category_code" else ("kind", KIND_TITLES.get(t[k], t[k]), KIND_TITLES.get(v, v))
            _change_note(conn, author, body.get("tab") or "family", "Lifecycle trigger: " + t["name"],
                         "Changed the %s of the lifecycle trigger %s from %s to %s." % (field, t["name"], old, new),
                         {"change": "trigger", "triggerId": t["trigger_id"], "field": field, "column": k,
                          "from": t[k], "to": v, "name": t["name"]},
                         category=changes.get("category_code") or t["category_code"], client=client)
    conn.commit()
    return {"triggers": fetch(conn, """
        SELECT trigger_id AS id, name, category_code AS category, kind, age_from AS "ageFrom", age_to AS "ageTo",
               every_years AS "everyYears", annual_cost AS "annualCost", notes, active
          FROM srm.lifecycle_trigger ORDER BY sort_order, age_from, name""")}


def undo_change(conn, fid, body):
    """Puts back what a family-page change replaced, and marks its note Not planned with the reply Undone."""
    rows = fetch(conn, "SELECT kind, status, context FROM srm.spending_feedback WHERE feedback_id = %s FOR UPDATE", (int(fid),))
    if not rows or rows[0]["kind"] != "change":
        raise LookupError("no change %s" % fid)
    if rows[0]["status"] == "declined":
        raise ValueError("this change has been undone already")
    c = rows[0]["context"] or {}
    if c.get("change") == "entry":
        column = SOURCES[c["source"]]
        tag = fetch(conn, "SELECT category_code, driver, member_id, event, notes FROM srm.spending_tag WHERE %s = %%s" % column, (c["entryId"],))
        values = dict(tag[0]) if tag else {}
        values[TAG_COLUMN[c["field"]]] = c.get("tagBefore")
        _write_tag(conn, column, c["entryId"], values, _by(body))
    elif c.get("change") == "trigger":
        fetch(conn, "UPDATE srm.lifecycle_trigger SET %s = %%s, updated_by = %%s, updated_at = now() WHERE trigger_id = %%s"
              % ("category_code" if c["column"] == "category_code" else "kind"), (c["from"], _by(body), c["triggerId"]))
    else:
        raise ValueError("this change can't be undone here")
    fetch(conn, """UPDATE srm.spending_feedback SET status = 'declined', reply = coalesce(reply, 'Undone.'), replied_by = %s,
                          replied_at = now() WHERE feedback_id = %s""", (_by(body), int(fid)))
    conn.commit()
    return feedback(conn)


# ------------------------------------------------------------------------------------------------------------ entries

ENTRY_TABLES = {"card": ("srm.card_txn", "srm.card_line", "card_line_id", "card"),
             "bank": ("srm.bank_txn", "srm.bank_line", "bank_line_id", "checking")}


def change_expense_account(conn, body):
    """Files card and check entries under another expense account (Entries ▸ Change Expense Account…). With
    fileFuture, what comes next lands there too: the entries' target accounts are filed under it, and entries with no
    target account get one (found by targetName, or made) whose bank names are their statement names, as the card and
    checking downloads match them. Cash-ledger entries take their budget line's expense account and can't change
    here."""
    account = _opt_int(body, "expenseAccountId")
    if not account or not fetch(conn, "SELECT 1 FROM srm.expense_account WHERE expense_account_id = %s AND kind = 'expense'",
                                (account,)):
        raise ValueError("expenseAccountId must be an expense account")
    chosen = body.get("entries") or []
    if not isinstance(chosen, list) or not chosen:
        raise ValueError("entries is a list of {source, id}")
    by = _by(body)
    rows = []
    for c in chosen:
        source = c.get("source")
        if source == "ledger":
            raise ValueError("a cash-ledger entry takes its budget line's expense account: change the line instead")
        if source not in ENTRY_TABLES:
            raise ValueError("source must be card or bank")
        table, lines, line_key, _ = ENTRY_TABLES[source]
        found = fetch(conn, """SELECT t.txn_id, t.payee_id, t.payee_name, l.name AS statement
                                 FROM %s t LEFT JOIN %s l USING (%s) WHERE t.txn_id = %%s FOR UPDATE OF t"""
                      % (table, lines, line_key), (int(c.get("id") or 0),))
        if not found:
            raise LookupError("no %s entry %s" % (source, c.get("id")))
        rows.append(dict(found[0], source=source))
    name = " ".join(str(body.get("targetName") or "").split())[:120]
    if body.get("fileFuture") and not name and any(not r["payee_id"] for r in rows):
        raise ValueError("targetName is required for entries with no target account")
    for r in rows:
        fetch(conn, """UPDATE %s SET expense_account_id = %%s, version = version + 1, updated_by = %%s, updated_at = now()
                        WHERE txn_id = %%s""" % ENTRY_TABLES[r["source"]][0], (account, by, r["txn_id"]))
    target = None
    if body.get("fileFuture"):
        # Their target accounts: filed under it from now on.
        payees = sorted({r["payee_id"] for r in rows if r["payee_id"]})
        if payees:
            fetch(conn, """UPDATE srm.payee SET expense_account_id = %s, version = version + 1, updated_by = %s,
                                  updated_at = now() WHERE payee_id = ANY(%s)""", (account, by, payees))
        loose = [r for r in rows if not r["payee_id"]]
        if loose:
            names = sorted({(r["statement"] or r["payee_name"] or "").strip() for r in loose} - {""})
            sources = sorted({ENTRY_TABLES[r["source"]][3] for r in loose})
            found = fetch(conn, "SELECT payee_id FROM srm.payee WHERE lower(name) = lower(%s)", (name,))
            if found:
                target = found[0]["payee_id"]
                fetch(conn, """UPDATE srm.payee SET expense_account_id = %s, version = version + 1, updated_by = %s,
                                      updated_at = now() WHERE payee_id = %s""", (account, by, target))
            else:
                target = fetch(conn, """INSERT INTO srm.payee (name, expense_account_id, updated_by, funding_sources)
                                        VALUES (%s, %s, %s, %s) RETURNING payee_id""", (name, account, by, sources))[0]["payee_id"]
            # The card companies' and the bank's names for it, so their downloads post to it, and the registers
            # that offer it.
            fetch(conn, """UPDATE srm.payee SET
                                  bank_names = ARRAY(SELECT DISTINCT x FROM unnest(coalesce(bank_names, '{}') || %s::text[]) x
                                                      WHERE lower(x) <> lower(name)),
                                  funding_sources = ARRAY(SELECT DISTINCT x FROM unnest(coalesce(funding_sources, '{}') || %s::text[]) x)
                            WHERE payee_id = %s""", (names, sources, target))
            for r in loose:
                fetch(conn, """UPDATE %s SET payee_id = %%s, payee_name = %%s WHERE txn_id = %%s""" % ENTRY_TABLES[r["source"]][0],
                      (target, name, r["txn_id"]))
    conn.commit()
    out = setup(conn, details=True)
    out["changed"] = len(rows)
    out["targetAccountId"] = target
    return out


# ------------------------------------------------------------------------------------------------------------ admin

def overlaps(conn):
    """Cash-ledger entries that look like a card charge or check they aren't linked to: the same amount within a
    week, the charge or check linked to no entry yet. Until linked, both count as spending. Up to three candidates
    each, nearest date first."""
    rows = fetch(conn, """
        SELECT e.entry_id AS "entryId", e.version, l.code AS ledger, e.entry_date AS date, e.vendor, e.description,
               e.amount, c.source, c.txn_id AS "txnId", c.register, c.txn_date AS "txnDate", c.payee,
               abs(c.txn_date - e.entry_date) AS days
          FROM srm.expense_entry e
          JOIN srm.expense_ledger l USING (ledger_id)
          JOIN LATERAL (
              SELECT * FROM (
                  SELECT 'card'::text AS source, t.txn_id, a.code AS register, t.txn_date,
                         coalesce(p.name, t.payee_name) AS payee
                    FROM srm.card_txn t
                    JOIN srm.card_account a USING (card_account_id)
                    LEFT JOIN srm.payee p ON p.payee_id = t.payee_id
                   WHERE t.status <> 'void' AND t.kind <> 'payment' AND t.amount = e.amount
                     AND abs(t.txn_date - e.entry_date) <= 7
                     AND NOT EXISTS (SELECT 1 FROM srm.expense_entry x WHERE x.card_txn_id = t.txn_id)
                     AND NOT srm.source_disconnected('card', a.code)
                  UNION ALL
                  SELECT 'bank', b.txn_id, a.code, b.txn_date, coalesce(p.name, b.payee_name)
                    FROM srm.bank_txn b
                    JOIN srm.bank_account a USING (bank_account_id)
                    LEFT JOIN srm.payee p ON p.payee_id = b.payee_id
                   WHERE b.status <> 'void' AND -b.amount = e.amount AND abs(b.txn_date - e.entry_date) <= 7
                     AND NOT EXISTS (SELECT 1 FROM srm.expense_entry x WHERE x.bank_txn_id = b.txn_id)
                     AND NOT srm.source_disconnected('bank', a.code)
              ) m ORDER BY abs(m.txn_date - e.entry_date), m.txn_id LIMIT 3) c ON true
         WHERE e.status = 'actual' AND e.kind IN ('expense', 'refund') AND e.card_txn_id IS NULL AND e.bank_txn_id IS NULL
           AND NOT srm.source_disconnected('ledger', l.code)
         ORDER BY e.entry_date, e.entry_id, days, c.txn_id""")
    out = {}
    for r in rows:
        o = out.setdefault(r["entryId"], dict({k: r[k] for k in ("entryId", "version", "ledger", "date", "vendor",
                                                                  "description", "amount")}, matches=[]))
        o["matches"].append({k: r[k] for k in ("source", "txnId", "register", "txnDate", "payee", "days")})
    return {"overlaps": list(out.values())}


def route(conn, method, parts, body, q):
    """The spending endpoints' answer, or None when the path isn't one of them."""
    if parts == ["spending", "setup"] and method == "GET":
        return setup(conn, details=True)
    if parts == ["spending", "analysis"] and method == "GET":
        return analysis(conn, q)
    if parts == ["spending", "overlaps"] and method == "GET":
        return overlaps(conn)
    if parts == ["spending", "expense-account"] and method == "POST":
        return change_expense_account(conn, body)
    if parts == ["spending", "sources"] and method == "GET":
        return sources(conn, q)
    if len(parts) == 4 and parts[1] == "sources" and method == "PUT":
        return set_source(conn, parts[2], parts[3], body, q)
    if parts == ["spending", "transfers"] and method == "GET":
        return transfers(conn, q)
    if len(parts) == 3 and parts[1] == "transfers" and method == "PUT":
        return file_target(conn, parts[2], body, q)
    if len(parts) == 5 and parts[1] == "sources" and parts[4] == "links" and method == "GET":
        return source_links(conn, parts[2], parts[3])
    if len(parts) == 5 and parts[1] == "sources" and parts[4] in ("disconnect", "reconnect") and method == "POST":
        return (disconnect_source if parts[4] == "disconnect" else reconnect_source)(conn, parts[2], parts[3], body, q)
    if parts == ["spending", "amazon", "load"] and method == "POST":
        return load_amazon(conn, body, q)
    if parts == ["spending", "amazon", "known"] and method == "GET":
        return amazon_known(conn, q)
    if parts == ["spending", "amazon", "attach"] and method == "POST":
        return attach_amazon(conn, body)
    if len(parts) == 5 and parts[1:3] == ["amazon", "unlink"] and method == "POST":
        return unlink_amazon(conn, parts[3], parts[4], body)
    if parts == ["spending", "feedback"]:
        if method == "GET":
            return feedback(conn, q)
        if method == "POST":
            return add_feedback(conn, body)
    if len(parts) == 3 and parts[1] == "feedback" and method == "PUT":
        return answer_feedback(conn, parts[2], body)
    if len(parts) == 4 and parts[1] == "feedback" and parts[3] == "undo" and method == "POST":
        return undo_change(conn, parts[2], body)
    if len(parts) == 5 and parts[1:3] == ["change", "entry"] and method == "PUT":
        return change_entry(conn, parts[3], parts[4], body)
    if len(parts) == 4 and parts[1:3] == ["change", "trigger"] and method == "PUT":
        return change_trigger(conn, parts[3], body)
    if parts == ["spending", "tax"] and method == "GET":
        return tax(conn, q)
    if len(parts) == 4 and parts[1:3] == ["tax", "items"]:
        if method == "PUT":
            save_tax_item(conn, parts[3], body)
        elif method == "DELETE":
            delete_tax_item(conn, parts[3])
        else:
            return None
        return tax(conn, {"year": body.get("year") or q.get("year")})
    if len(parts) == 5 and parts[1:3] == ["tax", "assign"] and method == "PUT":
        assign_tax(conn, parts[3], parts[4], body)
        return tax(conn, {"year": body.get("year") or q.get("year")})
    if parts == ["spending", "rules"] and method == "PUT":
        return save_rule(conn, body)
    if len(parts) == 4 and parts[1] == "rules" and parts[3] == "link":
        if method == "PUT":
            return save_rule_link(conn, parts[2], body)
        if method == "DELETE":
            return delete_rule_link(conn, parts[2])
    if len(parts) == 3 and parts[1] == "members":
        if method == "PUT":
            return save_member(conn, parts[2], body)
        if method == "DELETE":
            return delete_member(conn, parts[2])
    if parts == ["spending", "categories"] and method == "POST":
        return add_category(conn, body)
    if len(parts) == 3 and parts[1] == "categories":
        if method == "PUT":
            return save_category(conn, parts[2], body)
        if method == "DELETE":
            return delete_category(conn, parts[2], q)
    if len(parts) == 4 and parts[1] == "categories" and parts[3] == "usage" and method == "GET":
        return category_usage(conn, parts[2])
    if parts == ["spending", "category-order"] and method == "PUT":
        return set_order(conn, "srm.spending_category", body)
    if parts == ["spending", "drivers"] and method == "POST":
        return add_driver(conn, body)
    if len(parts) == 3 and parts[1] == "drivers":
        if method == "PUT":
            return save_driver(conn, parts[2], body)
        if method == "DELETE":
            return delete_driver(conn, parts[2], q)
    if len(parts) == 4 and parts[1] == "drivers" and parts[3] == "usage" and method == "GET":
        return driver_usage(conn, parts[2])
    if parts == ["spending", "driver-order"] and method == "PUT":
        return set_order(conn, "srm.spending_driver", body)
    if len(parts) == 3 and parts[1] == "triggers":
        if method == "PUT":
            return save_trigger(conn, parts[2], body)
        if method == "DELETE":
            return delete_trigger(conn, parts[2])
    if len(parts) == 4 and parts[1] == "tags" and method == "PUT":
        return save_tag(conn, parts[2], parts[3], body)
    return None
