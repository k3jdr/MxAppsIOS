# ADR-0004: API keys live in the Keychain, never in a jobspace

- **Status:** Superseded by [ADR-0018](0018-api-keys-kept-by-mxacctmgr-secure-accounts.md) (2026-10-25: keys are kept by MxAcctMGR ▸ Secure Accounts; they still never enter a jobspace) — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxJobsMGR.app

## Context

Jobspaces are shared and committed to git ([ADR-0001](0001-document-based-app-with-json-jobspace-files.md)), but
their API Data Read steps need provider keys (Alpha Vantage, Finnhub, …).

## Decision

Store each subscription's key in the **login Keychain** — service `com.k3jdr.MxJobsMGR`, account
`subscription-<uuid>` — and **never** write it to the jobspace. The subscription in the file keeps everything else
(base URL, auth style, key name, headers). *Save Key* runs *Test Key* (one call to the provider). Keys are masked in
URLs shown by Test Call; Python steps receive them only through `MXJOBS_API_KEY`.

## Consequences

- Jobspaces can be shared without leaking secrets; on another Mac, keys are entered again.
- *Save As* keeps the key with the copied subscription id.
- The Validator warns about steps whose subscription has no stored key; `KeychainChanges` redraws key status.
- Alpha Vantage accepts any key, so for it *Test Key* proves calls work rather than that the key is yours.

## Evidence

`Keychain.swift`, `SubscriptionsDialog.swift`, `KeyHelp.swift`, `Validation.swift`, README *Files and keys*.
