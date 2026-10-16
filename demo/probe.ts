// Isolated probes for the stuck decrypt steps. Each command does ONE thing, prints timings, and never sends a tx.
// Run from demo/:   npm run probe -- <command> [args]
//
//   acl [handle]            on-chain ACL check (no relayer): who is allowed on a handle. Defaults to the treasury's
//                           current balance handle.
//   treasury                TREASURY decrypts its own current balance
//   mint-handle [txHash]    TREASURY decrypts the amount handle emitted by a tx (default: the original mint tx)
//   registrar <address>     REGISTRAR decrypts <address>'s current balance
//   handle <0x..> <role>    <role> (treasury|registrar|regulator|admin) decrypts an arbitrary handle
//
// Reading the result:
//   "not entitled to decrypt ... ACL grant"      -> ACL problem (fast, ~2s)
//   "readiness_check_timed_out / not ready"      -> ACL is fine, the ciphertext isn't ready on the gateway yet
//   DECRYPTED = <n>                              -> works

import { createPublicClient, createWalletClient, http, parseAbi, toEventSelector, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia as viemSepolia } from "viem/chains";
import { MemoryStorage, ZamaSDK } from "@zama-fhe/sdk";
import type { Address } from "@zama-fhe/sdk";
import { sepolia, type FheChain } from "@zama-fhe/sdk/chains";
import { createConfig } from "@zama-fhe/sdk/viem";
import { node } from "@zama-fhe/sdk/node";

const t0 = Date.now();
const log = (m: string) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s] ${m}`);
const env = (n: string) => {
  const v = process.env[n];
  if (!v) throw new Error(`Missing env: ${n}`);
  return v;
};

const RPC = env("RPC_URL");
const STOCK = env("STOCK_ADDRESS") as Address;
const ACL = "0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D" as Address; // Sepolia ACL (from ZamaConfig)
const MINT_TX = "0xb8b353bdee3931a21dcfe5f142dca66d5513d4f2787226ab23dbe7f6722ff391" as Hex;
const TRANSFER_TOPIC = toEventSelector("ConfidentialTransfer(address,address,bytes32)");
const stockAbi = parseAbi(["function confidentialBalanceOf(address) view returns (bytes32)"]);
const aclAbi = parseAbi(["function isAllowed(bytes32,address) view returns (bool)", "function persistAllowed(bytes32,address) view returns (bool)"]);

const KEYS: Record<string, string> = {
  admin: "DEPLOYER_PRIVATE_KEY",
  treasury: "TREASURY_PRIVATE_KEY",
  registrar: "REGISTRAR_PRIVATE_KEY",
  regulator: "REGULATOR_PRIVATE_KEY",
};
const zs = { ...sepolia, network: RPC } as const satisfies FheChain;
const pc = createPublicClient({ chain: viemSepolia, transport: http(RPC) });
const addrOf = (role: string) => privateKeyToAccount(env(KEYS[role]!) as Hex).address as Address;

async function decryptAs(role: string, handle: Hex) {
  const account = privateKeyToAccount(env(KEYS[role]!) as Hex);
  const wc = createWalletClient({ account, chain: viemSepolia, transport: http(RPC) });
  const sdk = new ZamaSDK(
    createConfig({ chains: [zs], publicClient: pc, walletClient: wc, storage: new MemoryStorage(), relayers: { [zs.id]: node() } }),
  );
  log(`${role} (${account.address}) decrypting ${handle} ...`);
  try {
    const out = await sdk.decryption.decryptValues([{ encryptedValue: handle, contractAddress: STOCK }]);
    log(`DECRYPTED = ${out[handle]}`);
  } catch (e) {
    const msg = e instanceof Error ? e.message.split("\n").slice(0, 2).join(" | ") : String(e);
    log(`ERROR: ${msg.slice(0, 260)}`);
  } finally {
    sdk.terminate();
  }
}

const balanceHandle = (a: Address) =>
  pc.readContract({ address: STOCK, abi: stockAbi, functionName: "confidentialBalanceOf", args: [a] }) as Promise<Hex>;

async function main() {
  const [cmd, a1, a2] = process.argv.slice(2);
  switch (cmd) {
    case "acl": {
      const handle = (a1 as Hex) ?? (await balanceHandle(addrOf("treasury")));
      log(`handle ${handle}`);
      const who: [string, Address][] = [
        ["stock contract", STOCK],
        ["treasury", addrOf("treasury")],
        ["registrar", addrOf("registrar")],
        ["regulator", addrOf("regulator")],
        ["admin", addrOf("admin")],
      ];
      for (const [name, addr] of who) {
        const [allowed, persist] = await Promise.all([
          pc.readContract({ address: ACL, abi: aclAbi, functionName: "isAllowed", args: [handle, addr] }),
          pc.readContract({ address: ACL, abi: aclAbi, functionName: "persistAllowed", args: [handle, addr] }),
        ]);
        log(`${name.padEnd(15)} isAllowed=${allowed}  persistAllowed=${persist}`);
      }
      return;
    }
    case "treasury":
      return decryptAs("treasury", await balanceHandle(addrOf("treasury")));
    case "mint-handle": {
      const receipt = await pc.getTransactionReceipt({ hash: (a1 as Hex) ?? MINT_TX });
      const l = receipt.logs.find((x) => x.address.toLowerCase() === STOCK.toLowerCase() && x.topics[0] === TRANSFER_TOPIC);
      if (!l?.topics[3]) throw new Error("no ConfidentialTransfer log in that tx");
      return decryptAs("treasury", l.topics[3] as Hex);
    }
    case "registrar": {
      if (!a1) throw new Error("usage: registrar <address>");
      return decryptAs("registrar", await balanceHandle(a1 as Address));
    }
    case "handle": {
      if (!a1 || !a2 || !KEYS[a2]) throw new Error("usage: handle <0x..> <admin|treasury|registrar|regulator>");
      return decryptAs(a2, a1 as Hex);
    }
    default:
      console.log("commands: acl [handle] | treasury | mint-handle [txHash] | registrar <address> | handle <0x..> <role>");
  }
}

main()
  .catch((e) => console.error("Fatal:", e))
  .finally(() => process.exit(0));
