"""Amazon's order e-mails: what was bought behind the Amazon card charges, from your own mailbox (V055).

Amazon e-mails each order it confirms (auto-confirm@amazon.com, "Ordered: …"), each shipment it sends
(shipment-tracking@amazon.com, "Shipped: …"), each cancellation (order-update@amazon.com) and each refund
(payments-messages@ "Refund on order …", return@ "Advance refund issued …"). This reads them from your Gmail through the
Gmail API, read-only (connect it once with ./srm.py gmail-auth; see srmlib/gmail.py), and from Google Takeout .mbox
files in Amazon's drop folders (amazon_orders.local.json, as the export's), or one --file (.mbox or .eml). Settings,
all optional, in amazon_orders.local.json:

    {"dropFolders": ["~/MyCodeGIT/MxDataSRM/src-amazon"],
     "email": {"since": "2024-10-01", "gmail": true}}

Each run reads only the messages it hasn't read (--force: every one again), from `since` on (--since DATE). Each is
kept in srm.amazon_email once — what it is and what it says (order numbers, items, quantities, unit prices, totals, a
refund's amount and whether it went to the card; not the addresses) — and each order is built from all its e-mails
into srm.amazon_order (origin 'email'), amazon_shipment and amazon_item. What Amazon's e-mails give (2025–2026):

  * an order e-mail: the order's Grand Total (older ones: Order Total), and its item — name, quantity, unit price —
    only when it has one; an order of several items is summed up ("2 items: Sunglasses"). One e-mail may confirm
    several orders of one checkout, each with its own total;
  * a shipment e-mail: the shipment's Total, tax included — what Amazon charges the card when it leaves — and mostly
    its items (older ones: Shipment total, no items);
  * a cancellation: the order, or the items it names, taken off; a refund: its amount, and whether it went to the card
    or to the Amazon balance (no card credit then).

So each shipment e-mail is a shipment of its own total on the day it came, with the items it names; until one comes,
the order is one unshipped shipment of its total (matched up to 30 days after the order). Items no e-mail names come
from the order's page when the Order Lookup read it, else the e-mail's summary stands for them (condition 'summary':
the lookup reads such an order's page, and its items take the summary's place).

An order Amazon's export has (origin 'export') is left as the export gave it: the export is fuller, and an export read
later replaces an e-mail's order. An order the Order Lookup read from its page becomes the e-mails' (keeping its items
and the card it named). Then each credit is matched to the refund e-mail of the same amount (5 days before it to 14
after; the item it names, else the order), and the rest as amazon-orders matches them (its match(), matched_by
'amazon-email' for these orders).
"""

import collections
import datetime
import email
import email.policy
import email.utils
import hashlib
import html.parser
import json
import mailbox
import os
import re
import urllib.parse

from .. import gmail
from ..common import LoadRun, debug, log
from . import amazon_orders

PARSER = 1          # a newer reading reads every kept e-mail again
DEFAULT_SINCE = "2024-10-01"
# Who sends what: orders, shipments (and deliveries), cancellations (and changes), refunds and returns.
SENDERS = ("auto-confirm@amazon.com", "shipment-tracking@amazon.com", "order-update@amazon.com",
           "payments-messages@amazon.com", "return@amazon.com", "returns@amazon.com")
ORDER_ID = re.compile(r"\b(\d{3}-\d{7}-\d{7})\b")
# "$1,234.56", "$119", "126.14 USD", "58.279999999999994 USD"
AMOUNT = re.compile(r"(-)?\$\s?(\d[\d,]*(?:\.\d+)?)|(-)?(\d[\d,]*(?:\.\d+)?)\s*USD\b")
INVISIBLE = dict.fromkeys(map(ord, "­͏​‌‍‎‏‪‫‬‭‮"
                                   "⁦⁧⁨⁩﻿"))
REFUND_WINDOW = (-5, 14)    # days from the refund e-mail to the credit


def settings():
    return amazon_orders.config().get("email") or {}


# ------------------------------------------------------------------------------------------------------------ text

class _Text(html.parser.HTMLParser):
    """An HTML e-mail's words, a line per block, and its links' targets with their words (an image's alt text too)."""
    BLOCK = {"p", "div", "br", "tr", "td", "th", "li", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6",
             "section", "header", "footer", "center", "blockquote", "hr"}
    SKIP = {"style", "script", "head", "title"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts, self.links, self.skip, self.href, self.link_text = [], [], 0, None, []

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
        elif tag in self.BLOCK:
            self.parts.append("\n")
        if tag == "a":
            self.href, self.link_text = dict(attrs).get("href"), []
        elif tag == "img" and self.href is not None and dict(attrs).get("alt"):
            self.link_text.append(dict(attrs)["alt"])

    def handle_endtag(self, tag):
        if tag in self.SKIP:
            self.skip = max(0, self.skip - 1)
        elif tag in self.BLOCK:
            self.parts.append("\n")
        if tag == "a" and self.href is not None:
            self.links.append((self.href, " ".join(" ".join(self.link_text).split())))
            self.href = None

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)
            if self.href is not None:
                self.link_text.append(data)


