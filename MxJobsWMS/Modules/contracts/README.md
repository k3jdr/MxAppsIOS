# MxJobsWMS Layer 3 contracts

Versioned JSON contracts between the Layer 3 compute services and the Layer 2 decision agents.

| Schema | File | Served by |
| ------ | ---- | --------- |
| `mxjobs.optimize-request/1` | [optimize-request.schema.json](optimize-request.schema.json) | request of `POST /optimize` |
| `mxjobs.optimization/1` | [optimization.schema.json](optimization.schema.json) | `POST /optimize` — `portfolio-java` (127.0.0.1:8766), `portfolio-cpp` (127.0.0.1:8767) |
| `mxjobs.risk/1` | [risk.schema.json](risk.schema.json) | `POST /risk` — `portfolio-cpp` |

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
