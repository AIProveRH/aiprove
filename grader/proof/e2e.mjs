// End-to-end proof: submission -> grade -> signed attestation -> contract pays.
//
// Runs the REAL loop against a LOCAL EPHEMERAL anvil (127.0.0.1, in-memory).
// NOTHING here touches a public chain / Robinhood Chain / any real RPC.
//
// Steps:
//   1. read deployed addresses from the forge broadcast artifact
//   2. poster posts an AutoGrade FORECAST bounty (reward in $TICKET) + burn-to-post
//   3. alice/bob/carol enter (free) + submit provenance hashes
//   4. warp past the deadline
//   5. the GRADER service scores (twice, deterministic) + ranks + signs an EIP-712
//      attestation with its key (matching the board's domain)
//   6. finalize(id, attestation, sig) on the real deployed BountyBoard
//   7. warp past the challenge window; settle(id)
//   8. assert the winner received the escrowed reward on-chain

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  createWalletClient,
  createTestClient,
  http,
  keccak256,
  toHex,
  parseEther,
  getAbiItem,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import { gradeBounty } from "../src/grade.js";
import { metricHash as deriveMetricHash } from "../src/metric.js";

const __dir = dirname(fileURLToPath(import.meta.url));
const RPC = process.env.RPC_URL || "http://127.0.0.1:8545";
const CONTRACTS = join(__dir, "..", "..", "contracts");

// anvil default accounts (deterministic) -------------------------------------
const PK = {
  deployer: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // [0]
  alice: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // [1]
  bob: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", // [2]
  carol: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", // [3]
  poster: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a", // [4]
};
const TREASURY = "0x976EA74026E726554dB657fA54763abd0C3a0aa9"; // [6]

const acc = Object.fromEntries(Object.entries(PK).map(([k, v]) => [k, privateKeyToAccount(v)]));

// grader key from env (never hardcoded in the service)
const graderAccount = privateKeyToAccount(process.env.GRADER_PRIVATE_KEY);

// --- load ABIs + deployed addresses -----------------------------------------
function loadAbi(name) {
  const art = JSON.parse(readFileSync(join(CONTRACTS, "out", `${name}.sol`, `${name}.json`), "utf8"));
  return art.abi;
}
const boardAbi = loadAbi("BountyBoard");
const ticketAbi = loadAbi("TICKET");

function loadDeployment() {
  const run = JSON.parse(
    readFileSync(join(CONTRACTS, "broadcast", "DeployLocal.s.sol", "31337", "run-latest.json"), "utf8")
  );
  const addrs = {};
  for (const tx of run.transactions) {
    if (tx.transactionType === "CREATE") addrs[tx.contractName] = tx.contractAddress;
  }
  return { ticket: addrs.TICKET, board: addrs.BountyBoard };
}

// --- clients -----------------------------------------------------------------
const pub = createPublicClient({ chain: foundry, transport: http(RPC) });
const test = createTestClient({ chain: foundry, mode: "anvil", transport: http(RPC) });
function wallet(account) {
  return createWalletClient({ account, chain: foundry, transport: http(RPC) });
}

async function send(account, address, abi, functionName, args) {
  const { request } = await pub.simulateContract({ account, address, abi, functionName, args });
  const hash = await wallet(account).writeContract(request);
  return pub.waitForTransactionReceipt({ hash });
}

function eq(label, got, want) {
  const g = got.toString();
  const w = want.toString();
  if (g !== w) throw new Error(`ASSERT FAIL [${label}]: got ${g}, want ${w}`);
  console.log(`  ok  ${label} = ${g}`);
}

