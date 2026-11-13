import { test } from "node:test";
import assert from "node:assert/strict";
import { brierScore, scoreForecast, selectWinners } from "../src/scorer.js";
import { checkProvenance } from "../src/provenance.js";
import { metricHash, canonicalJSON, validateForecastMetric } from "../src/metric.js";

test("brier score: perfect vs wrong", () => {
  // outcome=1: prob 1.0 -> 0 ; prob 0.0 -> 1 (1e9 scaled)
  assert.equal(brierScore(1.0, 1).toString(), "0");
  assert.equal(brierScore(0.0, 1).toString(), "1000000000");
  // prob 0.82, outcome 1 -> 0.0324 -> 32400000
  assert.equal(brierScore(0.82, 1).toString(), "32400000");
});

test("brier rejects out-of-range prob", () => {
  assert.throws(() => brierScore(1.5, 1));
  assert.throws(() => brierScore(-0.1, 0));
});

test("scoreForecast ranks lower-brier first and disqualifies bad provenance", () => {
  const entries = [
    { entrant: "0xAAA", prediction: { prob: 0.82 }, provenanceOk: true },
    { entrant: "0xBBB", prediction: { prob: 0.35 }, provenanceOk: true },
    { entrant: "0xCCC", prediction: { prob: 0.99 }, provenanceOk: false, provenanceReason: "no transcript" },
  ];
  const sc = scoreForecast(entries, { outcome: 1 });
  const byEntrant = Object.fromEntries(sc.map((r) => [r.entrant, r]));
  assert.equal(byEntrant["0xaaa"].rank, 1); // best brier
  assert.equal(byEntrant["0xbbb"].rank, 2);
  assert.equal(byEntrant["0xccc"].valid, false);
  assert.equal(byEntrant["0xccc"].rank, null); // disqualified despite best prob
});

test("scoring is deterministic (two passes byte-identical)", () => {
  const entries = [
    { entrant: "0xAAA", prediction: { prob: 0.4214 }, provenanceOk: true },
    { entrant: "0xBBB", prediction: { prob: 0.4213 }, provenanceOk: true },
  ];
  const a = canonicalJSON(scoreForecast(entries, { outcome: 1 }));
  const b = canonicalJSON(scoreForecast(entries, { outcome: 1 }));
  assert.equal(a, b);
});

test("tie-break is deterministic by entrant address", () => {
  const entries = [
    { entrant: "0xBBB", prediction: { prob: 0.7 }, provenanceOk: true },
    { entrant: "0xAAA", prediction: { prob: 0.7 }, provenanceOk: true },
  ];
  const sc = scoreForecast(entries, { outcome: 1 });
  const ranked = sc.filter((r) => r.valid).sort((x, y) => x.rank - y.rank);
  assert.equal(ranked[0].entrant, "0xaaa"); // lower address wins the tie
});

test("selectWinners winner-take-all", () => {
  const sc = scoreForecast(
    [
      { entrant: "0xAAA", prediction: { prob: 0.82 }, provenanceOk: true },
      { entrant: "0xBBB", prediction: { prob: 0.35 }, provenanceOk: true },
    ],
    { outcome: 1 }
  );
  const { winners, weightsBps } = selectWinners(sc, { type: "winner-take-all" });
  assert.deepEqual(winners, ["0xaaa"]);
  assert.deepEqual(weightsBps, [10000]);
});

test("selectWinners top-n weights must sum to 10000", () => {
  const sc = scoreForecast(
    [
      { entrant: "0xAAA", prediction: { prob: 0.82 }, provenanceOk: true },
      { entrant: "0xBBB", prediction: { prob: 0.35 }, provenanceOk: true },
    ],
    { outcome: 1 }
  );
  const { winners, weightsBps } = selectWinners(sc, { type: "top-n", weightsBps: [7000, 3000] });
  assert.deepEqual(winners, ["0xaaa", "0xbbb"]);
  assert.deepEqual(weightsBps, [7000, 3000]);
  assert.throws(() => selectWinners(sc, { type: "top-n", weightsBps: [6000, 3000] }));
});

test("provenance: present + references entrant", () => {
  assert.equal(
    checkProvenance({ entrant: "0xABCDEF0000000000000000000000000000000001", transcript: "x" }).ok,
    false
  );
  const good = checkProvenance({
    entrant: "0xABCDEF0000000000000000000000000000000001",
    transcript: "agent run by 0xabcdef0000000000000000000000000000000001 produced the forecast",
  });
  assert.equal(good.ok, true);
});

test("metricHash is stable regardless of key order", () => {
  const a = metricHash({ category: "forecast", metric: "brier", z: 1, a: 2 });
  const b = metricHash({ a: 2, z: 1, metric: "brier", category: "forecast" });
  assert.equal(a, b);
  assert.match(a, /^0x[0-9a-f]{64}$/);
});

test("validateForecastMetric accepts brier spec, rejects others", () => {
  assert.ok(
    validateForecastMetric({
      category: "forecast",
      metric: "brier",
      direction: "lower-is-better",
      groundTruth: { source: "x" },
    })
  );
  assert.throws(() => validateForecastMetric({ category: "code", metric: "tests" }));
});
