# ADR-0003: The app talks to PostgreSQL directly, one statement per change

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxDataHUB.app

## Context

The app is used by one analyst at a time against a database on the local network. Its changes are small:
create or edit a portfolio, add or remove holdings, copy a benchmark into a snapshot, build a custom benchmark.
An API tier would add deployment and versioning work without a second client that needs it.

## Decision

Connect **directly with PostgresNIO** (SSL `disable` / `prefer` / `require`, no certificate verification, like libpq)
and make **every change a single SQL statement, committed on its own** — there are no client-side transactions.
Values are always passed as **text bind parameters**; SQL is never built from user input.

## Consequences

- Simple: no server to deploy; the database's constraints and functions are the API ([ADR-0002](0002-postgresql-srm-schema-as-system-of-record.md)).
- A failed action leaves nothing half-done, because there is only one statement.
- Multi-step operations must be a single SQL function (e.g. `add_holding`, `build_benchmark`) or tolerate partial
  completion (e.g. *Paste Holdings* adds line by line and reports which lines failed).
- The database must be reachable from the Mac; credentials are per user.
- `to_regclass('srm.security')` after connecting decides whether the schema is present, so the app can be pointed
  at any database on the server (Database drop-down).

## Alternatives considered

- *REST/GraphQL service over the database* — more moving parts; revisit if several users or remote access are needed.
- *Client transactions spanning several statements* — not needed for the current operations.

## Evidence

`PostgresService.swift` (`rows(_:_:)` with binds), `SRMStore.swift`, MxDataHUB `README.md` ("Every change the app makes is one SQL statement, committed on its own").
