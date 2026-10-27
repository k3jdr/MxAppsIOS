"""Amazon orders: what was bought behind the Amazon card charges (V046).

A card charge from Amazon reads only "AMAZON MKTPL*BD9ZG3640", and Amazon has no API for a personal account's orders.
Ask for them at amazon.com ▸ Account ▸ Request Your Data ▸ Your Orders; the e-mail's link downloads a zip
("Your Orders.zip") holding Retail.OrderHistory.1/Retail.OrderHistory.1.csv (other numbers for other Amazon sites).
Drop the zip, or its CSV files unpacked, in a folder named in amazon_orders.local.json (not in git; copy
amazon_orders.example.json):

    {"dropFolders": ["~/MyCodeGIT/MxDataSRM/src-amazon"]}

Each run reads every export there (oldest first; an order in a newer export replaces what an older one said about
it) into srm.amazon_order, amazon_shipment and amazon_item; an order whose rows haven't changed isn't rewritten. Rows
of an order with the same ship date, carrier and shipment subtotal are one shipment. The export's shipping and
billing addresses, gift messages and gift recipients are not read.

Then it matches the Amazon charges of the card registers and the check register (AMAZON MKTPL*…, AMAZON.COM*…,
AMZN.COM/BILL; not Prime memberships, Prime Video, Kindle, Audible or AWS) to what they paid for (srm.amazon_match):

  1. a shipment: Amazon charges the card when a shipment leaves, for its items' subtotal and tax (Shipment Item
     Subtotal + Shipment Item Subtotal Tax, or its items' Total Owed): the same amount, the charge dated 3 days before
     the ship date to 7 days after (an order not shipped yet: up to 30 days after the order);
  2. a whole order of several shipments charged at once: its items' Total Owed, up to 30 days after the order;
  3. 2 to 4 shipments of one order charged together, adding up to the charge;
  4. a credit (a return): one item's Total Owed, or a shipment's charge, from the ship date to 120 days after.

The closest dates win; a shipment, an order or an item goes with one charge (and one credit). When the export's
Payment Instrument Type names a card's last four digits, a charge on another card doesn't match. Matches stay from
run to run; an order whose rows changed loses its matches and is matched again.

MxAcctMGR's Amazon Order Lookup attaches orders too, from Amazon's own Transactions list (matched_by
'amazon-lookup', how 'transaction'), with what the order's page shows. Those stay when an export rewrites their order
(it replaces what the page gave), and each is narrowed to the order's shipment of the same amount when there is one.
A charge whose order was taken off it ('unlinked') isn't matched again.
"""

import collections
import csv
import datetime
import hashlib
import io
import itertools
import json
import os
import re
import zipfile

from ..common import LoadRun, debug, log

SRM_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# SRM_AMAZON_ORDERS names another one (a test's drop folders).
CONFIG_FILE = os.environ.get("SRM_AMAZON_ORDERS") or os.path.join(SRM_DIR, "amazon_orders.local.json")
DEFAULT_FOLDERS = ["~/MyCodeGIT/MxDataSRM/src-amazon"]
ORDER_FILE = re.compile(r"retail\.orderhistory\.\d+\.csv$", re.I)
REQUIRED = ("Order ID", "Order Date", "Product Name", "Total Owed")
MAX_BYTES = 200 * 1024 * 1024
NOT_GIVEN = {"", "not available", "not applicable", "n/a", "none"}

# An Amazon charge, and the Amazon charges that aren't orders (memberships, video, e-books, audiobooks, cloud).
AMAZON = re.compile(r"amazon|amzn", re.I)
NOT_ORDERS = re.compile(r"prime video|amazon prime|primevideo|prime membership|kindle|audible|web services|\baws\b|"
                        r"amazon music|amazon digital|amzn digital", re.I)

SHIP_WINDOW = (-3, 7)       # days from the ship date
ORDER_WINDOW = (-1, 30)     # days from the order date (an order, or a shipment with no ship date)
REFUND_WINDOW = (-2, 120)   # days from the ship date (else the order date)


