"""Secure accounts for the accounts service: the products and services held an account with (V035).

    GET  /secure-accounts                        every secure account
    PUT  /secure-accounts/<id>                   create (id 0) or change one {version, name, description, serviceUrl,
                                                 serviceApi, status, ownerUserName, paymentDate, paymentAmount,
                                                 renewalDate, renewalAmount, renewalStatus, by}: refused (409) when
                                                 someone changed it since, or when another one has the name

A change keeps the saved value of each field it doesn't send, so Edit Name sends only the name. Names are unique
whatever their case. The product key, the service key and the password are never sent here: MxAcctMGR keeps them in
the Keychain of the Mac they are entered on.
"""

from bank import Conflict, fetch, _date, _num

STATUSES = ("active", "inactive", "closed")
RENEWALS = ("auto", "renew", "decline")
# The columns save writes, in order.
COLUMNS = ("name", "description", "service_url", "service_api", "status", "owner_user_name", "payment_date",
           "payment_amount", "renewal_date", "renewal_amount", "renewal_status", "updated_by")


def secure_accounts(conn):
    rows = fetch(conn, """
        SELECT secure_account_id AS id, name, description, service_url AS "serviceUrl", service_api AS "serviceApi",
               status, owner_user_name AS "ownerUserName", payment_date AS "paymentDate",
               payment_amount AS "paymentAmount", renewal_date AS "renewalDate", renewal_amount AS "renewalAmount",
               renewal_status AS "renewalStatus", version, updated_by AS "updatedBy", updated_at AS "updatedAt"
          FROM srm.secure_account ORDER BY lower(name)""")
    return {"secureAccounts": rows}


def save(conn, sid, body):
    """A secure account, created (id 0) or changed from the version it was read at."""
    sid = int(sid)
    cur = {}
    if sid != 0:
        rows = fetch(conn, "SELECT * FROM srm.secure_account WHERE secure_account_id = %s FOR UPDATE", (sid,))
        if not rows:
            raise LookupError("no secure account %s" % sid)
        cur = rows[0]
        if int(body.get("version", -1)) != cur["version"]:
            conn.rollback()
            raise Conflict("%s changed this secure account since you opened it" % (cur["updated_by"] or "someone"),
                           version=cur["version"])
    name = (body.get("name") if "name" in body else cur.get("name")) or ""
    name = name.strip()
    if not name:
        raise ValueError("name is required")
    if fetch(conn, "SELECT 1 FROM srm.secure_account WHERE lower(name) = lower(%s) AND secure_account_id <> %s",
             (name, sid)):
        conn.rollback()
        raise Conflict("there is already a secure account named %s" % name, version=cur.get("version"))

    def text(column, n, key):
        return cur.get(column) if key not in body else (str(body[key] or "")).strip()[:n] or None

    def amount(column, key):
        return cur.get(column) if key not in body else (_num(body[key], key) if body[key] not in (None, "") else None)

    def day(column, key):
        return cur.get(column) if key not in body else (_date(body[key], key) if body[key] else None)

    status = body.get("status", cur.get("status", "active"))
    if status not in STATUSES:
        raise ValueError("status must be one of " + ", ".join(STATUSES))
    renewal = body.get("renewalStatus", cur.get("renewal_status", "auto"))
    if renewal not in RENEWALS:
        raise ValueError("renewalStatus must be one of " + ", ".join(RENEWALS))
    values = dict(
        name=name[:120], description=text("description", 2000, "description"),
        service_url=text("service_url", 500, "serviceUrl"), service_api=text("service_api", 500, "serviceApi"),
        status=status, owner_user_name=text("owner_user_name", 200, "ownerUserName"),
        payment_date=day("payment_date", "paymentDate"), payment_amount=amount("payment_amount", "paymentAmount"),
        renewal_date=day("renewal_date", "renewalDate"), renewal_amount=amount("renewal_amount", "renewalAmount"),
        renewal_status=renewal, updated_by=str(body.get("by") or "MxAcctMGR")[:80])
    row = tuple(values[c] for c in COLUMNS)
    if sid == 0:
        rows = fetch(conn, "INSERT INTO srm.secure_account (%s) VALUES (%s) RETURNING secure_account_id AS id"
                     % (", ".join(COLUMNS), ", ".join(["%s"] * len(COLUMNS))), row)
        sid = rows[0]["id"]
    else:
        fetch(conn, "UPDATE srm.secure_account SET %s, version = version + 1, updated_at = now() WHERE secure_account_id = %%s"
              % ", ".join("%s = %%s" % c for c in COLUMNS), row + (sid,))
    conn.commit()
    return dict(secure_accounts(conn), id=sid)


def route(conn, method, parts, body, q):
    """The secure accounts endpoints' answer, or None when the path isn't one of them."""
    if parts == ["secure-accounts"] and method == "GET":
        return secure_accounts(conn)
    if len(parts) == 2 and parts[0] == "secure-accounts" and method == "PUT":
        return save(conn, parts[1], body)
    return None