ASIN = re.compile(r"/(?:dp|gp/product|gp/aw/d|exec/obidos/ASIN)/([A-Z0-9]{10})(?:[/?&%)]|$)")


def asin_of(href):
    """The ASIN a product link points to, through Amazon's redirects (…/gp/r.html?…&U=https%3A%2F%2F…%2Fdp%2FB0…)."""
    for _ in range(3):
        m = ASIN.search(href or "")
        if m:
            return m.group(1)
        href = urllib.parse.unquote(href or "")
    return None


def _unmangle(text):
    """UTF-8 read as Latin-1 or Windows-1252 ("Order # â«111-…", some of Amazon's late-2025 e-mails), put right."""
    if not re.search("[âÃÂ][\x80-\xbf\u0152-\u2122«»]", text):
        return text
    for enc in ("cp1252", "latin-1"):
        try:
            return text.encode(enc).decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            pass
    return text


URL_BITS = re.compile(r"https?%3A%2F%2F|^[:&?=][^\s]*$|^[^\s]*(?:%[0-9A-F]{2}){3}[^\s]*$")


def _lines(text):
    """A text's lines, trimmed, without empty ones or links: a link to a product, on its own line or in pieces where
    the text wraps it, becomes an "ASIN: …" line."""
    out = []
    for line in _unmangle(text).translate(INVISIBLE).replace("\r", "").replace("\xa0", " ").split("\n"):
        line = " ".join(line.split())
        if not line:
            continue
        bare = re.fullmatch(r"\(?<?https?://\S+?>?\)?", line) or URL_BITS.search(line)
        if bare or "<http" in line:
            a = asin_of(line)
            if a:
                out.append("ASIN: " + a)
            line = re.sub(r"<https?://\S*>?", "", line).strip() if not bare else ""
            if not line:
                continue
        out.append(line)
    return out


def body(msg):
    """(the message's lines, [(link target, link words)]): its plain-text part's lines — Amazon's lay an order out a
    line at a time: "* name", "Quantity: 3", "9 USD", "Grand Total:", "28.62 USD" — else its HTML part's; and the HTML
    part's links, for the items' ASINs."""
    links, html_lines = [], []
    part = msg.get_body(preferencelist=("html",))
    if part is not None:
        p = _Text()
        try:
            p.feed(part.get_content())
            p.close()
            html_lines = _lines("".join(p.parts))
        except (LookupError, ValueError):
            pass
        links = p.links
    part = msg.get_body(preferencelist=("plain",))
    if part is not None:
        try:
            lines = _lines(part.get_content())
        except (LookupError, ValueError):
            lines = []
        if lines:
            return lines, links
    return html_lines, links


def money(text, price=False):
    """The first amount in a text as a number (to the cent), else None. An item's price written "$4795" (dollars and
    the cents raised, run together) is $47.95."""
    m = AMOUNT.search(text or "")
    if not m:
        return None
    digits = (m.group(2) or m.group(4)).replace(",", "")
    n = round(int(digits) / 100 if price and m.group(2) and digits.isdigit() and len(digits) >= 3 else float(digits), 2)
    return -n if (m.group(1) or m.group(3)) else n


def labelled(lines, *labels):
    """The amount after the first line that starts with a label (the first label first): on the same line, else alone
    on the next one."""
    for label in labels:
        pattern = re.compile(r"^(?:" + label + r")\s*:?", re.I)
        for i, line in enumerate(lines):
            m = pattern.match(line)
            if not m:
                continue
            rest = line[m.end():]
            v = money(rest) if AMOUNT.match(rest.strip()) else None
            if v is None and not rest.strip() and i + 1 < len(lines) and AMOUNT.fullmatch(lines[i + 1].strip()):
                v = money(lines[i + 1])
            if v is not None:
                return v
    return None


TOTAL = ("grand total", "order total", "shipment total", r"total(?! before| savings| refund)")


# ------------------------------------------------------------------------------------------------------------ reading

def _same(a, b):
    """Two items are one: the same ASIN, else the same name (an e-mail may cut a long name short with "...")."""
    if a.get("asin") and b.get("asin"):
        return a["asin"] == b["asin"]
    x, y = ((v.get("name") or "").lower().rstrip(".… ") for v in (a, b))
    return bool(x and y) and (x == y or (min(len(x), len(y)) >= 15 and (x.startswith(y) or y.startswith(x))))


def _link_asin(name, links):
    for href, words in links:
        a = asin_of(href)
        if a and words and _same({"name": name}, {"name": words}):
            return a
    return None


