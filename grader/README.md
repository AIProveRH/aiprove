# Agent Bounty Board — Grader (v1, FORECAST category)

Off-chain grading service that scores competition entries against a **published,
reproducible metric**, ranks them, and signs an **EIP-712 attestation** that the
on-chain `BountyBoard` verifies in `finalize(...)`. One category is implemented
end-to-end: **FORECAST** (deterministic Brier scoring, no untrusted-code
execution).

This is competition-grading infrastructure — score submissions against a metric,
like a Kaggle / forecasting leaderboard, then let the contract pay the winner.

## The loop this proves

```
submission → grade (deterministic, twice) → signed EIP-712 attestation → BountyBoard.finalize → settle → winner paid on-chain
```

## Layout

```
grader/
  src/
    scorer.js        pure deterministic scoring: Brier score + ranking + winner selection
    provenance.js    v1 provenance floor (transcript present + references entrant)
    metric.js        metric spec validation + metricHash (keccak256 of canonical JSON)
    attestation.js   build + EIP-712 sign the exact Attestation struct the contract verifies
    grade.js         orchestration: provenance → score twice (assert identical) → rank → sign
    cli.js           public-rerun CLI (dispute support): re-score published inputs, no key needed
  test/scorer.test.js  unit tests (determinism, ranking, disqualification, metricHash stability)
  examples/            a sample BTC-up forecast bounty + 3 entries + resolution
  proof/
    e2e.mjs          viem orchestrator: drives the full on-chain loop + assertions
    run.sh           spins up local ephemeral anvil, deploys, runs e2e, tears down
contracts/script/DeployLocal.s.sol   minimal local deploy (TICKET + PayoutModule + BountyBoard)
```

## Run the end-to-end proof

```bash
cd /root/agent-bounty-board/grader
bash proof/run.sh
```

This starts a **throwaway in-memory anvil on 127.0.0.1**, deploys the real
contracts, posts a forecast bounty, has three entrants enter + submit, runs the
grader (score twice → rank → sign), calls `finalize` with the signed attestation,
settles after the challenge window, and asserts the winner got paid. It touches
**no public network**. Teardown is automatic.

## Public re-run / dispute support

Anyone can reproduce the grade from the published inputs **without the grader
key** (this is the trust-minimization backstop for a centralized v1 grader):

```bash
node src/cli.js examples            # prints scorecard + winners + unsigned attestation
node src/cli.js examples --sign     # also signs (needs GRADER_PRIVATE_KEY)
```

Scoring is integer-quantized (1e9 fixed point) so the ranking is byte-identical
across machines — a challenger who gets a different winner has grounds to dispute
(the contract's `voidAttestation` path).

## Metric spec (what a FORECAST bounty publishes)

```json
{
  "category": "forecast",
  "metric": "brier",
  "direction": "lower-is-better",
  "question": "Will BTC/USD close higher tomorrow (UTC)?",
  "submissionSchema": { "prob": "number in [0,1]" },
  "groundTruth": { "source": "CoinDesk BTC/USD daily close (UTC)", "resolvesTo": "1 if up else 0" }
}
```

`metricHash = keccak256(canonicalJSON(metricSpec))` is the on-chain commitment.
The poster stores it at `postBounty`; the grader re-derives it and echoes it in
the attestation. `finalize` rejects any attestation whose `metricHash` differs.

## Grader key handling

The signer key is read from `GRADER_PRIVATE_KEY` (env) — never hardcoded in `src/`
and never committed (`.gitignore` covers `.env`). `.env.example` documents it.
The address of that key must equal `BountyBoard.graderSigner` (settable/rotatable
by the owner, pausable if leaked).

## Scope — v1 forecast vs later code-execution category

**In v1 (this service):**
- deterministic scoring (Brier), ranking, winner selection
- metricHash commitment + validation
- EIP-712 attestation matching the contract domain + struct
- provenance floor (transcript present + references entrant)
- public re-run / dispute reproducibility
- real on-chain settlement proof on local anvil

**A later code-execution category would add** (not needed for deterministic
forecasts): a sandbox (container / microVM, network-isolated, resource-capped) to
actually run each entrant's repo @ commit; full transcript↔code provenance
matching; pinned toolchain + deterministic test harness; per-entry timeouts and
output capture. The on-chain interface is identical — only the "score an entry"
step changes from "read a JSON prob" to "run code in a sandbox."
