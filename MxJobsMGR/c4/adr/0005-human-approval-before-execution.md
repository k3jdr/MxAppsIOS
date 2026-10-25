# ADR-0005: A human approves before anything is executed

- **Status:** Accepted — recorded retrospectively on 2026-10-17 from the code, READMEs and git history
- **Applies to:** Run engine, Validator

## Context

Workflows end in actions with consequences: rebalancing a portfolio, publishing attribution, running long
backfills. Agents and optimizers propose; a person must decide.

## Decision

- The **Validator reports an error** for an Execution Request with no User Approval upstream.
- **User Approval** pauses the run on an **Approve / Reject** prompt showing the summary (with `{{argument}}` and
  input values filled in), the approver and the instructions. **Reject** blocks every step after it.
- An Execution Request can ask **Send / Cancel** again before sending.
- *Auto-approve* exists only as a rehearsal mode and marks approvals as warnings.

## Consequences

- Every sample has an approval gate (PM, index PM, data steward).
- Runs are interactive by default; unattended execution is not possible today (see [ADR-0006](0006-execution-requests-never-send-yet.md)).

## Evidence

`Validation.swift` ("runs without a User Approval step before it"), `RunEngine.swift` (`approvalGate`, `executeRequest`), `RunViews.swift` (`RunPromptBanner`).
