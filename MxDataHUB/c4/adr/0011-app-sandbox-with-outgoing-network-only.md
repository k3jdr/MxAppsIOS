# ADR-0011: App Sandbox with outgoing network only

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxDataHUB.app

## Context

The app connects to PostgreSQL and to local HTTP services and stores one password. It does not need the user's files.

## Decision

Enable the **App Sandbox** with **outgoing network connections** only (`ENABLE_APP_SANDBOX`,
`ENABLE_OUTGOING_NETWORK_CONNECTIONS`); no file-access entitlements.

## Consequences

- Least privilege: the app cannot read files or start processes.
- Anything that needs files, processes or other credentials runs as a Layer 3 service outside the sandbox
  ([ADR-0005](0005-data-refresh-through-local-loader-service.md)).
- Import/export of files (e.g. holdings) would need a user-selected file entitlement; today holdings are pasted.

## Evidence

`MxDataHUB.xcodeproj/project.pbxproj` build settings.
