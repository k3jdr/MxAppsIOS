"""U.S. Treasury securities (srm.bond_terms, V018): every outstanding marketable bill, note, bond, TIPS and FRN, with
daily end-of-day prices.

  * Terms: TreasuryDirect's securities API (free, no key) — one record per auction, so a CUSIP reopened three times
    has four; they are combined: original issue date, the latest amount outstanding, coupon, frequency, dated and
    maturity dates, TIPS reference CPI, FRN spread. Announced auctions not yet issued are included (no amount yet).
    Each Treasury is a 'Bond' security of the U.S. Treasury, listed on MIC XXXX (no exchange) under its CUSIP, with
    its CUSIP and ISIN. Treasuries that have matured are marked inactive.
  * Prices: the Treasury's FedInvest price file — buy, sell and end-of-day price per CUSIP for a business day
    (the end-of-day price, per 100 of par, is stored as the close; source FEDINVEST). Each run fills the days since
    the last price, from --since (default 30 days back) the first time; one request every two seconds.
"""

import datetime
import html
import re
from http.cookiejar import CookieJar
import time
import urllib.error
import urllib.parse
import urllib.request

from ..common import HTTPError, LoadRun, debug, http, log, set_identifiers
from ..model import create_security, ensure_issuer, ensure_listing, source_id
from . import nasdaq_prices

SEARCH_URL = ("https://www.treasurydirect.gov/TA_WS/securities/search?format=json&dateFieldName=maturityDate"
              "&startDate={start}&endDate=12/31/2099")
FEDINVEST = "https://www.treasurydirect.gov/GA-FI/FedInvest/"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
MIC = "XXXX"
ISSUER = "United States Department of the Treasury"
KIND_NAMES = {"Bill": "Bill", "CMB": "Cash Management Bill", "Note": "Note", "Bond": "Bond",
              "TIPS": "Inflation-Protected", "FRN": "Floating Rate Note"}


def _date(text):
    try:
        return datetime.date.fromisoformat((text or "")[:10])
    except ValueError:
        return None


def _number(text):
    try:
        return float(text) if text not in (None, "") else None
    except (TypeError, ValueError):
        return None


def combine(records):
    """One CUSIP's auction records (original issue and reopenings) → its terms."""
    records = sorted(records, key=lambda r: r.get("issueDate") or "")
    first, last = records[0], records[-1]

    def latest(field):
        for r in reversed(records):
            if r.get(field) not in (None, ""):
                return r[field]
        return None

    kind = last.get("type") or last.get("securityType")
    if kind == "TIPS" and last.get("securityType") == "Bond":
        kind = "TIPS"
    outstanding = _number(latest("currentlyOutstanding"))
    return {
        "cusip": last["cusip"].strip().upper(), "kind": kind, "security_type": last.get("securityType"),
        "coupon": _number(latest("interestRate")),
        "frequency": latest("frequencyOfInterestPayments") or ("None" if kind in ("Bill", "CMB") else None),
        "floating": (latest("floatingRate") == "Yes") or kind == "FRN", "tips": kind == "TIPS",
        "callable": latest("callable") == "Yes", "call_date": _date(latest("callDate")),
        "original_issue": _date(first.get("originalIssueDate") or first.get("issueDate")),
        "dated": _date(latest("datedDate")), "maturity": _date(last.get("maturityDate")),
        "first_coupon": _date(latest("firstInterestPaymentDate")),
        "term": first.get("securityTerm"), "outstanding": outstanding if outstanding else None,
        "auctions": len(records), "spread": _number(latest("spread")),
        "offered": sum(_number(r.get("offeringAmount")) or 0 for r in records) or None,
        "ref_cpi": _number(latest("referenceCpiOnOriginalDatedDate") or latest("refCpiOnDatedDate")),
    }


def name(t):
    kind = KIND_NAMES.get(t["kind"], t["kind"])
    if t["kind"] in ("Bill", "CMB"):
        return f"U.S. Treasury {kind} {t['maturity']:%m/%d/%Y}"
    if t["kind"] == "TIPS":
        base = "Bond" if t["security_type"] == "Bond" else "Note"
        return f"U.S. Treasury Inflation-Protected {base} {t['coupon'] or 0:.3f}% {t['maturity']:%m/%d/%Y}"
    if t["kind"] == "FRN":
        return f"U.S. Treasury Floating Rate Note {t['maturity']:%m/%d/%Y}"
    return f"U.S. Treasury {kind} {t['coupon'] or 0:.3f}% {t['maturity']:%m/%d/%Y}"