def config():
    if not os.path.exists(CONFIG_FILE):
        return {}
    with open(CONFIG_FILE) as f:
        return json.load(f)


def drop_folders():
    return config().get("dropFolders") or DEFAULT_FOLDERS


# ------------------------------------------------------------------------------------------------------------ reading

def _cell(row, name):
    v = (row.get(name) or "").strip()
    return None if v.lower() in NOT_GIVEN else v


def _money(v):
    """A number of the export ("12.99", "'-0.50'", "$1,234.00"); None when not given."""
    v = (v or "").strip().strip("'\"").replace("$", "").replace(",", "").strip()
    if v.lower() in NOT_GIVEN:
        return None
    neg = v.startswith("(") and v.endswith(")")
    try:
        n = float(v.strip("()"))
    except ValueError:
        return None
    return round(-n if neg else n, 2)


WHEN = re.compile(r"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?\s*(Z|[+-]\d{2}:?\d{2})?$")


def _when(v):
    """A time of the export: ISO 8601 in UTC ("2024-10-21T12:19:08Z", "…T17:08:11.679Z"), or a date (MM/DD/YYYY or
    YYYY-MM-DD, taken as midnight here); None when not given."""
    v = (v or "").strip()
    if v.lower() in NOT_GIVEN:
        return None
    m = WHEN.match(v)
    if m:
        y, mo, d, h, mi, s, zone = m.groups()
        t = datetime.datetime(int(y), int(mo), int(d), int(h or 0), int(mi or 0), int(s or 0))
        if zone is None:
            return t.astimezone()
        if zone == "Z":
            return t.replace(tzinfo=datetime.timezone.utc)
        sign = -1 if zone[0] == "-" else 1
        zone = zone[1:].replace(":", "")
        return t.replace(tzinfo=datetime.timezone(sign * datetime.timedelta(hours=int(zone[:2]), minutes=int(zone[2:]))))
    for fmt in ("%m/%d/%Y", "%m/%d/%y"):
        try:
            return datetime.datetime.strptime(v, fmt).astimezone()
        except ValueError:
            pass
    return None


def _day(t):
    """The local date of a time (the card companies date charges in local time)."""
    return t.astimezone().date() if t is not None else None


def read_csv(text):
    """The item rows of an order history CSV (a dict each, headers trimmed), or None when its header isn't one."""
    reader = csv.DictReader(io.StringIO(text.lstrip("﻿")))
    header = [(h or "").strip() for h in (reader.fieldnames or [])]
    if not all(h in header for h in REQUIRED):
        return None
    reader.fieldnames = header
    return [r for r in reader if _cell(r, "Order ID")]


def _zip_texts(z, label, depth=0):
    out = []
    for info in z.infolist():
        base = os.path.basename(info.filename)
        if info.is_dir() or info.file_size > MAX_BYTES:
            continue
        if ORDER_FILE.search(base):
            out.append((label + ":" + info.filename, z.read(info).decode("utf-8-sig", errors="replace")))
        elif depth == 0 and base.lower().endswith(".zip") and "order" in base.lower():
            with zipfile.ZipFile(io.BytesIO(z.read(info))) as inner:
                out += _zip_texts(inner, label + ":" + info.filename, 1)
    return out


def texts(path):
    """[(name, text)] of the order history CSVs of one download: the CSV itself, or those in a zip (and in a zip of
    orders within it)."""
    if path.lower().endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            return _zip_texts(z, os.path.basename(path))
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        return [(os.path.basename(path), f.read())]


def downloads(folders, single=None):
    """The exports in the drop folders, oldest first: zips, and CSV files anywhere below them (an unpacked export
    keeps its folders), not in folders starting with . or _ (_removed)."""
    if single:
        return [single]
    paths = []
    for folder in folders:
        root = os.path.expanduser(folder)
        for d, dirs, names in os.walk(root):
            dirs[:] = [x for x in dirs if not x.startswith((".", "_"))]
            paths += [os.path.join(d, n) for n in names if n.lower().endswith((".zip", ".csv")) and not n.startswith(".")]
    return sorted(set(paths), key=os.path.getmtime)


