// Grading orchestration for the FORECAST category (v1).
//
// Pulls the pieces together into the flow the spec describes (§5 lane A):
//   published metric  ->  provenance check  ->  score the SAME WAY TWICE
//   (assert byte-identical = determinism / dispute support)  ->  rank
//   ->  select winner(s)  ->  build (+ optionally sign) the EIP-712 attestation.
//
// `gradeBounty` is pure + reproducible when { sign:false }: anyone can re-run it
// on the published inputs during the challenge window and must reproduce the same
// scorecard + winners (public-rerun dispute support). Signing is the only step
// that needs the grader key.

import { scoreForecast, selectWinners } from "./scorer.js";
import { checkProvenance } from "./provenance.js";
import { metricHash as computeMetricHash, validateForecastMetric, canonicalJSON } from "./metric.js";
import { buildAttestation, signAttestation } from "./attestation.js";

/**
 * @param {object} input
 * @param {object} input.bounty        { bountyId, metricSpec, onchainMetricHash?, attestNonce?, payout? }
 * @param {Array}  input.entries       [{ entrant, prediction, transcript, handle? }]
 * @param {object} input.resolution    { outcome: 0|1, ...provenance for audit }
 * @param {object} [input.domain]      { chainId, verifyingContract } — required to sign
 * @param {object} [input.opts]        { sign?: boolean, expiry?: unix, account? }
 * @returns {Promise<object>} grading report
 */
export async function gradeBounty({ bounty, entries, resolution, domain, opts = {} }) {
  const { metricSpec, bountyId } = bounty;

  // 1. metric must be one v1 can deterministically score
  validateForecastMetric(metricSpec);

  // 2. the published spec must hash to the on-chain commitment (if provided).
  //    finalize() rejects any attestation whose metricHash != bounty.metricHash,
  //    so we fail loudly here instead of producing an un-finalizable attestation.
  const derivedMetricHash = computeMetricHash(metricSpec);
  if (bounty.onchainMetricHash && bounty.onchainMetricHash.toLowerCase() !== derivedMetricHash.toLowerCase()) {
    throw new Error(
      `metricHash mismatch: published spec hashes to ${derivedMetricHash} but bounty committed ${bounty.onchainMetricHash}`
    );
  }

  // 3. provenance check (binds transcript to the claiming entrant)
  const prepared = entries.map((e) => {
    const prov = checkProvenance(e);
    return {
      entrant: e.entrant,
      prediction: e.prediction,
      provenanceOk: prov.ok,
      provenanceReason: prov.reason,
    };
  });

  // 4. score the SAME WAY TWICE and assert byte-identical (determinism gate)
  const passA = scoreForecast(prepared, resolution);
  const passB = scoreForecast(prepared, resolution);
  const canonA = canonicalJSON(passA);
  const canonB = canonicalJSON(passB);
  const determinismOk = canonA === canonB;
  if (!determinismOk) {
    throw new Error("non-deterministic scoring: two passes disagreed (refusing to attest)");
  }
  const scorecard = passA;

  // 5. select winner(s) + EIP-712 weights per the bounty's payout policy
  const { winners, weightsBps } = selectWinners(scorecard, bounty.payout);

  // 6. build the attestation
  const nowSec = Math.floor(Date.now() / 1000);
  const expiry = opts.expiry ?? nowSec + 24 * 3600;
  const attestation = buildAttestation({
    bountyId,
    metricHash: derivedMetricHash,
    winners,
    weightsBps,
    nonce: bounty.attestNonce ?? 0,
    expiry,
  });

  const report = {
    bountyId: String(bountyId),
    metricHash: derivedMetricHash,
    determinismOk,
    scorecard,
    winners,
    weightsBps,
    attestation: {
      bountyId: attestation.bountyId.toString(),
      metricHash: attestation.metricHash,
      winners: attestation.winners,
      weightsBps: attestation.weightsBps.map((w) => w.toString()),
      nonce: attestation.nonce.toString(),
      expiry: attestation.expiry.toString(),
    },
  };

  // 7. sign only if asked (needs the grader key + the on-chain domain)
  if (opts.sign) {
    if (!domain) throw new Error("signing requires domain { chainId, verifyingContract }");
    const { signature, signer } = await signAttestation(attestation, domain, opts.account);
    report.signature = signature;
    report.signer = signer;
    report.domain = { ...domain };
  }

  return report;
}