NOT_NAME = re.compile(r"^(?:order\s*#|order number|view|arriving|ship(?:ped)? to|track|grand total|order total|total|"
                      r"quantity|qty|sold by|cancel|placed|deliver|your |thanks|hello|hi |asin:|\$|\d+(?:\.\d+)? usd)"
                      r"|\s-\s[A-Z .'-]+, [A-Z]{2}$", re.I)


def items(lines, links):
    """What an e-mail's lines name as bought: [{name, asin, quantity, price (each)}] — "* name" lines with the
    "Quantity: n" and price after them; else a name, its "ASIN: …", "Quantity: n" and price; "[name](product link)";
    a name and its "ASIN: …" (a cancellation); and "Item: name Quantity: n ASIN: …" (a refund)."""
    out = []

    def add(name, asin=None, quantity=None, price=None):
        name = (name or "").strip().strip('"“”')
        if len(name) < 3:
            return
        item = {"name": name[:500], "asin": asin or _link_asin(name, links), "quantity": quantity, "price": price}
        if not any(_same(item, x) for x in out):
            out.append(item)

    for i, line in enumerate(lines):
        if line.startswith("* "):
            qty = price = None
            for nxt in lines[i + 1:i + 5]:
                if nxt.startswith("* "):
                    break
                q = re.match(r"^(?:quantity|qty)\s*:?\s*(\d+)", nxt, re.I)
                if q and qty is None:
                    qty = int(q.group(1))
                elif price is None and AMOUNT.fullmatch(nxt):
                    price = money(nxt, price=True)
            add(line[2:], quantity=qty, price=price)
            continue
        q = re.fullmatch(r"(?:quantity|qty)\s*:?\s*(\d+)", line, re.I)
        if q and not any(lines[j].startswith("* ") for j in range(max(0, i - 3), i)):
            asin = name = None
            for j in range(i - 1, max(-1, i - 5), -1):
                a = re.fullmatch(r"ASIN: ([A-Z0-9]{10})", lines[j])
                if a:
                    asin = asin or a.group(1)
                    continue
                if not NOT_NAME.search(lines[j]):
                    name = lines[j]
                    if j > 0 and re.fullmatch(r"ASIN: ([A-Z0-9]{10})", lines[j - 1]) and not asin:
                        asin = lines[j - 1][6:]
                break
            nxt = lines[i + 1] if i + 1 < len(lines) else ""
            if name:
                add(name, asin, int(q.group(1)), money(nxt, price=True) if AMOUNT.fullmatch(nxt) else None)
            continue
        for name, href in re.findall(r"\[([^\]]{3,})\]\((https?://[^)\s]+)\)", line):
            if asin_of(href):
                q = re.search(r"quantity:\s*(\d+)", lines[i + 1] if i + 1 < len(lines) else "", re.I)
                add(name, asin_of(href), int(q.group(1)) if q else None)
        m = re.search(r"\bItem:\s*(.+?)\s+Quantity:\s*(\d+)(?:\s+ASIN:\s*([A-Z0-9]{10}))?", line)
        if m:
            add(m.group(1), m.group(3), int(m.group(2)))
        m = re.fullmatch(r"ASIN: ([A-Z0-9]{10})", line)
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if (m and i > 0 and not NOT_NAME.search(lines[i - 1]) and not re.match(r"(?:quantity|qty)\b", nxt, re.I)
                and not (i + 2 < len(lines) and re.match(r"(?:quantity|qty)\b", lines[i + 2], re.I))):
            add(lines[i - 1], m.group(1))
    return out


ORDER_LINE = re.compile(r"^(?:order\s*#|order number)\s*:?\s*\(?(?:.{0,3}?(\d{3}-\d{7}-\d{7})|\s*$)", re.I)


def blocks(lines):
    """[(order id, its lines)]: from each "Order #" line to the next one of another order (one order's several "Order
    #" lines are one block)."""
    marks = []
    for i, line in enumerate(lines):
        m = ORDER_LINE.match(line)
        if not m:
            continue
        oid = m.group(1)
        if oid is None and i + 1 < len(lines):
            n = ORDER_ID.match(lines[i + 1])
            oid = n.group(1) if n else None
        if oid:
            marks.append((i, oid))
    out = []
    for n, (i, oid) in enumerate(marks):
        part = lines[i:marks[n + 1][0] if n + 1 < len(marks) else len(lines)]
        if out and out[-1][0] == oid:
            out[-1][1].extend(part)
        else:
            out.append((oid, list(part)))
    return out


def kind_of(sender, subject):
    s = (subject or "").lower()
    if sender.startswith("auto-confirm@"):
        return "order"
    if sender.startswith("shipment-tracking@"):
        return "shipment" if re.search(r"^shipped\b|has shipped|was shipped|have shipped", s) else "other"
    if sender.startswith("order-update@") and re.search(
            r"cancell?ed successfully|successful cancell?ation|(?:has been|was) cancell?ed|order cancell?ed", s):
        return "cancel"
    if re.search(r"\brefund", s) and not re.search(r"dropoff|request confirmed", s):
        return "refund"
    return "other"


