// EIP-712 attestation: build + sign the exact struct BountyBoard.finalize() verifies.
//
// Contract interface this MUST match (contracts/src/BountyBoard.sol):
//   domain:   EIP712("AgentBountyBoard", "1")  + chainId + verifyingContract(board)
//   typehash: Attestation(uint256 bountyId,bytes32 metricHash,address[] winners,
//                         uint256[] weightsBps,uint256 nonce,uint256 expiry)
//   checks in finalize(): bountyId==id, metricHash==bounty.metricHash,
//     nonce==bounty.attestNonce, expiry>=now, winners all entered,
//     sum(weightsBps)==10000, ECDSA.recover(sig)==graderSigner.

import { privateKeyToAccount } from "viem/accounts";

export const EIP712_DOMAIN_NAME = "AgentBountyBoard";
export const EIP712_DOMAIN_VERSION = "1";

export const ATTESTATION_TYPES = {
  Attestation: [
    { name: "bountyId", type: "uint256" },
    { name: "metricHash", type: "bytes32" },
    { name: "winners", type: "address[]" },
    { name: "weightsBps", type: "uint256[]" },
    { name: "nonce", type: "uint256" },
    { name: "expiry", type: "uint256" },
  ],
};

/**
 * Load the grader signer from the environment. NEVER hardcode / commit this key.
 * @param {string} [pk] optional explicit key; defaults to process.env.GRADER_PRIVATE_KEY
 */
export function loadGraderAccount(pk = process.env.GRADER_PRIVATE_KEY) {
  if (!pk) {
    throw new Error("GRADER_PRIVATE_KEY not set (export it; never hardcode the grader key)");
  }
  const key = pk.startsWith("0x") ? pk : `0x${pk}`;
  return privateKeyToAccount(key);
}

/**
 * Build the Attestation message object (values typed for viem / EIP-712).
 * @param {object} p
 * @param {bigint|number|string} p.bountyId
 * @param {`0x${string}`} p.metricHash
 * @param {string[]} p.winners
 * @param {Array<number|bigint>} p.weightsBps
 * @param {bigint|number} p.nonce
 * @param {bigint|number} p.expiry  unix seconds
 */
export function buildAttestation({ bountyId, metricHash, winners, weightsBps, nonce, expiry }) {
  const sum = weightsBps.reduce((a, b) => a + Number(b), 0);
  if (sum !== 10000) {
    throw new Error(`weightsBps must sum to 10000, got ${sum}`);
  }
  if (winners.length !== weightsBps.length) {
    throw new Error("winners and weightsBps length mismatch");
  }
  if (winners.length === 0) {
    throw new Error("attestation needs at least one winner");
  }
  return {
    bountyId: BigInt(bountyId),
    metricHash,
    winners,
    weightsBps: weightsBps.map((w) => BigInt(w)),
    nonce: BigInt(nonce),
    expiry: BigInt(expiry),
  };
}

/**
 * Sign the attestation with the grader key. Returns { attestation, signature, signer }.
 * @param {object} attestation  from buildAttestation()
 * @param {object} domainCtx    { chainId, verifyingContract }
 * @param {object} [account]    viem account; defaults to loadGraderAccount()
 */
export async function signAttestation(attestation, domainCtx, account = loadGraderAccount()) {
  const { chainId, verifyingContract } = domainCtx;
  if (!chainId || !verifyingContract) {
    throw new Error("domainCtx needs { chainId, verifyingContract }");
  }
  const domain = {
    name: EIP712_DOMAIN_NAME,
    version: EIP712_DOMAIN_VERSION,
    chainId: Number(chainId),
    verifyingContract,
  };
  const signature = await account.signTypedData({
    domain,
    types: ATTESTATION_TYPES,
    primaryType: "Attestation",
    message: attestation,
  });
  return { attestation, signature, signer: account.address };
}
