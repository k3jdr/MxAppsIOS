# ADR-0014: Sandboxed, with user-selected files and security-scoped bookmarks

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxJobsMGR.app

## Context

The app opens and saves documents anywhere, calls networks, runs Python, and offers *Open Project in…* for a
service's source folder in an IDE — while jobspaces may come from others.

## Decision

Enable the **App Sandbox** with **outgoing network**, **user-selected files read/write** and
**`files.bookmarks.app-scope`**. *Open Project* uses **URL schemes** where IDEs have them (VS Code
`vscode://file/<path>/`, IntelliJ IDEA), which work for any folder; for CLion, Xcode and Finder it hands over a folder
the user chose once (*Choose…* / *Grant Access…*), remembered as a **security-scoped bookmark**.

## Consequences

- A jobspace cannot make the app read arbitrary files; Python children inherit the same limits ([ADR-0011](0011-python-steps-run-in-the-sandbox-with-consent.md)).
- One-time folder grants for some IDEs.
- Release signing must keep the entitlements (re-sign without the debug entitlement only).

## Evidence

`MxJobsMGR.entitlements`, build settings, `ProjectOpener.swift`.
