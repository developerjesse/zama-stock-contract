// ConfidentialStock end-to-end proof of concept on Sepolia, using the Zama SDK.
//
// Roles (one wallet each, so it is obvious who can do what):
//   ADMIN      issuer/agent: mint, corporate actions, disclose. Cannot read balances.
//   TREASURY   holds minted shares, distributes with confidentialTransfer.
//   REGISTRAR  internal auditor: standing read access to every balance and transfer amount. Cannot move anything.
//   ALICE/BOB  holders (throwaway keys generated per run, no ETH needed: decrypting is an off-chain signature).
//   REGULATOR  sees nothing until the admin calls disclose(holder, regulator).
//
// Run from demo/ (reads ../.env). Steps can run separately; Alice/Bob keys persist in demo/.state.json.
//   npm start                              all steps in order
//   npm start -- split dividend            only these steps
// Steps: mint, distribute, holders, registrar, split, dividend, regulator

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import {
  createPublicClient,
  createWalletClient,
  formatUnits,
  http,
  parseAbi,
  toEventSelector,
  type Hex,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { sepolia as viemSepolia } from "viem/chains";
import { MemoryStorage, ZamaSDK } from "@zama-fhe/sdk";
import type { Address } from "@zama-fhe/sdk";
import { sepolia, type FheChain } from "@zama-fhe/sdk/chains";
import { createConfig } from "@zama-fhe/sdk/viem";
import { node } from "@zama-fhe/sdk/node";

// ── Config ───────────────────────────────────────────────────────────────────
const DECIMALS = 6;
const ONE_SHARE = 10n ** BigInt(DECIMALS);
const WAD = 10n ** 18n;
const MINT_RAW = 1_000_000n * ONE_SHARE; // 1,000,000 shares to the treasury
const ALICE_RAW = 600n * ONE_SHARE;
const BOB_RAW = 400n * ONE_SHARE;

function env(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}

const RPC_URL = env("RPC_URL");
const STOCK = env("STOCK_ADDRESS") as Address;

const ABI = parseAbi([
  "function mint(uint64 rawAmount)",
  "function applyCorporateAction(uint256 numerator, uint256 denominator, string kind)",
  "function disclose(address holder, address regulator)",
  "function multiplier() view returns (uint256)",
  "function rawTotalSupply() view returns (uint64)",
  "function publishedSupply() view returns (uint256)",
  "function registrar() view returns (address)",
  "function treasury() view returns (address)",
]);

const TRANSFER_TOPIC = toEventSelector("ConfidentialTransfer(address,address,bytes32)");

// ── Clients ──────────────────────────────────────────────────────────────────
const transport = http(RPC_URL);
// No relayer URL needed on Sepolia: the preset carries it.
const zamaSepolia = { ...sepolia, network: RPC_URL } as const satisfies FheChain;
const publicClient = createPublicClient({ chain: viemSepolia, transport });

function makeRole(name: string, key: Hex) {
  const account = privateKeyToAccount(key);
  const walletClient = createWalletClient({ account, chain: viemSepolia, transport });
  const sdk = new ZamaSDK(
    createConfig({
      chains: [zamaSepolia],
      publicClient,
      walletClient,
      storage: new MemoryStorage(),
      relayers: { [zamaSepolia.id]: node() },
    }),
  );
  const token = sdk.createToken(STOCK);
  return { name, account, address: account.address as Address, walletClient, sdk, token };
}
type Role = ReturnType<typeof makeRole>;

// ── Output helpers ───────────────────────────────────────────────────────────
let failures = 0;
const section = (t: string) => console.log(`\n${"═".repeat(64)}\n  ${t}\n${"═".repeat(64)}`);
const shares = (raw: bigint) => formatUnits(raw, DECIMALS);
const displayed = (raw: bigint, multiplier: bigint) => (raw * multiplier) / WAD;
const txLink = (h: string) => `https://eth-sepolia.blockscout.com/tx/${h}`;
function check(label: string, ok: boolean) {
  if (!ok) failures++;
  console.log(`  ${ok ? "✓" : "✗ FAILED:"} ${label}`);
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Decrypt that is EXPECTED to work. Retries because the relayer needs time to see fresh ACL grants. */
async function mustDecrypt(label: string, fn: () => Promise<bigint>, tries = 2): Promise<bigint> {
  for (let i = 1; ; i++) {
    try {
      return await fn();
    } catch (err) {
      if (i >= tries) throw err;
      const msg = err instanceof Error ? err.message.split("\n")[0] : String(err);
      console.log(`  … ${label}: ${msg.slice(0, 140)} (attempt ${i}/${tries}), retrying in 10s`);
      await sleep(10_000);
    }
  }
}

/** Decrypt that is EXPECTED to be denied. Returns true if it was denied. */
async function expectDenied(label: string, fn: () => Promise<bigint>): Promise<boolean> {
  try {
    const v = await fn();
    console.log(`  ✗ ${label}: UNEXPECTEDLY decrypted to ${shares(v)}`);
    return false;
  } catch (err) {
    const msg = err instanceof Error ? err.message.split("\n")[0] : String(err);
    console.log(`  🔒 ${label}: denied (${msg.slice(0, 90)})`);
    return true;
  }
}

async function send(role: Role, label: string, hashPromise: Promise<Hex>) {
  const hash = await hashPromise;
  console.log(`  ${role.name} → ${label}\n    ${txLink(hash)}`);
  await publicClient.waitForTransactionReceipt({ hash });
}

async function readState() {
  const [multiplier, rawSupply, published] = await Promise.all([
    publicClient.readContract({ address: STOCK, abi: ABI, functionName: "multiplier" }),
    publicClient.readContract({ address: STOCK, abi: ABI, functionName: "rawTotalSupply" }),
    publicClient.readContract({ address: STOCK, abi: ABI, functionName: "publishedSupply" }),
  ]);
  return { multiplier, rawSupply, published };
}
function printState(s: Awaited<ReturnType<typeof readState>>) {
  console.log(
    `  public state: multiplier=${formatUnits(s.multiplier, 18)}  rawTotalSupply=${shares(s.rawSupply)}  publishedSupply=${shares(s.published)}`,
  );
}

async function applyAction(admin: Role, num: bigint, den: bigint, kind: string) {
  await send(
    admin,
    `applyCorporateAction(${num}, ${den}, "${kind}")`,
    admin.walletClient.writeContract({
      address: STOCK,
      abi: ABI,
      functionName: "applyCorporateAction",
      args: [num, den, kind],
    }),
  );
}

// ── Persisted holder state ───────────────────────────────────────────────────
const STATE_FILE = new URL("./.state.json", import.meta.url);
type State = { aliceKey?: Hex; bobKey?: Hex; transferHandles?: Record<string, Hex> };
const loadState = (): State => (existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : {});
const saveState = (s: State) => writeFileSync(STATE_FILE, JSON.stringify(s, null, 2));

// ── Main ─────────────────────────────────────────────────────────────────────
const ALL_STEPS = ["mint", "distribute", "holders", "registrar", "split", "dividend", "regulator"] as const;
type Step = (typeof ALL_STEPS)[number];

async function main() {
  const requested = process.argv.slice(2);
  for (const r of requested) if (!ALL_STEPS.includes(r as Step)) throw new Error(`Unknown step "${r}". Steps: ${ALL_STEPS.join(", ")}`);
  const steps = new Set<string>(requested.length ? requested : ALL_STEPS);

  section("0. Setup: who is who");
  const state = loadState();
  const admin = makeRole("ADMIN", env("DEPLOYER_PRIVATE_KEY") as Hex);
  const treasury = makeRole("TREASURY", env("TREASURY_PRIVATE_KEY") as Hex);
  const registrar = makeRole("REGISTRAR", env("REGISTRAR_PRIVATE_KEY") as Hex);
  const regulator = makeRole("REGULATOR", env("REGULATOR_PRIVATE_KEY") as Hex);
  const needsHolders = ["distribute", "holders", "registrar", "regulator"].some((s) => steps.has(s));
  if (steps.has("distribute")) {
    state.aliceKey = generatePrivateKey();
    state.bobKey = generatePrivateKey();
    state.transferHandles = {};
    saveState(state); // distribute always starts a fresh Alice/Bob pair
  }
  if (needsHolders && (!state.aliceKey || !state.bobKey)) throw new Error("No Alice/Bob in demo/.state.json: run the `distribute` step first");
  const alice = state.aliceKey ? makeRole("ALICE", state.aliceKey) : undefined;
  const bob = state.bobKey ? makeRole("BOB", state.bobKey) : undefined;
  const roles = [admin, treasury, registrar, regulator, ...(alice && bob ? [alice, bob] : [])];

  try {
    console.log(`  steps: ${[...steps].join(", ")}`);
    console.log(`  contract: ${STOCK}`);
    for (const r of roles) console.log(`  ${r.name.padEnd(10)} ${r.address}`);

    const [onchainRegistrar, onchainTreasury] = await Promise.all([
      publicClient.readContract({ address: STOCK, abi: ABI, functionName: "registrar" }),
      publicClient.readContract({ address: STOCK, abi: ABI, functionName: "treasury" }),
    ]);
    check("on-chain registrar matches REGISTRAR wallet", onchainRegistrar.toLowerCase() === registrar.address.toLowerCase());
    check("on-chain treasury matches TREASURY wallet", onchainTreasury.toLowerCase() === treasury.address.toLowerCase());
    printState(await readState());

    // ── mint ────────────────────────────────────────────────────────────────
    if (steps.has("mint")) {
      section("1. ADMIN mints to the treasury (plaintext: primary issuance matches custodian shares)");
      const before = await readState();
      await send(
        admin,
        `mint(${shares(MINT_RAW)} shares)`,
        admin.walletClient.writeContract({ address: STOCK, abi: ABI, functionName: "mint", args: [MINT_RAW] }),
      );
      const after = await readState();
      printState(after);
      check("rawTotalSupply grew by the minted amount", after.rawSupply === before.rawSupply + MINT_RAW);
    }

    // ── distribute ──────────────────────────────────────────────────────────
    if (steps.has("distribute") && alice && bob) {
      section("2. TREASURY distributes with confidentialTransfer (amounts encrypted client-side)");
      state.transferHandles = {};
      for (const [who, raw] of [
        [alice, ALICE_RAW],
        [bob, BOB_RAW],
      ] as const) {
        console.log(`  TREASURY → ${who.name}: ${shares(raw)} shares (on-chain this is only an encrypted handle)`);
        const res = await treasury.token.confidentialTransfer(who.address, raw, {
          skipBalanceCheck: true,
          onEncryptComplete: () => console.log("    amount encrypted"),
          onTransferSubmitted: (h) => console.log(`    ${txLink(h)}`),
        });
        const log = res.receipt.logs.find(
          (l) => l.address?.toLowerCase() === STOCK.toLowerCase() && l.topics[0] === TRANSFER_TOPIC,
        );
        if (log?.topics[3]) state.transferHandles[who.name] = log.topics[3];
        saveState(state);
      }
    }

    // ── holders ─────────────────────────────────────────────────────────────
    if (steps.has("holders") && alice && bob) {
      section("3. ALICE and BOB decrypt their own balance, and cannot read each other's");
      const m = (await readState()).multiplier;
      const aliceBal = await mustDecrypt("alice", () => alice.token.balanceOf(alice.address));
      const bobBal = await mustDecrypt("bob", () => bob.token.balanceOf(bob.address));
      console.log(`  ALICE sees: raw ${shares(aliceBal)}  displayed ${shares(displayed(aliceBal, m))}`);
      console.log(`  BOB   sees: raw ${shares(bobBal)}  displayed ${shares(displayed(bobBal, m))}`);
      check("Alice's raw balance is 600", aliceBal === ALICE_RAW);
      check("Bob's raw balance is 400", bobBal === BOB_RAW);
      check("Alice cannot read Bob's balance", await expectDenied("ALICE reading BOB", () => alice.token.balanceOf(bob.address)));
      check("Bob cannot read Alice's balance", await expectDenied("BOB reading ALICE", () => bob.token.balanceOf(alice.address)));
    }

    // ── registrar ───────────────────────────────────────────────────────────
    if (steps.has("registrar") && alice && bob) {
      section("4. REGISTRAR (internal auditor) sees every balance and transfer amount");
      const m = (await readState()).multiplier;
      const regAlice = await mustDecrypt("registrar/alice", () => registrar.token.balanceOf(alice.address));
      const regBob = await mustDecrypt("registrar/bob", () => registrar.token.balanceOf(bob.address));
      const regTreasury = await mustDecrypt("registrar/treasury", () => registrar.token.balanceOf(treasury.address));
      console.log(`  ALICE raw ${shares(regAlice)} (displayed ${shares(displayed(regAlice, m))})   BOB raw ${shares(regBob)} (displayed ${shares(displayed(regBob, m))})`);
      console.log(`  TREASURY raw ${shares(regTreasury)}`);
      check("registrar reads Alice's balance", regAlice === ALICE_RAW);
      check("registrar reads Bob's balance", regBob === BOB_RAW);
      check("treasury balance is positive", regTreasury > 0n);
      const aliceHandle = state.transferHandles?.["ALICE"];
      if (aliceHandle) {
        const amount = await mustDecrypt("registrar/transfer", async () => {
          const out = await registrar.sdk.decryption.decryptValues([{ encryptedValue: aliceHandle, contractAddress: STOCK }]);
          const v = out[aliceHandle];
          if (typeof v !== "bigint") throw new Error("no value");
          return v;
        });
        console.log(`  transfer amount (treasury → Alice) decrypted by registrar: ${shares(amount)}`);
        check("registrar reads the transfer amount", amount === ALICE_RAW);
      }
      console.log("  (the registrar only decrypts: it holds no mint, transfer or admin power)");
    }

    // ── split ───────────────────────────────────────────────────────────────
    if (steps.has("split")) {
      section("5. ADMIN applies a 2-for-1 split: zero FHE ops, encrypted balances untouched");
      const pre = await readState();
      await applyAction(admin, 2n, 1n, "split");
      const post = await readState();
      printState(post);
      check("multiplier doubled", post.multiplier === pre.multiplier * 2n);
      check("publishedSupply doubled", post.published === pre.published * 2n);
      console.log(`  a holder with raw ${shares(ALICE_RAW)} now displays ${shares(displayed(ALICE_RAW, post.multiplier))} (raw × multiplier, computed client-side)`);
    }

    // ── dividend ────────────────────────────────────────────────────────────
    if (steps.has("dividend")) {
      section("6. ADMIN applies a reinvested dividend 1005/1000 ($0.50 on $100)");
      const pre = await readState();
      await applyAction(admin, 1005n, 1000n, "dividend");
      const post = await readState();
      printState(post);
      check("multiplier scaled by 1.005", post.multiplier === (pre.multiplier * 1005n) / 1000n);
      console.log(`  raw ${shares(ALICE_RAW)} displays ${shares(displayed(ALICE_RAW, post.multiplier))};  raw ${shares(BOB_RAW)} displays ${shares(displayed(BOB_RAW, post.multiplier))}  (rounded down)`);
    }

    // ── regulator ───────────────────────────────────────────────────────────
    if (steps.has("regulator") && alice && bob) {
      section("7. REGULATOR: denied → ADMIN discloses ALICE only → allowed (BOB still denied)");
      check("regulator cannot read Alice before disclosure", await expectDenied("REGULATOR reading ALICE", () => regulator.token.balanceOf(alice.address)));
      await send(
        admin,
        `disclose(ALICE, REGULATOR)`,
        admin.walletClient.writeContract({ address: STOCK, abi: ABI, functionName: "disclose", args: [alice.address, regulator.address] }),
      );
      const seen = await mustDecrypt("regulator/alice", () => regulator.token.balanceOf(alice.address));
      console.log(`  REGULATOR now sees ALICE: raw ${shares(seen)}`);
      check("regulator reads Alice after disclosure", seen === ALICE_RAW);
      check("regulator still cannot read Bob", await expectDenied("REGULATOR reading BOB", () => regulator.token.balanceOf(bob.address)));
    }
  } finally {
    section(failures === 0 ? "DONE: all checks passed" : `DONE: ${failures} check(s) FAILED`);
    for (const r of roles) r.sdk.terminate();
    if (failures > 0) process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exitCode = 1;
});
