# ADR-0006: Secrets live in the Keychain, environment or untracked config — never in the repository

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxDataHUB.app, srm.py

## Context

The system needs a database password and API keys for OpenFIGI and FMP (plus an SEC User-Agent). The repository
is on GitHub; the apps are sandboxed.

## Decision

- **App:** the database password is kept in the **login Keychain** (`MxDataHUB: user@host:port/database`) when
  *Save password in Keychain* is on; connection fields (no password) in `UserDefaults`. Debug builds may read `PGPASSWORD`.
- **Loaders:** secrets are looked up in order **environment → Keychain (`SRM-postgres`, `SRM-api`) →
  `config.local.json` (git-ignored)**; libpq's `~/.pgpass` also works. Keys are **redacted** from logs and from
  `srm.load_run`.

## Consequences

- The repository and the load audit can be shared safely.
- Each Mac needs its secrets entered once (`security add-generic-password …`).
- The app and the loaders keep separate copies of the database password.

## Evidence

`Keychain.swift`, `PostgresService.swift` (`ConnectionSettings`), `SRM/srmlib/common.py`, `SRM/README.md` (Secrets).
