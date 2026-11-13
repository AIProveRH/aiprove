#!/usr/bin/env node
// Public-rerun CLI (dispute support).
//
//   grader <bountyDir> [--sign]
//
// <bountyDir> contains:
//   bounty.json      { bountyId, attestNonce?, onchainMetricHash?, payout, metricSpec }
//   resolution.json  { outcome: 0|1, source, ... }   (the published ground truth)
//   entries/*.json   { entrant, prediction:{prob}, transcript, handle? }
//
// Without --sign this runs the FULL deterministic grade (provenance + score twice
// + rank + winners) and prints the scorecard WITHOUT needing the grader key — so
// any challenger can reproduce the result during the challenge window.
// With --sign it also produces the EIP-712 signature (needs GRADER_PRIVATE_KEY).

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { gradeBounty } from "./grade.js";

function readJSON(p) {
  return JSON.parse(readFileSync(p, "utf8"));
}

function loadEntries(dir) {
  const entriesDir = join(dir, "entries");
  return readdirSync(entriesDir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => readJSON(join(entriesDir, f)));
}

async function main() {
  const args = process.argv.slice(2);
  const sign = args.includes("--sign");
  const dir = args.find((a) => !a.startsWith("--"));
  if (!dir) {
    console.error("usage: grader <bountyDir> [--sign]");
    process.exit(2);
  }

  const bounty = readJSON(join(dir, "bounty.json"));
  const resolution = readJSON(join(dir, "resolution.json"));
  const entries = loadEntries(dir);

  let domain;
  try {
    domain = readJSON(join(dir, "domain.json"));
  } catch {
    domain = undefined;
  }

  const report = await gradeBounty({
    bounty,
    entries,
    resolution,
    domain,
    opts: { sign },
  });

  console.log(JSON.stringify(report, null, 2));
}

main().catch((e) => {
  console.error("grade failed:", e.message);
  process.exit(1);
});
