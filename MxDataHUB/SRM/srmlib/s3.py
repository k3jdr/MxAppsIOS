"""A minimal S3 GET for S3-compatible file stores (Massive's Flat Files), signed with AWS Signature V4 using only
the standard library — no boto3. Path-style URLs (endpoint/bucket/key); region us-east-1, service s3."""

import datetime
import hashlib
import hmac
import urllib.error
import urllib.parse
import urllib.request

from .common import debug, trace

REGION, SERVICE = "us-east-1", "s3"


def _sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def get(endpoint, bucket, key, access_key, secret_key, timeout=300):
    """The object's bytes, or None when it isn't there or not readable (403 / 404). Other HTTP errors raise urllib.error.HTTPError."""
    host = urllib.parse.urlsplit(endpoint).netloc
    path = "/" + bucket + "/" + urllib.parse.quote(key, safe="/-_.~")
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    payload = "UNSIGNED-PAYLOAD"
    headers = {"host": host, "x-amz-content-sha256": payload, "x-amz-date": amz_date}
    signed = ";".join(sorted(headers))
    canonical = "\n".join(["GET", path, "", "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)), signed, payload])
    scope = f"{day}/{REGION}/{SERVICE}/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    k = _sign(_sign(_sign(_sign(("AWS4" + secret_key).encode(), day), REGION), SERVICE), "aws4_request")
    signature = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    request = urllib.request.Request(endpoint.rstrip("/") + path, headers={
        "x-amz-content-sha256": payload, "x-amz-date": amz_date,
        "Authorization": f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed}, Signature={signature}"})
    trace(f"GET {endpoint.rstrip('/')}{path}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as r:
            data = r.read()
            debug(f"downloaded {key}: {len(data):,} bytes")
            return data
    except urllib.error.HTTPError as e:
        # A day not published yet (or outside the plan) answers 403 as well as 404: the store doesn't allow
        # listing, so it can't say "no such key". Bad keys also give 403 — the caller checks a known day.
        if e.code in (403, 404):
            return None
        raise