def load_terms(conn, cur, run, src):
    today = datetime.date.today()
    run.api_calls += 1
    records = http(SEARCH_URL.format(start=today.strftime("%m/%d/%Y")), headers={"User-Agent": UA}, timeout=180)
    by_cusip = {}
    for r in records or []:
        if r.get("cusip") and _date(r.get("maturityDate")):
            by_cusip.setdefault(r["cusip"].strip().upper(), []).append(r)
    run.read += len(records or [])
    log(f"  TreasuryDirect: {len(records or [])} auctions of {len(by_cusip)} outstanding Treasuries")
    issuer_id = ensure_issuer(cur, ISSUER)
    created = updated = 0
    for cusip, recs in sorted(by_cusip.items()):
        t = combine(recs)
        cur.execute("""SELECT security_id FROM srm.security_identifier WHERE id_type = 'CUSIP' AND id_value = %s
                          AND current_date < valid_to LIMIT 1""", (cusip,))
        row = cur.fetchone()
        if row:
            security_id = row[0]
            cur.execute("UPDATE srm.security SET name = %s, is_active = true, inactive_date = NULL WHERE security_id = %s",
                        (name(t), security_id))
            updated += 1
        else:
            security_id = create_security(cur, name(t), "Bond", run.load_id, country="US", primary_mic=MIC,
                                          issuer_id=issuer_id)
            listing_id, _ = ensure_listing(cur, security_id, MIC, cusip, True)
            cur.execute("SELECT srm.isin_from_cusip(%s)", (cusip,))
            isin = cur.fetchone()[0]
            set_identifiers(cur, run, [(security_id, "CUSIP", cusip, None, None)]
                            + ([(security_id, "ISIN", isin, None, None)] if isin else []), "TREASURYDIRECT")
            created += 1
        cur.execute("""
            INSERT INTO srm.bond_terms (security_id, bond_class, bond_kind, issuer_name, coupon_rate, coupon_frequency,
                   is_floating, is_inflation_linked, is_callable, call_date, original_issue_date, dated_date, maturity_date,
                   first_coupon_date, term, amount_outstanding, amount_offered, auctions, spread, ref_cpi_dated_date, source_id,
                   load_id)
            VALUES (%s, 'treasury', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (security_id) DO UPDATE SET bond_kind = excluded.bond_kind, coupon_rate = excluded.coupon_rate,
                coupon_frequency = excluded.coupon_frequency, is_floating = excluded.is_floating,
                is_inflation_linked = excluded.is_inflation_linked, is_callable = excluded.is_callable,
                call_date = excluded.call_date, original_issue_date = excluded.original_issue_date,
                dated_date = excluded.dated_date, maturity_date = excluded.maturity_date,
                first_coupon_date = excluded.first_coupon_date, term = excluded.term,
                amount_outstanding = coalesce(excluded.amount_outstanding, srm.bond_terms.amount_outstanding),
                amount_offered = excluded.amount_offered,
                auctions = excluded.auctions, spread = excluded.spread, ref_cpi_dated_date = excluded.ref_cpi_dated_date,
                load_id = excluded.load_id, updated_at = now()""",
                    (security_id, t["kind"], ISSUER, t["coupon"], t["frequency"], t["floating"], t["tips"], t["callable"],
                     t["call_date"], t["original_issue"], t["dated"], t["maturity"], t["first_coupon"], t["term"],
                     t["outstanding"], t["offered"], t["auctions"], t["spread"], t["ref_cpi"], src, run.load_id))
    # Matured since the last load.
    cur.execute("""UPDATE srm.security s SET is_active = false, inactive_date = b.maturity_date
                     FROM srm.bond_terms b
                    WHERE b.security_id = s.security_id AND b.bond_class = 'treasury' AND b.maturity_date < current_date
                      AND s.is_active RETURNING s.security_id""")
    matured = len(cur.fetchall())
    conn.commit()
    run.inserted += created
    run.updated += updated
    log(f"  {created} new Treasuries, {updated} updated, {matured} matured")
    return by_cusip


