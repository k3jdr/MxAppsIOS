# ADR-0010: Shared Swift sources are compiled into each app

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** MxDataHUB, MxJobsWMS (and MxDataSQL, MxFileMGR for Quick Help)

## Context

Both apps need the same service catalog, sample list, URL hand-offs, services views and Quick Help panel. A Swift
package or framework would add versioning and build configuration for a few files that change together with the apps.

## Decision

Keep the shared code in **`MXcodeIDE/Shared`** and add it to each Xcode project as a **file-system synchronized
group** (`path = ../Shared`), so it compiles into each app. MxDataSQL and MxFileMGR include only `Shared/QuickHelp`.

## Consequences

- One source of truth; a change appears in every app at its next build.
- No binary compatibility or package versioning concerns.
- A change can break an app that is not rebuilt and tested; release the apps that use a changed file together.
- Shared code must avoid app-specific types (it uses closures and small value types, e.g. `ServicesView(openSample:)`).

## Evidence

`MxDataHUB.xcodeproj/project.pbxproj` (`Shared` synchronized group), `Shared/*.swift` headers.
