"""Applies migrations/V<nnn>__<name>.sql in order, each in its own transaction, and records
them in srm_meta.schema_version with a checksum. An applied file that was edited afterwards is
reported and stops the run (write a new migration instead)."""

import glob
import hashlib
import os
import re

from .common import ROOT, log

MIGRATIONS = os.path.join(ROOT, "migrations")


def migration_files():
    files = []
    for path in sorted(glob.glob(os.path.join(MIGRATIONS, "V*__*.sql"))):
        m = re.match(r"V(\d+)__(.+)\.sql$", os.path.basename(path))
        if m:
            files.append((int(m.group(1)), m.group(2), path))
    return sorted(files)


def ensure_meta(conn):
    with conn.cursor() as cur:
        cur.execute("""
            CREATE SCHEMA IF NOT EXISTS srm_meta;
            CREATE TABLE IF NOT EXISTS srm_meta.schema_version (
                version    integer PRIMARY KEY,
                name       text NOT NULL,
                checksum   text NOT NULL,
                applied_at timestamptz NOT NULL DEFAULT now(),
                applied_by text NOT NULL DEFAULT current_user
            )""")
    conn.commit()


def applied(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT version, name, checksum, applied_at FROM srm_meta.schema_version ORDER BY version")
        return {r[0]: r for r in cur.fetchall()}


def status(conn):
    ensure_meta(conn)
    done = applied(conn)
    for version, name, path in migration_files():
        checksum = hashlib.sha256(open(path, "rb").read()).hexdigest()
        row = done.get(version)
        state = "pending" if not row else ("applied" if row[2] == checksum else "applied, FILE CHANGED")
        when = f" {row[3]:%Y-%m-%d %H:%M}" if row else ""
        print(f"V{version:03d} {name:45s} {state}{when}")


def migrate(conn, target=None):
    ensure_meta(conn)
    done = applied(conn)
    count = 0
    for version, name, path in migration_files():
        if target is not None and version > target:
            break
        sql = open(path, "rb").read()
        checksum = hashlib.sha256(sql).hexdigest()
        if version in done:
            if done[version][2] != checksum:
                raise SystemExit(f"V{version:03d} {name} was changed after it was applied; add a new migration instead.")
            continue
        log(f"applying V{version:03d} {name}")
        with conn.cursor() as cur:
            cur.execute(sql.decode("utf-8"))
            cur.execute("INSERT INTO srm_meta.schema_version (version, name, checksum) VALUES (%s, %s, %s)",
                        (version, name, checksum))
        conn.commit()
        count += 1
    log(f"{count} migration(s) applied" if count else "schema is up to date")
