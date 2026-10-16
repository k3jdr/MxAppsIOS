# MxJobsWMS Layer 3 contracts

Versioned JSON contracts between the Layer 3 compute services and the Layer 2 decision agents.

| Schema | File | Served by |
| ------ | ---- | --------- |
| `mxjobs.optimize-request/1` | [optimize-request.schema.json](optimize-request.schema.json) | request of `POST /optimize` |
| `mxjobs.optimization/1` | [optimization.schema.json](optimization.schema.json) | `POST /optimize` — `portfolio-java` (127.0.0.1:8766), `portfolio-cpp` (127.0.0.1:8767) |
| `mxjobs.risk/1` | [risk.schema.json](risk.schema.json) | `POST /risk` — `portfolio-cpp` |

| `mxjobs.inputs/1` | — (see below) | `GET /inputs/{id}` — analytics (127.0.0.1:8772); read by the active, tracking and risk endpoints via `inputsUrl` |
| `mxjobs.inputs-summary/1` | — | `POST /inputs` — analytics |
| `mxjobs.active-optimization/1` | — | `POST /optimize/active` — `portfolio-java` |
| `mxjobs.tracking/1` | — | `POST /optimize/tracking` — `portfolio-cpp` |
| `mxjobs.attribution/1` | — | `POST /attribution` — analytics |

`examples/` has a request and the outcome it produces. A breaking change gets a new version (`/2`) served next to
the old one; adding an optional field does not.

## Optimization (both engines implement exactly this, so their results agree)

1. **Inputs.** `expectedReturns` (μ) and `covariance` (Σ), annualised — or `prices`, from which daily simple returns
   give μ = mean × 252 and Σ = sample covariance (n − 1) × 252.
2. **Feasible set.** Long-only, fully invested, capped: wᵢ ≥ 0, Σwᵢ = 1, wᵢ ≤ `maxWeight`.
   Infeasible when `maxWeight` × assets < 1.
3. **Projection** onto that set: wᵢ = clip(vᵢ − τ, 0, cap), τ found by 100 bisection steps on [min v − 1, max v].
4. **Mean-variance(λ):** maximise μᵀw − λ/2 · wᵀΣw by projected gradient ascent from equal weights,
   step 1 / (λ · L) with L the largest eigenvalue of Σ (60 power iterations from the ones vector),
   until max |Δw| < 1e-10 or 20 000 iterations. `min_variance` is the same with μ = 0, λ = 1.
5. **Max-Sharpe:** mean-variance for 80 values λₖ = 10^(−2 + 5k/79), k = 0…79; then 30 golden-section steps on
   x = log10 λ over [x of k−1, x of k+1] around the best grid point k (clamped to the grid; x₁ = b − φ(b − a),
   x₂ = a + φ(b − a), φ = (√5 − 1)/2; keep [a, x₂] when Sharpe(x₁) ≥ Sharpe(x₂), else [x₁, b]). The highest Sharpe
   seen anywhere wins (grid first; on ties the earlier one).
6. **Metrics:** expectedReturn = μᵀw, volatility = √(wᵀΣw), sharpe = (expectedReturn − riskFreeRate) / volatility.
   Weights are rounded to 6 decimals.
7. **Status:** `optimal` when every solve converged, else `max_iterations`; `infeasible`; `invalid_input` (HTTP 400).
8. **Binding constraints:** `max_weight` if some wᵢ ≥ cap − 1e-6 (cap < 1), `long_only` if some wᵢ ≤ 1e-6,
   `max_turnover` if turnover > `maxTurnover`.
9. **Turnover** = ½ Σ |wᵢ − currentᵢ| over all assets in either; null without `currentWeights`.

## decisionContext rules

| Situation | recommendation | confidence | alternatives |
| --------- | -------------- | ---------- | ------------ |
| `invalid_input` | `escalate` | 1.0 | — |
| `infeasible` | `rerun_relaxed` | 0.9 | `escalate` |
| `max_iterations` | `escalate` | 0.4 | `rebalance`, `hold` |
| optimal, no `currentWeights` | `rebalance` | c | `hold` |
| optimal, turnover < 0.02 | `hold` | 0.9 | `rebalance` |
| optimal, turnover > `maxTurnover` | `rebalance_partially` | c | `rebalance`, `hold` |
| optimal, otherwise | `rebalance` | c | `rebalance_partially`, `hold` |