def summary(subject, lines):
    """How the e-mail sums its items up when it doesn't name them: "2 items: Sunglasses", "Philips SatinShave... and
    1 more item"."""
    m = re.match(r"^(?:ordered|shipped|delivered)\s*:?\s*(.+)$", (subject or "").translate(INVISIBLE).strip(), re.I)
    if m:
        return " ".join(m.group(1).split())[:300]
    for i, line in enumerate(lines[:-1]):
        if re.match(r"^on the way:?$", line, re.I):
            return lines[i + 1][:300]
    return None


def read(raw, received_ms=None):
    """One e-mail: {key, received, sender, subject, kind, orders, amount, facts}. facts: {orders: {id: {items,
    total}}, summary, whole (a cancellation of the whole order)} — or a refund's {refund, toCard, items}."""
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    sender = email.utils.parseaddr(str(msg.get("From") or ""))[1].lower()
    subject = " ".join(str(msg.get("Subject") or "").translate(INVISIBLE).split())
    key = str(msg.get("Message-ID") or "").strip() or "sha1:" + hashlib.sha1(raw).hexdigest()
    try:
        received = email.utils.parsedate_to_datetime(str(msg.get("Date")))
    except (TypeError, ValueError, IndexError):
        received = None
    if received is None or received.tzinfo is None:
        received = (datetime.datetime.fromtimestamp(received_ms / 1000, datetime.timezone.utc) if received_ms
                    else (received or datetime.datetime.now()).astimezone())
    kind = kind_of(sender, subject)
    lines, links = (body(msg) if kind != "other" else ([], []))
    order_ids = list(collections.OrderedDict.fromkeys(ORDER_ID.findall(subject + "\n" + "\n".join(lines))))
    facts, amount = {}, None
    found = blocks(lines) if kind in ("order", "shipment", "cancel") else []
    if found:      # its own orders: not another order a link names (a shipment's invoice of two orders)
        order_ids = list(collections.OrderedDict.fromkeys(oid for oid, _ in found))
    if kind in ("order", "shipment", "cancel") and order_ids:
        per = collections.OrderedDict()
        for oid, part in found or [(order_ids[0], lines)]:
            f = per.setdefault(oid, {"items": [], "total": None})
            for i in items(part, links):
                if not any(_same(i, x) for x in f["items"]):
                    f["items"].append(i)
            if f["total"] is None:
                f["total"] = labelled(part, *TOTAL)
        facts = {"orders": per, "summary": summary(subject, lines)}
        if kind == "cancel":
            facts["whole"] = bool(re.search(r"your order (?:was|has been)(?: successfully)? cancell?ed",
                                            " ".join(lines), re.I))
        totals = [f["total"] for f in per.values()]
        amount = round(sum(totals), 2) if totals and None not in totals else None
    elif kind == "refund":
        text = " ".join(lines)
        m = (re.search(r"refund of \$\s?([\d,]+\.\d{2})", text, re.I)
             or re.search(r"total refund\*?\s*:?\s*\$\s?([\d,]+\.\d{2})", text, re.I)
             or re.search(r"refund (?:total|subtotal)\s*:?\s*\$\s?([\d,]+\.\d{2})", text, re.I))
        amount = round(float(m.group(1).replace(",", "")), 2) if m else None
        facts = {"refund": amount, "items": items(lines, links),
                 "toCard": not re.search(r"to your amazon (?:account|gift card) balance", text, re.I)}
    return {"key": key[:500], "received": received, "sender": sender[:200], "subject": subject[:500], "kind": kind,
            "orders": order_ids, "amount": amount, "facts": facts}


# ------------------------------------------------------------------------------------------------------------ messages

def mbox_files(folders, single=None):
    if single:
        return [single]
    paths = []
    for folder in folders:
        for d, dirs, names in os.walk(os.path.expanduser(folder)):
            dirs[:] = [x for x in dirs if not x.startswith((".", "_"))]
            paths += [os.path.join(d, n) for n in names if n.lower().endswith((".mbox", ".eml")) and not n.startswith(".")]
    return sorted(set(paths), key=os.path.getmtime)


def from_file(path):
    """[(raw bytes, None)] of the Amazon messages in an .mbox (Google Takeout's) or one .eml."""
    if path.lower().endswith(".eml"):
        with open(path, "rb") as f:
            return [(f.read(), None)]
    out = []
    for m in mailbox.mbox(path, create=False):
        sender = email.utils.parseaddr(str(m.get("From") or ""))[1].lower()
        if sender.endswith("@amazon.com"):
            out.append((m.as_bytes(), None))
    return out


def gmail_query(since):
    return "from:(%s) after:%s" % (" OR ".join(SENDERS), since.strftime("%Y/%m/%d"))


