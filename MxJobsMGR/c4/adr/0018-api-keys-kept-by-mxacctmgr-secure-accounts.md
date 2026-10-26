# ADR-0018: API keys are kept by MxAcctMGR ▸ Secure Accounts

- **Status:** Accepted — 2026-10-25
- **Applies to:** MxJobsMGR.app, MxAcctMGR.app (Shared/SharedKeys.swift, Shared/AppLinks.swift)
- **Supersedes:** [ADR-0004](0004-api-keys-in-keychain-never-in-jobspace.md) (keys stay out of the jobspace; who keeps them changes)

## Context

MxJobsMGR kept each subscription's key itself (login Keychain, service `com.k3jdr.MxJobsMGR`, account
`subscription-<uuid>`) and had its own key entry (*Save Key*, *Paste & Save*, *Remove Key*). MxAcctMGR's
Banking ▸ Secure Accounts (`srm.secure_account`, V035) already records every product and service held an account with,
and keeps each one's service key in the Keychain. Keys were entered in two places, and a subscription's key was tied
to one jobspace's subscription id.

## Decision

- **MxAcctMGR ▸ Secure Accounts is the one place API keys are entered and changed.** A secure account's *service key*
  is the API key.
- **A subscription names a secure account** (`secureAccountID`, with `secureAccountName` as last seen) and its calls
  send that account's service key, which MxJobsMGR reads from the Keychain (service `com.k3jdr.MxAcctMGR.secure-accounts`,
  account `<id> service key`). MxJobsMGR has no place to type a key: API Subscriptions has a *Secure account* picker,
  *Open in MxAcctMGR* (`mxacctmgr://secure-accounts/<id>`) and *New in MxAcctMGR…*
  (`mxacctmgr://secure-accounts/new?name=…&api=…&url=…`, the account then linked by name), and *Test Key*.
- **No keychain access group.** Sharing data-protection keychain items needs `keychain-access-groups` or an app group,
  which a sandboxed app signed without a provisioning profile can't use (`errSecMissingEntitlement`, −34018). The apps
  use the login keychain instead, and each item is made **trusting both apps** (`SecAccessCreate` with the other app as
  installed in /Applications; Shared/SharedKeys.swift). Trust is by bundle id and signing certificate, so rebuilds and
  the release re-sign keep matching; either app reads, changes or removes the item without a password prompt.
- **Existing keys move once.** *Move Keys to Secure Accounts* (offered when a jobspace with old keys opens, and in API
  Subscriptions) puts each old key in the secure account of the subscription's name — made through the accounts service
  when there is none — and links the subscription. Items MxJobsMGR made are deleted; items MxJobsWMS made can only be
  deleted by it (`errSecInvalidOwnerEdit`), so they stay until removed in Keychain Access, unused.

## Consequences

- One key per provider serves every jobspace that links the same secure account.
- Picking an account needs the accounts service (127.0.0.1:8774); without it the picker lists only the accounts that
  already have a service key, from the Keychain items' labels.
- Key status is re-read whenever MxJobsMGR becomes active (`KeychainChanges`), since keys change in MxAcctMGR.
- A secure account made before MxJobsMGR is installed trusts only MxAcctMGR: MxJobsMGR's first read of it asks once
  (*Always Allow* adds it), until MxAcctMGR saves the key again.
- The *Adding API Keys* window, the provider guides and Quick Help point to Secure Accounts.

## Alternatives considered

- **Shared keychain access group / app group** — needs a provisioning profile; the apps are signed with the
  certificate alone (see the release routine).
- **The accounts service hands out keys** — secrets over local HTTP, and every job would need the service running.
- **Default item access** — the other app would be asked for the login password on each item's first read.

## Evidence

`MxJobsMGR/SecureKeys.swift`, `SecureAccounts.swift`, `KeyMove.swift`, `SubscriptionsDialog.swift`, `Validation.swift`;
`MxAcctMGR/SecureAccounts.swift`; `Shared/SharedKeys.swift`, `Shared/AppLinks.swift`.