def orders(rows):
    """{order id: order} of an export's rows: the order, its shipments (rows with the same ship date, carrier and
    shipment subtotal; first shipped first) and their items. Rows without a readable order date are left out."""
    by = collections.OrderedDict()
    for r in rows:
        by.setdefault(_cell(r, "Order ID"), []).append(r)
    out = {}
    for oid, rs in by.items():
        ordered = _when(_cell(rs[0], "Order Date"))
        if ordered is None:
            continue
        groups = collections.OrderedDict()
        kept = []
        for r in rs:
            item = {"name": _cell(r, "Product Name") or "(no product name)", "asin": _cell(r, "ASIN"),
                    "quantity": int(_money(r.get("Quantity")) or 0) or None, "unitPrice": _money(r.get("Unit Price")),
                    "unitTax": _money(r.get("Unit Price Tax")), "shipping": _money(r.get("Shipping Charge")),
                    "discounts": _money(r.get("Total Discounts")), "totalOwed": _money(r.get("Total Owed")),
                    "condition": _cell(r, "Product Condition")}
            key = (_cell(r, "Ship Date") or "", _cell(r, "Carrier Name & Tracking Number") or "",
                   _cell(r, "Shipment Item Subtotal") or "", _cell(r, "Shipment Item Subtotal Tax") or "")
            g = groups.setdefault(key, {"items": [], "status": None})
            g["items"].append(item)
            g["status"] = g["status"] or _cell(r, "Shipment Status")
            kept.append([oid, _cell(r, "Order Date"), _cell(r, "Order Status"), _cell(r, "Currency"),
                         _cell(r, "Payment Instrument Type"), _cell(r, "Shipment Status")] + list(key) + list(item.values()))
        shipments = []
        for (ship, carrier, sub, tax), g in groups.items():
            owed = round(sum(i["totalOwed"] or 0 for i in g["items"]), 2)
            subtotal, subtax = _money(sub), _money(tax)
            charge = round(subtotal + (subtax or 0), 2) if subtotal is not None else owed
            shipments.append({"shipped": _when(ship), "status": g["status"], "carrier": carrier or None,
                              "subtotal": subtotal, "tax": subtax, "owed": owed, "charge": charge, "items": g["items"]})
        shipments.sort(key=lambda s: (s["shipped"] is None, s["shipped"] or ordered))
        payment = _cell(rs[0], "Payment Instrument Type")
        last4 = re.search(r"(\d{4})\D*$", payment or "")
        out[oid] = {
            "id": oid, "website": _cell(rs[0], "Website"), "ordered": ordered, "currency": _cell(rs[0], "Currency"),
            "status": _cell(rs[0], "Order Status"), "payment": payment, "last4": last4.group(1) if last4 else None,
            "items": sum(len(s["items"]) for s in shipments),
            "owed": round(sum(s["owed"] for s in shipments), 2), "shipments": shipments,
            "hash": hashlib.sha1(json.dumps(sorted(kept, key=lambda k: json.dumps(k, default=str)),
                                            default=str).encode()).hexdigest()}
    return out


# ------------------------------------------------------------------------------------------------------------ saving