c = 0.5 + 0.4 · tanh(sharpe), clamped to [0.05, 0.95] and rounded to 4 decimals. `reason` explains the choice in a sentence.

## Risk (portfolio-cpp)

For weights w: σ = √(wᵀΣw); over h = `horizonDays`: σₕ = σ√(h/252), μₕ = μᵀw · h/252 (0 without returns);
z = Φ⁻¹(`confidence`); VaR = V(zσₕ − μₕ); expected shortfall = V(σₕ φ(z)/(1 − confidence) − μₕ);
risk contribution RCᵢ = wᵢ(Σw)ᵢ / wᵀΣw; diversification ratio = Σ wᵢ√Σᵢᵢ / σ; concentration = Σ wᵢ².

## Portfolio contracts (analytics → Java / C++ → agents)

**`mxjobs.inputs/1`** (analytics `GET /inputs/{id}`): `assets`, `names`, `sectors` (one per asset),
`benchmarkWeights` (sum 1), `currentWeights` (asset → weight), `expectedReturns` (alpha or historical mean,
annualised), `covariance` (annualised), `statistics` (observations, period, shrinkage), `alpha` (model and top /
bottom names), `portfolio`, `benchmark`, `asOf`. Any endpoint taking `inputsUrl` merges the request over these fields
(request fields win) and only fetches from 127.0.0.1.

**`mxjobs.active-optimization/1`** (`POST /optimize/active`): request `inputsUrl` or the inputs fields, `maxWeight`
(0.05), `maxActiveWeight` (0.03), `maxSectorActive`, `trackingErrorTarget`, `riskAversion` (10), `maxTurnover`.
Outcome: `solverStatus`, `riskAversion`, `activeAlpha`, `trackingError`, `informationRatio`, `activeShare`,
`holdings`, `turnover`, `bindingConstraints`, `sectorActiveWeights`, `maxSectorActive`, `topActiveWeights`,
`bottomActiveWeights`, `trades` (20 largest), `weights`, `decisionContext`, `diagnostics`.
decisionContext: `escalate` (not converged), `rerun_relaxed` (sector band or TE target not met), `hold` (turnover
< 2%), `rebalance_partially` (turnover > maxTurnover), else `rebalance`; confidence 0.5 + 0.4 tanh(IR).

**`mxjobs.tracking/1`** (`POST /optimize/tracking`): request `inputsUrl` or the inputs fields, `maxNames` (0 = all),
`selection` (`stratified` | `largest`), `maxWeight` (1), `trackingErrorBudget` (0.01), `maxTurnover`. Outcome:
`solverStatus`, `method` (`full_replication`, `sampled_stratified`, `sampled_largest`), `names`, `trackingError`,
`currentTrackingError`, `benchmarkWeightCovered`, `turnover`, `sectorActiveWeights`, `maxSectorActive`, `trades`,
`weights`, `decisionContext`: `rerun_relaxed` when the tracking error exceeds the budget, `hold` when the current
portfolio is within budget and turnover < 2%, `rebalance_partially` above `maxTurnover`, else `rebalance`.

**`mxjobs.risk/1` additions** (`POST /risk` with `benchmarkWeights` or an `inputsUrl`): `trackingError`, `beta`,
`benchmarkVolatility`, `activeRiskContributions` (top 10: asset, active weight, share of active variance),
`sectorActiveRisk`, `withinTrackingErrorLimit` (with `maxTrackingError`). With `inputsUrl` and no `weights`, the
current weights are used.

**`mxjobs.attribution/1`** (`POST /attribution`): `period`, `assumptions`, `portfolioReturn`, `benchmarkReturn`,
`activeReturn`, `effects` {allocation, selection, interaction, residual}, `byGroup` (per sector: weights, effects,
total), `periods` (per month), `topContributors`, `bottomContributors`, `dataGaps`, `decisionContext`
{recommendation `publish` | `review`, confidence, reasons, highlight}.