def keep(cur, m, gmail_id, file_name, load_id):
    """Writes one e-mail to srm.amazon_email (again, when a newer parser read it)."""
    cur.execute("""INSERT INTO srm.amazon_email (message_key, gmail_id, received_at, sender, subject, kind, order_ids,
                                                 amount, facts, parser, file_name, load_id)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (message_key) DO UPDATE SET gmail_id = coalesce(excluded.gmail_id, srm.amazon_email.gmail_id),
                          received_at = excluded.received_at, sender = excluded.sender, subject = excluded.subject,
                          kind = excluded.kind, order_ids = excluded.order_ids, amount = excluded.amount,
                          facts = excluded.facts, parser = excluded.parser, file_name = excluded.file_name,
                          load_id = excluded.load_id, read_at = now()""",
                (m["key"], gmail_id, m["received"], m["sender"], m["subject"], m["kind"], m["orders"], m["amount"],
                 json.dumps(m["facts"], default=str), PARSER, file_name[:300], load_id))


# ------------------------------------------------------------------------------------------------------------ orders

def _price(bs):
    return sum((b.get("price") or 0) * (b.get("quantity") or 1) for b in bs)


def build(order_id, mails, page_items=()):
    """An order from its e-mails (oldest first; each {kind, received, facts}) and the items its page gave:
    {id, ordered, status, items, total, shipments, emails, hash}."""
    def facts(m):
        return ((m["facts"] or {}).get("orders") or {}).get(order_id) or {"items": [], "total": None}

    confirmations = [m for m in mails if m["kind"] == "order"]
    shipped = [m for m in mails if m["kind"] == "shipment"]
    cancels = [m for m in mails if m["kind"] == "cancel"]
    conf = facts(confirmations[-1]) if confirmations else {"items": [], "total": None}   # an order changed is confirmed again
    total = conf["total"]
    bought = [dict(i) for i in conf["items"]]
    if not bought:                          # several items: what the shipment e-mails name, else what its page gave
        for m in shipped:
            for i in facts(m)["items"]:
                if not any(_same(i, b) for b in bought):
                    bought.append(dict(i))
    if not bought:
        bought = [dict(i, page=True) for i in page_items]
    first = confirmations[0] if confirmations else mails[0]
    if not bought and (first["facts"] or {}).get("summary"):
        several = len((first["facts"] or {}).get("orders") or {}) > 1
        bought = [{"name": ("one of the orders of " if several else "") + first["facts"]["summary"], "summary": True}]
    ordered = min(m["received"] for m in (confirmations or mails))
    status = None
    for m in cancels:
        named = facts(m)["items"]
        if m["facts"].get("whole") or not named or all(any(_same(n, b) for n in named) for b in bought if not b.get("summary")):
            status = "Cancelled"
        for b in bought:
            b["cancelled"] = b.get("cancelled") or status == "Cancelled" or any(_same(b, n) for n in named)
    if total is not None and status != "Cancelled" and any(b.get("cancelled") for b in bought) and _price(bought) > 0:
        total = round(total * _price([b for b in bought if not b.get("cancelled")]) / _price(bought), 2)

    # Shipments: each shipment e-mail, with its total and the items it names; the items no e-mail names go with the
    # first shipment that names none, else stay unshipped.
    shipments, left = [], [b for b in bought if not b.get("cancelled")]
    for m in ([] if status == "Cancelled" else shipped):
        f = facts(m)
        mine, foreign = [], False
        for n in f["items"]:
            hit = next((b for b in left if _same(b, n)), None)
            if hit is None and not any(_same(b, n) for b in bought):
                if conf["items"]:
                    foreign = True      # another order's item, shipped with this one's
                    continue
                hit = dict(n)
                bought.append(hit)
            if hit is not None and hit in left:
                left.remove(hit)
                mine.append(hit)
        if f["items"] and not mine:
            continue                    # nothing of this order's (it was in the shipment of another)
        shipments.append({"shipped": m["received"], "items": mine, "total": None if foreign else f["total"],
                          "named": bool(f["items"]), "summary": (m["facts"] or {}).get("summary")})
    for s in shipments:
        if not s["named"] and left:
            s["items"], left = left, []
        elif not s["named"] and s["summary"]:
            s["items"] = [{"name": s["summary"], "summary": True}]
            bought.append(s["items"][0])
    known = round(sum(s["total"] for s in shipments if s["total"] is not None), 2)
    rest = round(total - known, 2) if total is not None else None
    if status != "Cancelled" and (left or not shipments or (rest is not None and rest > 0.01
                                                            and all(s["total"] is not None for s in shipments))):
        shipments.append({"shipped": None, "items": left, "total": None})
        left = []
    # What each shipment's charge should be: its own total, else what the order's total leaves (shared by the items'
    # prices when several have none).
    open_ = [s for s in shipments if s["total"] is None]
    if open_ and rest is not None and rest > 0:
        prices = [_price(s["items"]) for s in open_]
        if len(open_) == 1 or sum(prices) <= 0:
            open_[0]["total"] = rest
        else:
            for s, p in zip(open_, prices):
                s["total"] = round(rest * p / sum(prices), 2)
            open_[-1]["total"] = round(rest - sum(s["total"] for s in open_[:-1]), 2)
    for s in shipments:
        s["total"] = max(0.0, round(s["total"] or 0.0, 2))
    order = {"id": order_id, "ordered": ordered, "status": status, "items": bought,
             "total": total if total is not None else round(sum(s["total"] for s in shipments), 2),
             "shipments": [{k: s[k] for k in ("shipped", "items", "total")} for s in shipments if s["items"] or s["total"]],
             "emails": len(mails)}
    order["hash"] = "email:%d:" % PARSER + hashlib.sha1(json.dumps(order, sort_keys=True, default=str).encode()).hexdigest()
    return order


