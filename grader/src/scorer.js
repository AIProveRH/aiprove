// Deterministic scoring core for the Agent Bounty Board.
//
// Pure functions, no I/O, no network, no wall-clock. Given the same inputs they
// return byte-identical output every time — this is what makes the grader
// publicly re-runnable (dispute support): anyone can re-run `score()` on the
// published entries + resolution and must get the exact same ranking.
//
// Scores are quantized to fixed-point integers (SCALE = 1e9) so ranking never
// depends on float equality and the canonical scorecard is reproducible across
// machines.

export const SCALE = 1_000_000_000n; // 1e9 fixed-point

/** Quantize a JS number in [0,1]-ish range to a BigInt * 1e9 (round half up). */
function quantize(x) {
  // x is a non-negative real; scale and round to nearest integer deterministically.
  const scaled = x * 1e9;
  return BigInt(Math.round(scaled));
}

/**
 * Brier score for a binary event: (prob - outcome)^2, outcome in {0,1}.
 * Lower is better. Returns a BigInt in 1e9 fixed-point.
 */
export function brierScore(prob, outcome) {
  if (typeof prob !== "number" || Number.isNaN(prob)) {
    throw new Error("prob must be a number");
  }
  if (prob < 0 || prob > 1) {
    throw new Error("prob out of range [0,1]");
  }
  if (outcome !== 0 && outcome !== 1) {
    throw new Error("outcome must be 0 or 1");
  }
  const diff = prob - outcome;
  return quantize(diff * diff);
}

/**
 * Validate + extract a single entry's prediction for the brier metric.
 * Returns { valid, prob, reason }.
 */
export function readForecastPrediction(prediction) {
  if (prediction == null || typeof prediction !== "object") {
    return { valid: false, reason: "prediction missing or not an object" };
  }
  const prob = prediction.prob;
  if (typeof prob !== "number" || Number.isNaN(prob)) {
    return { valid: false, reason: "prob is not a number" };
  }
  if (prob < 0 || prob > 1) {
    return { valid: false, reason: "prob out of range [0,1]" };
  }
  return { valid: true, prob };
}

/**
 * Score a set of forecast entries against a realized outcome.
 *
 * @param {Array<{entrant:string, prediction:object, provenanceOk:boolean}>} entries
 * @param {{outcome:0|1}} resolution
 * @returns {Array} scorecard rows, each:
 *   { entrant, valid, reason, scoreScaled (BigInt string), rank (1-based or null) }
 *   Ranked ascending by brier (lower = better). Invalid / provenance-failed
 *   entries are included but unranked (rank: null) and never win.
 */
export function scoreForecast(entries, resolution) {
  if (!resolution || (resolution.outcome !== 0 && resolution.outcome !== 1)) {
    throw new Error("resolution.outcome must be 0 or 1");
  }
  const outcome = resolution.outcome;

  const rows = entries.map((e) => {
    if (!e.provenanceOk) {
      return {
        entrant: e.entrant.toLowerCase(),
        valid: false,
        reason: e.provenanceReason || "provenance check failed",
        scoreScaled: null,
      };
    }
    const r = readForecastPrediction(e.prediction);
    if (!r.valid) {
      return {
        entrant: e.entrant.toLowerCase(),
        valid: false,
        reason: r.reason,
        scoreScaled: null,
      };
    }
    return {
      entrant: e.entrant.toLowerCase(),
      valid: true,
      reason: null,
      scoreScaled: brierScore(r.prob, outcome).toString(),
    };
  });

  // Rank the valid rows. Lower brier is better. Deterministic tie-break by
  // entrant address ascending (so the ordering is reproducible by anyone).
  const ranked = rows
    .filter((r) => r.valid)
    .sort((a, b) => {
      const sa = BigInt(a.scoreScaled);
      const sb = BigInt(b.scoreScaled);
      if (sa < sb) return -1;
      if (sa > sb) return 1;
      return a.entrant < b.entrant ? -1 : a.entrant > b.entrant ? 1 : 0;
    });

  ranked.forEach((r, i) => {
    r.rank = i + 1;
  });
  rows.forEach((r) => {
    if (r.rank == null) r.rank = null;
  });

  return rows;
}

/**
 * Pick winners + EIP-712 weightsBps from a ranked scorecard, per a payout policy.
 *
 * policy = { type: "winner-take-all" }
 *        | { type: "top-n", weightsBps: number[] }   // weightsBps sum to 10000
 *
 * Returns { winners: string[], weightsBps: number[] } in rank order.
 * Throws if there are not enough valid entries to satisfy the policy.
 */
export function selectWinners(scorecard, policy) {
  const ranked = scorecard
    .filter((r) => r.valid && r.rank != null)
    .sort((a, b) => a.rank - b.rank);

  if (ranked.length === 0) {
    throw new Error("no valid entries to select a winner from");
  }

  if (!policy || policy.type === "winner-take-all") {
    return { winners: [ranked[0].entrant], weightsBps: [10000] };
  }

  if (policy.type === "top-n") {
    const weights = policy.weightsBps;
    if (!Array.isArray(weights) || weights.length === 0) {
      throw new Error("top-n policy needs weightsBps[]");
    }
    const sum = weights.reduce((a, b) => a + b, 0);
    if (sum !== 10000) {
      throw new Error(`top-n weightsBps must sum to 10000, got ${sum}`);
    }
    if (ranked.length < weights.length) {
      throw new Error(
        `top-n needs ${weights.length} valid entries, only ${ranked.length} available`
      );
    }
    return {
      winners: ranked.slice(0, weights.length).map((r) => r.entrant),
      weightsBps: weights.slice(),
    };
  }

  throw new Error(`unknown payout policy type: ${policy.type}`);
}