class FedInvest:
    """The price form keeps a session (cookie and CSRF token); the prices come from the page it redirects to."""

    def __init__(self):
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))
        self.last = 0.0

    def _open(self, url, data=None):
        pause = 2.0 - (time.monotonic() - self.last)
        if pause > 0:
            time.sleep(pause)
        self.last = time.monotonic()
        req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, "Referer": FEDINVEST + "selectSecurityPriceDate"})
        with self.opener.open(req, timeout=60) as r:
            return r.read().decode("latin-1")

    def prices(self, day):
        """{cusip: (type, end-of-day price)} for a business day; empty when FedInvest has none (weekend, holiday)."""
        form = self._open(FEDINVEST + "selectSecurityPriceDate")
        token = re.search(r'name="_csrf" value="([^"]+)"', form)
        body = urllib.parse.urlencode({"_csrf": token.group(1) if token else "", "priceDate": day.isoformat(),
                                       "submit": "Show Prices"}).encode()
        page = self._open(FEDINVEST + "selectSecurityPriceDate", body)   # follows the redirect to the price table
        if "securityPriceDetail" not in page and "END OF DAY" not in page:
            page = self._open(FEDINVEST + "securityPriceDetail")
        out = {}
        for row in re.findall(r"<tr[^>]*>(.*?)</tr>", page, re.S):
            cells = [html.unescape(re.sub(r"<[^>]+>", "", c)).strip() for c in re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)]
            if len(cells) >= 8 and re.fullmatch(r"[0-9A-Z]{9}", cells[0]):
                eod = _number(cells[7])
                if eod and eod > 0:
                    out[cells[0]] = (cells[1], eod)
        # The page says which day its prices are for ("Prices For: October 22, 2026"); another day's (a holiday asks
        # for the nearest) must not be stored under this one.
        shown = re.search(r"Prices For:\s*</?[^>]*>?\s*([A-Z][a-z]+ \d{1,2}, \d{4})", page) or \
            re.search(r"Prices For:\s*([A-Z][a-z]+ \d{1,2}, \d{4})", re.sub(r"<[^>]+>", " ", page))
        shown_day = datetime.datetime.strptime(shown.group(1), "%B %d, %Y").date() if shown else None
        return (out if shown_day == day else {}), shown_day


def load_prices(conn, cur, run, src, since):
    cur.execute("""SELECT si.id_value, l.listing_id FROM srm.bond_terms b
                     JOIN srm.security_identifier si ON si.security_id = b.security_id AND si.id_type = 'CUSIP'
                          AND current_date < si.valid_to
                     JOIN srm.listing l ON l.security_id = b.security_id AND l.mic = %s AND current_date < l.valid_to
                    WHERE b.bond_class = 'treasury'""", (MIC,))
    listings = dict(cur.fetchall())
    cur.execute("SELECT max(price_date) FROM srm.price WHERE source_id = %s", (src,))
    last = cur.fetchone()[0]
    today = datetime.date.today()
    day = (last + datetime.timedelta(days=1)) if last else since
    fed = FedInvest()
    days = priced = unknown = 0
    while day <= today:
        if day.weekday() < 5:
            run.api_calls += 2
            try:
                prices, shown = fed.prices(day)
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                run.reject(day.isoformat(), f"FedInvest: {e}")
                day += datetime.timedelta(days=1)
                continue
            if prices:
                rows = {}
                for cusip, (_, eod) in prices.items():
                    listing_id = listings.get(cusip)
                    if listing_id:
                        rows.setdefault(listing_id, []).append((day.isoformat(), None, None, None, eod, None))
                    else:
                        unknown += 1
                for listing_id, values in rows.items():
                    result = nasdaq_prices._upsert(cur, listing_id, values, src, run.load_id, "USD")
                    priced += sum(1 for r in result if r[0])
                conn.commit()
                days += 1
                debug(f"FedInvest {day}: {len(prices)} prices")
            else:
                debug(f"FedInvest {day}: no prices" + (f" (not posted yet, or a holiday; the page is for {shown})" if shown else ""))
        day += datetime.timedelta(days=1)
    log(f"  FedInvest: {days} business days, {priced} new prices" +
        (f", {unknown} prices for CUSIPs not in the security master" if unknown else ""))
    run.inserted += priced


def run(conn, cfg, args):
    since = datetime.date.fromisoformat(args.since) if args.since else datetime.date.today() - datetime.timedelta(days=30)
    with LoadRun(conn, "TREASURYDIRECT", "treasuries", {"since": since.isoformat()}) as run, conn.cursor() as cur:
        load_terms(conn, cur, run, source_id(cur, "TREASURYDIRECT"))
        try:
            load_prices(conn, cur, run, source_id(cur, "FEDINVEST"), since)
        except HTTPError as e:
            run.status, run.message = "partial", f"FedInvest: {e}"
