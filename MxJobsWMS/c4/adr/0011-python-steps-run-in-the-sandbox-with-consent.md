# ADR-0011: Python Script steps run inside the sandbox, with consent; services are preferred

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** Python Script steps, PythonRunner

## Context

Quick data shaping in Python is useful inside a jobspace, but a jobspace file can carry code from someone else, and
the app is sandboxed.

## Decision

A **Python Script** step runs its code with the step's interpreter (else Homebrew, python.org, Apple's developer
tools — `/usr/bin/python3` mapped past its `xcrun` shim), **inside the app's sandbox** (network and the app's
container only), with JSON on stdin (`arguments`, `inputs`, `step`) and JSON on stdout. A run **asks once —
"Run Python scripts?" — showing the code** before the first script. Mock mode does not run Python. For anything
needing files, packages under the home folder or credentials, use a **local service** instead ([ADR-0003](0003-layer-3-compute-as-local-services.md)).

## Consequences

- Untrusted code cannot read the user's files; the user sees code before it runs.
- Packages must be installed into the interpreter itself; pyenv/conda interpreters under the home folder cannot start.
- Two ways to do Python at Layer 3, with guidance on which to choose (README *Python at Layer 3*).

## Evidence

`PythonRunner.swift`, `RunEngine.swift` (`performScript`), README.