def save(cur, order, load_id):
    """Writes an order from its e-mails, in place of what an earlier reading or its page said (the card the page named
    stays); the loaders' matches go (they are made again), the lookup's stay, on the order as a whole."""
    oid = order["id"]
    cur.execute("""UPDATE srm.amazon_match SET how = 'transaction', shipment_id = NULL
                    WHERE order_id = %s AND matched_by NOT IN ('amazon-orders', 'amazon-email') AND how <> 'unlinked'""", (oid,))
    cur.execute("DELETE FROM srm.amazon_match WHERE order_id = %s AND matched_by IN ('amazon-orders', 'amazon-email')", (oid,))
    cur.execute("DELETE FROM srm.amazon_item WHERE order_id = %s", (oid,))
    cur.execute("DELETE FROM srm.amazon_shipment WHERE order_id = %s", (oid,))
    named = [i for i in order["items"] if not i.get("summary")]
    cur.execute("""INSERT INTO srm.amazon_order (order_id, website, ordered_at, currency, order_status, items, total_owed,
                                                 origin, content_hash, file_name, load_id)
                   VALUES (%s, 'Amazon.com', %s, 'USD', %s, %s, %s, 'email', %s, %s, %s)
                   ON CONFLICT (order_id) DO UPDATE SET origin = 'email', website = excluded.website,
                          ordered_at = excluded.ordered_at, currency = excluded.currency,
                          order_status = excluded.order_status, items = excluded.items,
                          total_owed = excluded.total_owed, content_hash = excluded.content_hash,
                          file_name = excluded.file_name, load_id = excluded.load_id, updated_at = now()""",
                (oid, order["ordered"], order["status"], len(named), order["total"], order["hash"],
                 "%d e-mail%s" % (order["emails"], "" if order["emails"] == 1 else "s"), load_id))
    placed = set()
    for seq, s in enumerate(order["shipments"], 1):
        cur.execute("""INSERT INTO srm.amazon_shipment (order_id, seq, shipped_at, shipment_status, total_owed, charge_amount)
                       VALUES (%s, %s, %s, %s, %s, %s) RETURNING shipment_id""",
                    (oid, seq, s["shipped"], "Shipped" if s["shipped"] else None, s["total"], s["total"]))
        sid = cur.fetchone()[0]
        for i in s["items"]:
            placed.add(id(i))
            _item(cur, oid, sid, i)
    for i in order["items"]:
        if id(i) not in placed:
            _item(cur, oid, None, i)     # cancelled


def _item(cur, oid, sid, i):
    qty = i.get("quantity") or 1
    condition = ("Cancelled" if i.get("cancelled") else "summary" if i.get("summary")
                 else "order page" if i.get("page") else None)
    cur.execute("""INSERT INTO srm.amazon_item (order_id, shipment_id, product_name, asin, quantity, unit_price, total_owed,
                                                condition)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s)""",
                (oid, sid, i["name"][:500], i.get("asin"), None if i.get("summary") else qty, i.get("price"),
                 round(i["price"] * qty, 2) if i.get("price") is not None else None, condition))


# ------------------------------------------------------------------------------------------------------------ refunds