async function main() {
  const { ticket, board } = loadDeployment();
  console.log("LOCAL EPHEMERAL anvil:", RPC, "chainId", await pub.getChainId());
  console.log("TICKET", ticket, "| BOARD", board);
  console.log("grader signer (from GRADER_PRIVATE_KEY):", graderAccount.address);

  // sanity: deployed grader signer matches our key
  const onchainSigner = await pub.readContract({ address: board, abi: boardAbi, functionName: "graderSigner" });
  eq("board.graderSigner == grader key", onchainSigner, graderAccount.address);

  // published metric spec (same object the grader hashes)
  const bountyJson = JSON.parse(readFileSync(join(__dir, "..", "examples", "bounty.json"), "utf8"));
  const metricSpec = bountyJson.metricSpec;
  const metricHashHex = deriveMetricHash(metricSpec);
  const category = keccak256(toHex("forecast"));
  const reward = parseEther("1000"); // 1000 TICKET reward

  // 2. POST (poster) — approve, then postBounty(AutoGrade, ...)
  await send(acc.poster, ticket, ticketAbi, "approve", [board, parseEther("100000000")]);
  const nowBlock = await pub.getBlock();
  const deadline = Number(nowBlock.timestamp) + 3600;
  await send(acc.poster, board, boardAbi, "postBounty", [
    0, // Mode.AutoGrade
    category,
    metricHashHex,
    ticket, // reward token = TICKET
    reward,
    BigInt(deadline),
  ]);
  const id = await pub.readContract({ address: board, abi: boardAbi, functionName: "bountyCount" });
  console.log(`\n[post] bounty #${id} posted: reward ${reward} TICKET, metricHash ${metricHashHex}`);

  // 3. ENTER (free) + SUBMIT (provenance hashes) for alice, bob, carol
  for (const name of ["alice", "bob", "carol"]) {
    await send(acc[name], board, boardAbi, "enter", [id]);
    await send(acc[name], board, boardAbi, "submit", [
      id,
      keccak256(toHex(`repo-${name}`)),
      keccak256(toHex(`transcript-${name}`)),
    ]);
  }
  console.log("[enter] alice, bob, carol entered + submitted (free)");

  // 4. warp past deadline
  await test.increaseTime({ seconds: 3601 });
  await test.mine({ blocks: 1 });

  // 5. GRADER: read on-chain commitment, score, rank, sign
  const chainBounty = await pub.readContract({ address: board, abi: boardAbi, functionName: "getBounty", args: [id] });
  const entries = ["01-alice", "02-bob", "03-carol"].map((f) =>
    JSON.parse(readFileSync(join(__dir, "..", "examples", "entries", `${f}.json`), "utf8"))
  );
  const resolution = JSON.parse(readFileSync(join(__dir, "..", "examples", "resolution.json"), "utf8"));
  const blk = await pub.getBlock();

  const report = await gradeBounty({
    bounty: {
      bountyId: id,
      metricSpec,
      onchainMetricHash: chainBounty.metricHash,
      attestNonce: chainBounty.attestNonce,
      payout: bountyJson.payout,
    },
    entries,
    resolution,
    domain: { chainId: await pub.getChainId(), verifyingContract: board },
    opts: { sign: true, account: graderAccount, expiry: Number(blk.timestamp) + 86400 },
  });

  console.log("\n[grade] determinismOk:", report.determinismOk);
  console.log("[grade] scorecard:");
  for (const r of report.scorecard) {
    console.log(`    ${r.entrant}  valid=${r.valid}  score=${r.scoreScaled}  rank=${r.rank}${r.reason ? "  (" + r.reason + ")" : ""}`);
  }
  console.log("[grade] winners:", report.winners, "weightsBps:", report.weightsBps);
  console.log("[grade] signer:", report.signer, "sig:", report.signature.slice(0, 22) + "...");

  // 5b. NEGATIVE CHECK: a forged attestation signed by a NON-grader key must be
  //     rejected by the contract (proves finalize really verifies the signer).
  const { signAttestation } = await import("../src/attestation.js");
  const forged = await signAttestation(
    {
      bountyId: BigInt(id),
      metricHash: chainBounty.metricHash,
      winners: report.attestation.winners,
      weightsBps: report.attestation.weightsBps.map((w) => BigInt(w)),
      nonce: BigInt(report.attestation.nonce),
      expiry: BigInt(report.attestation.expiry),
    },
    { chainId: await pub.getChainId(), verifyingContract: board },
    acc.deployer // WRONG signer (not the grader)
  );
  const forgedAtt = {
    bountyId: BigInt(id),
    metricHash: chainBounty.metricHash,
    winners: report.attestation.winners,
    weightsBps: report.attestation.weightsBps.map((w) => BigInt(w)),
    nonce: BigInt(report.attestation.nonce),
    expiry: BigInt(report.attestation.expiry),
  };
  let rejected = false;
  try {
    await pub.simulateContract({ account: acc.deployer, address: board, abi: boardAbi, functionName: "finalize", args: [id, forgedAtt, forged.signature] });
  } catch (e) {
    rejected = true;
    console.log("\n[neg] forged (non-grader) attestation correctly rejected:", e.shortMessage || "revert");
  }
  if (!rejected) throw new Error("ASSERT FAIL: contract accepted a non-grader signature");

  // 6. FINALIZE on the real deployed board with the signed attestation
  const att = {
    bountyId: BigInt(report.attestation.bountyId),
    metricHash: report.attestation.metricHash,
    winners: report.attestation.winners,
    weightsBps: report.attestation.weightsBps.map((w) => BigInt(w)),
    nonce: BigInt(report.attestation.nonce),
    expiry: BigInt(report.attestation.expiry),
  };
  await send(acc.deployer, board, boardAbi, "finalize", [id, att, report.signature]);
  const stAfterFinalize = (await pub.readContract({ address: board, abi: boardAbi, functionName: "getBounty", args: [id] })).state;
  console.log(`\n[finalize] accepted by contract. state=${stAfterFinalize} (2=Finalized, challenge window open)`);
  eq("state == Finalized", stAfterFinalize, 2);

  // 7. warp past challenge window + settle
  const winner = report.winners[0];
  const aliceBefore = await pub.readContract({ address: ticket, abi: ticketAbi, functionName: "balanceOf", args: [winner] });
  const treasBefore = await pub.readContract({ address: ticket, abi: ticketAbi, functionName: "balanceOf", args: [TREASURY] });

  await test.increaseTime({ seconds: 2 * 24 * 3600 + 1 }); // challengeWindow = 2 days
  await test.mine({ blocks: 1 });
  await send(acc.deployer, board, boardAbi, "settle", [id]);
  console.log("[settle] escrow released");

  // 8. ASSERT winner got paid on-chain
  const aliceAfter = await pub.readContract({ address: ticket, abi: ticketAbi, functionName: "balanceOf", args: [winner] });
  const treasAfter = await pub.readContract({ address: ticket, abi: ticketAbi, functionName: "balanceOf", args: [TREASURY] });
  const stFinal = (await pub.readContract({ address: board, abi: boardAbi, functionName: "getBounty", args: [id] })).state;
  const escrowFinal = await pub.readContract({ address: board, abi: boardAbi, functionName: "escrowed", args: [ticket] });

  const rake = (reward * 400n) / 10000n; // gmvRakeBps default 400
  const payout = reward - rake;

  console.log("\n=== ON-CHAIN SETTLEMENT ASSERTIONS ===");
  eq("winner (alice) received payout", aliceAfter - aliceBefore, payout);
  eq("treasury received GMV rake", treasAfter - treasBefore, rake);
  eq("escrow fully cleared", escrowFinal, 0n);
  eq("bounty state == Settled", stFinal, 5);

  console.log("\nPROOF PASSED: submission -> grade -> signed attestation -> contract paid the winner on-chain.");
  console.log(`winner ${winner} +${payout} TICKET | treasury +${rake} TICKET (rake) | escrow=0`);
}

main().catch((e) => {
  console.error("\nE2E FAILED:", e.shortMessage || e.message);
  console.error(e);
  process.exit(1);
});
