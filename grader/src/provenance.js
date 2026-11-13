// Basic provenance check (v1).
//
// Spec §5 lane A: entrants submit a build transcript proving THEIR agent produced
// the entry. Full transcript<->code matching is a later (code-execution) category.
// For the FORECAST category v1 we do a lightweight, deterministic check:
//
//   1. a transcript string is present and non-trivial, and
//   2. it references the entrant (their on-chain address, or a declared handle).
//
// This is deliberately a floor, not a forgery-proof check — it rejects empty /
// copy-paste-of-someone-else's submissions and binds the transcript to the
// claiming entrant, which is all v1 needs. It never executes the transcript.

const MIN_TRANSCRIPT_LEN = 32;

/**
 * @param {object} entry { entrant (0x address), transcript (string), handle? }
 * @returns {{ ok: boolean, reason: string|null }}
 */
export function checkProvenance(entry) {
  const { entrant, transcript, handle } = entry;

  if (typeof transcript !== "string" || transcript.trim().length < MIN_TRANSCRIPT_LEN) {
    return { ok: false, reason: `transcript missing or shorter than ${MIN_TRANSCRIPT_LEN} chars` };
  }

  const hay = transcript.toLowerCase();
  const refs = [];
  if (typeof entrant === "string" && entrant.length > 0) refs.push(entrant.toLowerCase());
  if (typeof handle === "string" && handle.length > 0) refs.push(handle.toLowerCase());

  const referencesEntrant = refs.some((r) => hay.includes(r));
  if (!referencesEntrant) {
    return { ok: false, reason: "transcript does not reference the entrant (address or handle)" };
  }

  return { ok: true, reason: null };
}