def match_refunds(cur, load_id):
    """Each credit not matched yet to the refund e-mail (to the card) of the same amount, from 5 days before it to 14
    after: the item it names when its order has it, else the order; the closest dates win. Returns how many."""
    cur.execute(amazon_orders.CHARGES)
    cols = [d[0] for d in cur.description]
    credits = [dict(zip(cols, r)) for r in cur.fetchall()]
    credits = [c for c in credits if c["amount"] < 0 and amazon_orders.is_order_charge(c["text"])]
    if not credits:
        return 0
    cur.execute("""SELECT e.email_id, e.received_at, e.amount, e.facts, o.order_id, o.payment_last4
                     FROM srm.amazon_email e
                     JOIN srm.amazon_order o ON o.order_id = e.order_ids[1]
                    WHERE e.kind = 'refund' AND e.amount > 0 AND coalesce((e.facts->>'toCard')::boolean, true)
                      AND NOT EXISTS (SELECT FROM srm.amazon_match m WHERE m.email_id = e.email_id)""")
    refunds = collections.defaultdict(list)
    for email_id, received, amount, facts, oid, last4 in cur.fetchall():
        refunds[amazon_orders._cents(amount)].append({"email_id": email_id, "day": amazon_orders._day(received),
                                                      "facts": facts or {}, "order_id": oid, "last4": last4})
    pairs = []
    for c in credits:
        c["last4"] = c["account_last4"]
        for r in refunds.get(-amazon_orders._cents(c["amount"]), []):
            days = (c["txn_date"] - r["day"]).days
            if amazon_orders._card_fits(c, r["last4"]) and REFUND_WINDOW[0] <= days <= REFUND_WINDOW[1]:
                pairs.append((abs(days), c["txn_id"], c, r, days))
    used_c, used_r, n = set(), set(), 0
    for _, _, c, r, days in sorted(pairs, key=lambda p: (p[0], p[1])):
        if (c["source"], c["txn_id"]) in used_c or r["email_id"] in used_r:
            continue
        used_c.add((c["source"], c["txn_id"]))
        used_r.add(r["email_id"])
        cur.execute("""SELECT item_id, product_name, asin FROM srm.amazon_item i
                        WHERE order_id = %s AND NOT EXISTS (SELECT FROM srm.amazon_match m
                                                             WHERE m.item_id = i.item_id AND m.how = 'refund')""",
                    (r["order_id"],))
        kept = [{"item_id": i, "name": nm, "asin": a} for i, nm, a in cur.fetchall()]
        hits = [k for k in kept if any(_same(k, x) for x in r["facts"].get("items") or [])]
        card, bank = (c["txn_id"], None) if c["source"] == "card" else (None, c["txn_id"])
        cur.execute("""INSERT INTO srm.amazon_match (card_txn_id, bank_txn_id, order_id, item_id, how, days, matched_by,
                                                     load_id, email_id)
                       VALUES (%s, %s, %s, %s, 'refund', %s, 'amazon-email', %s, %s)""",
                    (card, bank, r["order_id"], hits[0]["item_id"] if len(hits) == 1 else None, days, load_id,
                     r["email_id"]))
        n += 1
    return n


# ------------------------------------------------------------------------------------------------------------ run