def save(cur, order, file_name, load_id):
    """Writes one order (replacing what an earlier export or its page said about it, and the loader's matches; the
    lookup's stay, on the order as a whole)."""
    oid = order["id"]
    cur.execute("""UPDATE srm.amazon_match SET how = 'transaction', shipment_id = NULL
                    WHERE order_id = %s AND matched_by <> 'amazon-orders' AND how <> 'unlinked'""", (oid,))
    cur.execute("DELETE FROM srm.amazon_match WHERE order_id = %s AND matched_by = 'amazon-orders'", (oid,))
    cur.execute("DELETE FROM srm.amazon_item WHERE order_id = %s", (oid,))
    cur.execute("DELETE FROM srm.amazon_shipment WHERE order_id = %s", (oid,))
    cur.execute("""INSERT INTO srm.amazon_order (order_id, website, ordered_at, currency, order_status, payment,
                                                 payment_last4, items, total_owed, content_hash, file_name, load_id)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (order_id) DO UPDATE SET origin = 'export', website = excluded.website, ordered_at = excluded.ordered_at,
                          currency = excluded.currency, order_status = excluded.order_status, payment = excluded.payment,
                          payment_last4 = excluded.payment_last4, items = excluded.items,
                          total_owed = excluded.total_owed, content_hash = excluded.content_hash,
                          file_name = excluded.file_name, load_id = excluded.load_id, updated_at = now()""",
                (oid, order["website"], order["ordered"], order["currency"], order["status"], order["payment"],
                 order["last4"], order["items"], order["owed"], order["hash"], file_name[:300], load_id))
    for seq, s in enumerate(order["shipments"], 1):
        cur.execute("""INSERT INTO srm.amazon_shipment (order_id, seq, shipped_at, shipment_status, carrier, item_subtotal,
                                                        item_tax, total_owed, charge_amount)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING shipment_id""",
                    (oid, seq, s["shipped"], s["status"], (s["carrier"] or "")[:200] or None, s["subtotal"], s["tax"],
                     s["owed"], s["charge"]))
        sid = cur.fetchone()[0]
        for i in s["items"]:
            cur.execute("""INSERT INTO srm.amazon_item (order_id, shipment_id, product_name, asin, quantity, unit_price,
                                                        unit_tax, shipping, discounts, total_owed, condition)
                           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                        (oid, sid, i["name"][:500], i["asin"], i["quantity"], i["unitPrice"], i["unitTax"],
                         i["shipping"], i["discounts"], i["totalOwed"], i["condition"]))


# ------------------------------------------------------------------------------------------------------------ matching

def is_order_charge(text):
    """Statement text of an Amazon purchase (not a membership, video, e-book, audiobook or cloud bill)."""
    return bool(AMAZON.search(text or "")) and not NOT_ORDERS.search(text or "")


CHARGES = """
    SELECT 'card' AS source, c.txn_id, c.txn_date, c.amount, a.account_last4,
           concat_ws(' ', c.payee_name, l.name, c.memo, p.name) AS text
      FROM srm.card_txn c
      JOIN srm.card_account a USING (card_account_id)
      LEFT JOIN srm.card_line l USING (card_line_id)
      LEFT JOIN srm.payee p ON p.payee_id = c.payee_id
     WHERE c.status <> 'void' AND c.kind IN ('charge', 'credit') AND c.amount <> 0
       AND concat_ws(' ', c.payee_name, l.name, c.memo, p.name) ~* '(amazon|amzn)'
       AND NOT EXISTS (SELECT FROM srm.amazon_match m WHERE m.card_txn_id = c.txn_id)
    UNION ALL
    SELECT 'bank', b.txn_id, b.txn_date, -b.amount, NULL,
           concat_ws(' ', b.payee_name, l.name, l.memo, b.memo, p.name)
      FROM srm.bank_txn b
      LEFT JOIN srm.bank_line l USING (bank_line_id)
      LEFT JOIN srm.payee p ON p.payee_id = b.payee_id
     WHERE b.status <> 'void' AND b.amount <> 0
       AND concat_ws(' ', b.payee_name, l.name, l.memo, b.memo, p.name) ~* '(amazon|amzn)'
       AND NOT EXISTS (SELECT FROM srm.amazon_match m WHERE m.bank_txn_id = b.txn_id)"""

SHIPMENTS = """
    SELECT s.shipment_id, s.order_id, s.shipped_at, s.charge_amount, s.total_owed, o.ordered_at, o.payment_last4,
           (coalesce(o.currency, 'USD') <> 'USD' OR coalesce(o.order_status, '') ~* 'cancel'
            OR coalesce(s.shipment_status, '') ~* 'cancel') AS cancelled,
           EXISTS (SELECT FROM srm.amazon_match m WHERE m.shipment_id = s.shipment_id AND m.how IN ('shipment', 'shipments'))
           OR EXISTS (SELECT FROM srm.amazon_match m WHERE m.order_id = s.order_id AND m.how = 'order') AS paid,
           EXISTS (SELECT FROM srm.amazon_match m WHERE m.shipment_id = s.shipment_id AND m.how = 'refund') AS refunded
      FROM srm.amazon_shipment s JOIN srm.amazon_order o USING (order_id)"""

ITEMS = """
    SELECT i.item_id, i.order_id, i.total_owed, s.shipped_at, o.ordered_at, o.payment_last4
      FROM srm.amazon_item i
      JOIN srm.amazon_shipment s USING (shipment_id)
      JOIN srm.amazon_order o ON o.order_id = i.order_id
     WHERE i.total_owed > 0 AND coalesce(o.currency, 'USD') = 'USD'
       AND NOT EXISTS (SELECT FROM srm.amazon_match m WHERE m.item_id = i.item_id)
       AND NOT EXISTS (SELECT FROM srm.amazon_match m WHERE m.shipment_id = i.shipment_id AND m.how = 'refund')"""


def _cents(x):
    return int(round(float(x) * 100))


def _card_fits(charge, last4):
    """Not a charge on another card than the one the order names."""
    return not (charge["last4"] and last4 and charge["last4"] != last4)


def _within(days, window):
    return window[0] <= days <= window[1]


def match(cur, load_id):
    """Matches the Amazon charges, debits and credits not matched yet; returns {how: count} of the new matches."""
    cur.execute(CHARGES)
    cols = [d[0] for d in cur.description]
    charges = [dict(zip(cols, r)) for r in cur.fetchall()]
    charges = [dict(c, cents=_cents(c["amount"]), last4=c["account_last4"]) for c in charges if is_order_charge(c["text"])]
    cur.execute(SHIPMENTS)
    cols = [d[0] for d in cur.description]
    ships = [dict(zip(cols, r)) for r in cur.fetchall()]
    for s in ships:
        s["shipped"], s["ordered"] = _day(s["shipped_at"]), _day(s["ordered_at"])
    used = {"charge": set(), "ship": set(), "order": set(), "item": set(), "refund": set()}
    made = collections.Counter()

    # The lookup's charges (an order as a whole): to the order's shipment of the same amount, when one is free.
    cur.execute("""SELECT m.match_id, m.order_id, coalesce(c.amount, -b.amount) AS amount
                     FROM srm.amazon_match m
                     LEFT JOIN srm.card_txn c ON c.txn_id = m.card_txn_id
                     LEFT JOIN srm.bank_txn b ON b.txn_id = m.bank_txn_id
                    WHERE m.how = 'transaction' AND m.shipment_id IS NULL""")
    for match_id, order_id, amount in cur.fetchall():
        if amount is None or amount <= 0:
            continue
        for s in ships:
            if (s["order_id"] == order_id and not s["paid"] and not s["cancelled"] and s["shipment_id"] not in used["ship"]
                    and _cents(amount) in {_cents(s["charge_amount"]), _cents(s["total_owed"])}):
                cur.execute("UPDATE srm.amazon_match SET how = 'shipment', shipment_id = %s WHERE match_id = %s",
                            (s["shipment_id"], match_id))
                used["ship"].add(s["shipment_id"])
                made["narrowed"] += 1
                break
    free = [s for s in ships if not s["cancelled"] and not s["paid"] and float(s["charge_amount"]) > 0
            and s["shipment_id"] not in used["ship"]]

    def assign(pairs):
        for days, tier, c, how, things, offset in sorted(pairs, key=lambda p: (p[0], p[1], p[2]["txn_id"])):
            key = (c["source"], c["txn_id"])
            if key in used["charge"]:
                continue
            if how in ("shipment", "shipments", "order") and any(s["shipment_id"] in used["ship"] for s in things):
                continue
            if how == "order" and things[0]["order_id"] in used["order"]:
                continue
            if how == "refund" and (things[0].get("item_id") in used["item"]
                                    or ("item_id" not in things[0] and things[0]["shipment_id"] in used["refund"])):
                continue
            used["charge"].add(key)
            card, bank = (c["txn_id"], None) if c["source"] == "card" else (None, c["txn_id"])
            if how == "order":
                used["order"].add(things[0]["order_id"])
                used["ship"].update(s["shipment_id"] for s in things)
                rows = [(things[0]["order_id"], None, None)]
            elif how == "refund":
                t = things[0]
                if "item_id" in t:
                    used["item"].add(t["item_id"])
                    rows = [(t["order_id"], None, t["item_id"])]
                else:
                    used["refund"].add(t["shipment_id"])
                    rows = [(t["order_id"], t["shipment_id"], None)]
            else:
                used["ship"].update(s["shipment_id"] for s in things)
                rows = [(s["order_id"], s["shipment_id"], None) for s in things]
            for order_id, shipment_id, item_id in rows:
                cur.execute("""INSERT INTO srm.amazon_match (card_txn_id, bank_txn_id, order_id, shipment_id, item_id, how,
                                                             days, matched_by, load_id)
                               VALUES (%s, %s, %s, %s, %s, %s, %s, 'amazon-orders', %s)""",
                            (card, bank, order_id, shipment_id, item_id, how, offset, load_id))
            made[how] += 1

    # 1 and 2: a shipment, or a whole order of several shipments.
    by_amount = collections.defaultdict(list)
    for s in free:
        for amount in {_cents(s["charge_amount"]), _cents(s["total_owed"])}:
            by_amount[amount].append(s)
    by_order = collections.defaultdict(list)
    for s in ships:
        if not s["cancelled"]:
            by_order[s["order_id"]].append(s)
    whole = collections.defaultdict(list)
    for oid, group in by_order.items():
        if len(group) > 1 and not any(s["paid"] for s in group):
            for amount in {sum(_cents(s["total_owed"]) for s in group), sum(_cents(s["charge_amount"]) for s in group)}:
                whole[amount].append(group)
    pairs = []
    for c in charges:
        if c["cents"] <= 0:
            continue
        for s in by_amount.get(c["cents"], []):
            if not _card_fits(c, s["payment_last4"]):
                continue
            days = (c["txn_date"] - (s["shipped"] or s["ordered"])).days
            if _within(days, SHIP_WINDOW if s["shipped"] else ORDER_WINDOW):
                pairs.append((abs(days), 0, c, "shipment", [s], days))
        for group in whole.get(c["cents"], []):
            days = (c["txn_date"] - group[0]["ordered"]).days
            if _card_fits(c, group[0]["payment_last4"]) and _within(days, ORDER_WINDOW):
                pairs.append((abs(days), 1, c, "order", group, days))
    assign(pairs)

    # 3: several shipments of one order charged together.
    left = [c for c in charges if c["cents"] > 0 and (c["source"], c["txn_id"]) not in used["charge"]]
    if left:
        combos = collections.defaultdict(list)
        for oid, group in by_order.items():
            open_ = [s for s in group if not s["paid"] and s["shipment_id"] not in used["ship"]
                     and s["shipped"] and float(s["charge_amount"]) > 0]
            if not 2 <= len(open_) <= 8:
                continue
            for k in range(2, min(4, len(open_)) + 1):
                for combo in itertools.combinations(open_, k):
                    combos[sum(_cents(s["charge_amount"]) for s in combo)].append(combo)
        pairs = []
        for c in left:
            for combo in combos.get(c["cents"], []):
                first, last = min(s["shipped"] for s in combo), max(s["shipped"] for s in combo)
                days = (c["txn_date"] - last).days
                if (_card_fits(c, combo[0]["payment_last4"]) and (c["txn_date"] - first).days >= SHIP_WINDOW[0]
                        and days <= SHIP_WINDOW[1]):
                    pairs.append((abs(days), 2, c, "shipments", list(combo), days))
        assign(pairs)

    # 4: credits — a returned item, or a shipment.
    credits = [c for c in charges if c["cents"] < 0]
    if credits:
        cur.execute(ITEMS)
        cols = [d[0] for d in cur.description]
        items = collections.defaultdict(list)
        for r in cur.fetchall():
            i = dict(zip(cols, r))
            i["since"] = _day(i["shipped_at"]) or _day(i["ordered_at"])
            items[_cents(i["total_owed"])].append(i)
        refundable = collections.defaultdict(list)
        for s in ships:
            if not s["cancelled"] and not s["refunded"] and float(s["charge_amount"]) > 0:
                refundable[_cents(s["charge_amount"])].append(s)
        pairs = []
        for c in credits:
            for i in items.get(-c["cents"], []):
                days = (c["txn_date"] - i["since"]).days
                if _card_fits(c, i["payment_last4"]) and _within(days, REFUND_WINDOW):
                    pairs.append((abs(days), 0, c, "refund", [i], days))
            for s in refundable.get(-c["cents"], []):
                days = (c["txn_date"] - (s["shipped"] or s["ordered"])).days
                if _card_fits(c, s["payment_last4"]) and _within(days, REFUND_WINDOW):
                    pairs.append((abs(days), 1, c, "refund", [{"order_id": s["order_id"], "shipment_id": s["shipment_id"]}], days))
        assign(pairs)
    return made, [c for c in charges if (c["source"], c["txn_id"]) not in used["charge"]]


def run(conn, cfg, args):
    single = getattr(args, "file", None)
    folders = drop_folders()
    with LoadRun(conn, "AMAZON_ORDERS", "amazon_orders", {"folders": folders, "file": single}) as run, conn.cursor() as cur:
        found = {}
        files = 0
        for path in downloads(folders, single):
            try:
                parts = texts(path)
            except (OSError, zipfile.BadZipFile) as e:
                log(f"  can't read {path}: {e}")
                continue
            for name, text in parts:
                rows = read_csv(text)
                if rows is None:
                    debug(f"  {name}: not an Amazon order history (no {', '.join(REQUIRED)} columns)")
                    continue
                files += 1
                run.read += len(rows)
                read = orders(rows)
                for oid in {r.get("Order ID", "").strip() for r in rows} - set(read):
                    run.reject(f"{name}:{oid}", "no readable Order Date")
                for oid, order in read.items():
                    found[oid] = (order, name)       # a newer export replaces an older one's order
                debug(f"  {name}: {len(rows)} item rows, {len(read)} orders")
        cur.execute("SELECT order_id, content_hash FROM srm.amazon_order")
        known = dict(cur.fetchall())
        new = changed = 0
        for oid, (order, name) in found.items():
            if known.get(oid) == order["hash"]:
                continue
            save(cur, order, name, run.load_id)
            new += oid not in known
            changed += oid in known
        made, unmatched = match(cur, run.load_id)
        conn.commit()
        cur.execute("""SELECT count(*), min(ordered_at)::date, max(ordered_at)::date FROM srm.amazon_order""")
        total, first, last = cur.fetchone()
        run.inserted += new
        run.updated += changed
        matched = sum(n for how, n in made.items() if how != "narrowed")
        # Unmatched entries the export could have matched: those dated from its first order to a week after its last.
        dated = [c for c in unmatched if first and first <= c["txn_date"] <= last + datetime.timedelta(days=7)]
        left = sum(1 for c in dated if c["cents"] > 0)
        credits_left = len(dated) - left
        if not files:
            run.message = (f"no Amazon order export in {', '.join(folders)} (Request Your Data ▸ Your Orders); "
                           f"{total} orders kept; ")
        else:
            run.message = f"{files} export file(s): {len(found)} orders ({new} new, {changed} changed), {total} kept"
            run.message += f" ({first} – {last}); " if total else "; "
        run.message += (f"{matched} Amazon entries matched now ({made['shipment']} to a shipment, {made['order']} to an "
                        f"order, {made['shipments']} to several shipments, {made['refund']} credits to returns"
                        + (f"; {made['narrowed']} looked-up charges narrowed to their shipment" if made["narrowed"] else "") + "); "
                        f"{left} charges and {credits_left} credits in the export's dates not matched")
        log("  " + run.message)
