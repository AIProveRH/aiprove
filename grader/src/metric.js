// Metric spec + the on-chain metric commitment (metricHash).
//
// A bounty publishes an objective metric spec. The poster commits to it on-chain
// by storing `metricHash` in the Bounty struct at postBounty(). The grader MUST
// put the identical metricHash in its signed Attestation, or finalize() reverts
// with BadAttestation. So metricHash is a hash commitment to the exact metric +
// ground-truth source everyone agreed to grade against.
//
// metricHash = keccak256( utf8( canonicalJSON(metricSpec) ) )
// Canonical JSON = keys sorted recursively, no insignificant whitespace — so the
// poster side and the grader side derive the same bytes32 from the same spec.

import { keccak256, toHex } from "viem";

/** Deterministic JSON: object keys sorted recursively, arrays preserved. */
export function canonicalJSON(value) {
  if (value === null || typeof value !== "object") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalJSON).join(",") + "]";
  }
  const keys = Object.keys(value).sort();
  return (
    "{" +
    keys.map((k) => JSON.stringify(k) + ":" + canonicalJSON(value[k])).join(",") +
    "}"
  );
}

/**
 * Compute the on-chain metricHash (bytes32) for a metric spec object.
 * This is the value the poster passes to postBounty and the grader echoes in
 * the attestation.
 */
export function metricHash(metricSpec) {
  const canonical = canonicalJSON(metricSpec);
  return keccak256(toHex(canonical));
}

/**
 * Validate a FORECAST metric spec. v1 supports the "brier" metric only.
 * Throws on anything the grader can't deterministically score.
 */
export function validateForecastMetric(metricSpec) {
  if (!metricSpec || typeof metricSpec !== "object") {
    throw new Error("metric spec missing");
  }
  if (metricSpec.category !== "forecast") {
    throw new Error(`grader v1 handles category "forecast", got "${metricSpec.category}"`);
  }
  if (metricSpec.metric !== "brier") {
    throw new Error(`grader v1 handles metric "brier", got "${metricSpec.metric}"`);
  }
  if (metricSpec.direction !== "lower-is-better") {
    throw new Error('brier metric requires direction "lower-is-better"');
  }
  if (!metricSpec.groundTruth || typeof metricSpec.groundTruth.source !== "string") {
    throw new Error("metric spec needs groundTruth.source (the published outcome source)");
  }
  return true;
}