def run(conn, cfg, args):
    opts = settings()
    since = datetime.date.fromisoformat(getattr(args, "since", None) or opts.get("since") or DEFAULT_SINCE)
    force = bool(getattr(args, "force", False))
    single = getattr(args, "file", None)
    folders = amazon_orders.drop_folders()
    use_gmail = opts.get("gmail", True) and not single
    with LoadRun(conn, "AMAZON_EMAIL", "amazon_email", {"since": str(since), "force": force, "file": single,
                                                        "folders": folders, "gmail": use_gmail}) as run, \
            conn.cursor() as cur:
        cur.execute("SELECT message_key, gmail_id, parser FROM srm.amazon_email")
        kept, kept_gmail = {}, {}
        for key, gmail_id, parser in cur.fetchall():
            kept[key] = parser
            if gmail_id:
                kept_gmail[gmail_id] = parser
        touched, counts, sources, this_run = set(), collections.Counter(), [], set()

        def take(raw, received_ms, gmail_id, file_name):
            try:
                m = read(raw, received_ms)
            except Exception as e:     # one odd message mustn't stop the run
                run.reject(gmail_id or file_name, f"can't read: {type(e).__name__}: {e}")
                return
            run.read += 1
            # Read already (from Gmail or an .mbox; two Gmail messages may carry one Message-ID: the first stays).
            if (not force and kept.get(m["key"]) == PARSER and m["key"] not in this_run) or m["received"].date() < since:
                return
            if m["key"] in this_run:
                return
            this_run.add(m["key"])
            counts["new"] += m["key"] not in kept
            keep(cur, m, gmail_id, file_name, run.load_id)
            kept[m["key"]] = PARSER
            counts[m["kind"]] += 1
            if m["kind"] in ("order", "shipment", "cancel"):
                touched.update(m["orders"])

        # Gmail: the messages not read yet (or read by an older parser).
        if use_gmail:
            try:
                g = gmail.Gmail()
                mailbox_name = g.profile()["emailAddress"]
                ids = g.search(gmail_query(since))
                todo = [i for i in ids if force or kept_gmail.get(i) != PARSER]
                log(f"  Gmail {mailbox_name}: {len(ids)} Amazon e-mails since {since}, {len(todo)} to read")
                for n in range(0, len(todo), 100):
                    for mid, (raw, ms) in g.raws(todo[n:n + 100]).items():
                        take(raw, ms, mid, f"gmail:{mailbox_name}")
                    conn.commit()       # what was read stays when a later batch fails
                    log(f"  read {min(n + 100, len(todo))} of {len(todo)}")
                run.api_calls += g.calls
                sources.append(f"Gmail {mailbox_name}")
            except gmail.NotAuthorized as e:
                if not mbox_files(folders):
                    raise
                log(f"  {e}; reading the .mbox files only")
                run.status = "partial"
        # Google Takeout .mbox files (and .eml) in the drop folders, or --file.
        for path in mbox_files(folders, single):
            try:
                found = from_file(path)
            except OSError as e:
                log(f"  can't read {path}: {e}")
                continue
            for raw, ms in found:
                take(raw, ms, None, os.path.basename(path))
            sources.append(os.path.basename(path))
            debug(f"  {path}: {len(found)} Amazon e-mails")
        conn.commit()

        # Each order an e-mail changed (with --force every one), from all its e-mails.
        cur.execute("""SELECT order_ids, kind, received_at, facts FROM srm.amazon_email
                        WHERE kind IN ('order', 'shipment', 'cancel') AND order_ids <> '{}' ORDER BY received_at""")
        by_order = collections.defaultdict(list)
        for order_ids, kind, received, facts in cur.fetchall():
            for oid in order_ids:
                by_order[oid].append({"kind": kind, "received": received, "facts": facts})
        cur.execute("SELECT order_id, origin, content_hash, payment, payment_last4 FROM srm.amazon_order")
        orders = {r[0]: r[1:] for r in cur.fetchall()}
        # The items the Order Lookup read from an order's page (kept when the e-mails took the order over).
        cur.execute("""SELECT i.order_id, i.product_name, i.asin, i.quantity, i.unit_price
                         FROM srm.amazon_item i JOIN srm.amazon_order o USING (order_id)
                        WHERE (o.origin = 'order page' OR i.condition = 'order page') ORDER BY i.item_id""")
        pages = collections.defaultdict(list)
        for oid, name, asin, qty, price in cur.fetchall():
            pages[oid].append({"name": name, "asin": asin, "quantity": qty, "price": float(price) if price is not None else None})
        new = changed = from_export = 0
        for oid in sorted(by_order if force else touched & set(by_order)):
            origin, h, payment, last4 = orders.get(oid, (None, None, None, None))
            if origin == "export":
                from_export += 1
                continue
            order = build(oid, by_order[oid], pages.get(oid, ()))
            if h == order["hash"] or not (order["items"] or order["shipments"]):
                continue
            save(cur, order, run.load_id)
            if origin == "order page" and (payment or last4):
                cur.execute("UPDATE srm.amazon_order SET payment = %s, payment_last4 = %s WHERE order_id = %s",
                            (payment, last4, oid))
            new += origin is None
            changed += origin is not None
        refunds = match_refunds(cur, run.load_id)
        made, unmatched = amazon_orders.match(cur, run.load_id)
        conn.commit()
        run.inserted += new
        run.updated += changed
        cur.execute("SELECT count(*), min(ordered_at)::date, max(ordered_at)::date FROM srm.amazon_order WHERE origin = 'email'")
        total, first, last = cur.fetchone()
        cur.execute("""SELECT count(DISTINCT coalesce(m.card_txn_id, -m.bank_txn_id)) FROM srm.amazon_match m
                         JOIN srm.amazon_order o USING (order_id) WHERE o.origin = 'email' AND m.how <> 'unlinked'""")
        matched_all = cur.fetchone()[0]
        matched = sum(n for how, n in made.items() if how != "narrowed")
        dated = [c for c in unmatched if first and first <= c["txn_date"] <= last + datetime.timedelta(days=30)]
        read_now = sum(counts[k] for k in ("order", "shipment", "refund", "cancel", "other"))
        run.message = (f"{', '.join(sources) or 'no mailbox'}: {read_now} e-mails read ({counts['new']} new: "
                       f"{counts['order']} orders, {counts['shipment']} shipments, {counts['refund']} refunds, "
                       f"{counts['cancel']} cancellations, {counts['other']} other); {new} orders new, {changed} "
                       f"changed, {from_export} left as the export has them; {total} orders from e-mails kept"
                       + (f" ({first} – {last})" if total else "") + "; "
                       f"{matched + refunds} Amazon entries matched now ({made['shipment']} to a shipment, "
                       f"{made['order']} to an order, {made['shipments']} to several shipments, "
                       f"{made['refund'] + refunds} credits to refunds"
                       + (f"; {made['narrowed']} looked-up charges narrowed to their shipment" if made["narrowed"] else "")
                       + f"), {matched_all} entries matched to e-mail orders in all; "
                       f"{sum(1 for c in dated if c['cents'] > 0)} charges and {sum(1 for c in dated if c['cents'] < 0)} "
                       f"credits in the e-mails' dates not matched")
        log("  " + run.message)
