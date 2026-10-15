# Handoff: Stage 5 (Sepolia demo), where we are and what is stuck

Written 2026-10-14 to restart the chat. Read `docs/implementation-notes.md` first for the contract design, then this file.

## TL;DR
- Contract is **deployed and verified on Sepolia**. Mint, two confidential transfers, a 2-for-1 split and a 1005/1000 dividend all succeeded on-chain.
- **Every user decryption of our contract's handles is stuck**: the relayer answers `readiness_check_timed_out: Ciphertext not ready for decryption on the gateway chain` (HTTP 503), 40+ minutes after the transactions.
- The user's own FHECounter dapp decrypts fine on the same Sepolia and the same toolchain, so the network is healthy. Cause is unknown.

## Deployment
| Item | Value |
|---|---|
| Contract | `0xb01b7261d9458a576a736a67a9c51d988ea91995` (verified on Blockscout) |
| Explorer | https://eth-sepolia.blockscout.com/address/0xb01b7261d9458a576a736a67a9c51d988ea91995 |
| Admin / agent (deployer) | `0x7d87bBBBc4F15B8B7ff5EA1a400412D778132eDc` |
| Treasury | `0x3250C1Ab6Ede5e987B357b0D7B122b39C933E7Ef` |
| Registrar | `0x235E0B79e5cf92C394617C8272ca15651CD4ef3A` |
| Regulator (demo only) | `0xCDDb4F23cdfddD1846745DA001066271D535Bf4E` |
| First-run Alice (key lost) | `0x48bE218F29be85274F6B1B267351e56966c41f5F` (raw 600e6) |
| First-run Bob (key lost) | `0xA1F5d457af95F4825658fE9Fb41AD601c3b2bB51` (raw 400e6) |

Keys are in `.env` (gitignored, testnet only): `DEPLOYER_PRIVATE_KEY`, `TREASURY_PRIVATE_KEY`, `REGISTRAR_PRIVATE_KEY`, `REGULATOR_PRIVATE_KEY`, plus `RPC_URL`, `STOCK_ADDRESS`, `REGISTRAR_ADDRESS`, `TREASURY_ADDRESS`.

### On-chain history
- Deploy needed an explicit gas limit: forge estimated ~3.3M gas, the creation actually used 22.5M. Two attempts ran out of gas first (no contract left behind). Working command:
  `forge script script/DeployConfidentialStock.s.sol --rpc-url $RPC_URL --broadcast --gas-estimate-multiplier 800`
  (`--gas-limit` is ignored for the tx; the multiplier is what works.)
- Mint of 1,000,000 shares (raw `1000000000000` = 1e12): `0xb8b353bdee3931a21dcfe5f142dca66d5513d4f2787226ab23dbe7f6722ff391`
- Treasury to Alice 600 shares: `0x903f43fabe9ed48369e364a5199bfe691e3d63754f4321eac124d9297af82c15`
- Treasury to Bob 400 shares: `0x4b769b082a61594f3258255a206bab7371b0f1924138da101e8ae5d7432caf9b`
- Split 2-for-1: `0x44a484e24e6ce2e8c2b90022ee348b7a3bfc0a0804607ea3cf9ef0e3521b5c12`
- Dividend 1005/1000: `0x76dfd0adbfebc44626b0bb15d3eff4cc16553a953c15a1220c222fb23bfeaf3d`
- Current public state: multiplier `2.01e18`, `rawTotalSupply` 1e12, `publishedSupply` 2,010,000 shares.
  For a clean 1.0 starting point for a real demo, redeploy.

## What is stuck
Any user decrypt of a handle created by our contract: treasury, Alice, Bob balances, the mint tx's own output handle, and a transfer amount. Tried as treasury and as registrar, via `token.balanceOf` and `sdk.decryption.decryptValues`. The SDK itself retries about 94 seconds, then throws.

### What has been ruled out
- **Toolchain / library version.** The user's working counter (`/Users/jesseclark/git/zama/deploy-counter/fhevm-foundry-template`, contract `0xe3328e8e86D1A58128FD5EC966B7563756123C94`) uses an identical `foundry.toml`: `@fhevm/solidity` 0.11.1, same `forge-fhevm` pin. Its deploy also took 7.4M gas.
- **Contract wiring.** The transfer tx emitted FHE executor events from `0x92C9…c127` (coprocessor) and ACL events from `0xf0Ff…A433D`, exactly the Sepolia addresses in `ZamaConfig`. Protocol id reads 10001.
- **Relayer reachability / Node transport.** `relayer.testnet.zama.org` answers; probing the user's counter handle with our script's Node SDK path returned a clear "not entitled to decrypt" in ~2.5s.
- **ACL grants.** On-chain ACL check of the treasury's current balance handle (`npm run probe -- acl`): stock contract, treasury and registrar are allowed; regulator and admin are not. This is the intended access model, verified on Sepolia independent of the relayer. The SDK also checks entitlement before polling, so a missing grant would fail fast, not time out.
- **Bisect.** The handle emitted directly by the mint tx (trivial encrypts, add, select, no user input) is also "not ready", so the problem starts at the first tx with encrypted values and affects every ciphertext from our contract.

### Open hypotheses (unconfirmed)
1. The Sepolia coprocessor has not processed (or failed to process) our contract's computations. Cannot see inside it from here.
2. Something in our contract's op graph differs from the counter's (the counter's ops are a subset of ours). The mint graph is standard OZ `tryIncrease`: trivial encrypts, add, select.
3. Backlog or per-contract throttling on the testnet. Least likely given 40+ minutes.

## Next steps (in order)
1. **Ask the Zama team** (the user is onsite): did the coprocessor process contract `0xb01b…1995` / mint tx `0xb8b353bd…ff391`? Cheapest and most informative.
2. **Control experiment** (needs the user's OK, ~0.003 ETH): deploy the template's original `FHECounter` (git history: `git show 8fc3237:src/FHECounter.sol`, `script/DeployFHECounter.s.sol`) from the admin key with `--gas-estimate-multiplier 800`, increment it via the SDK, and decrypt it with the Node SDK.
   - Decrypts: our contract's op graph is the suspect. Bisect with smaller variants: plain ERC7984 with a trivial-encrypt mint, then Rwa, then ConfidentialStock.
   - Hangs: the issue is in how we deploy or call (gas multiplier, Node transport), not the contract.
3. Retry the probes below after some time (cheap).
4. Once decrypts work: run `npm start` (all steps) or the decrypt steps individually (`distribute`, `holders`, `registrar`, `regulator`), and confirm the ✓/✗ checks. Note the old Alice/Bob keys are lost, so `distribute` creates a fresh pair and saves it to `demo/.state.json`.
5. Remaining stages: commit `script/` + `demo/`; presentation material (known-limits slide: resolution after splits, ACL irrevocable, `disclose` breadth, transfer-and-call P2).

## How to run things
From `demo/` (reads `../.env`):

```bash
npm start -- split dividend     # public steps only (already run once; multiplier is now 2.01)
npm start -- distribute         # new Alice/Bob + 2 transfers (needs no decrypt)
npm start -- holders registrar regulator   # decrypt steps (stuck until the issue is fixed)
npm start                       # everything, in order

npm run probe -- acl                         # on-chain ACL check, no relayer
npm run probe -- treasury                    # treasury decrypts its own balance
npm run probe -- mint-handle                 # decrypt the mint tx's output handle
npm run probe -- registrar 0x48bE218F29be85274F6B1B267351e56966c41f5F   # registrar reads first-run Alice
npm run probe -- handle 0x<handle> <role>    # any handle as admin|treasury|registrar|regulator
```

Reading probe output:
- `not entitled to decrypt ... ACL grant`: an ACL problem (fast, ~2s).
- `readiness_check_timed_out / not ready`: ACL is fine, ciphertext isn't ready on the gateway.
- `DECRYPTED = <n>`: works.

Contract tests: `forge test` (26 tests, mock FHEVM, all passing).

## SDK notes
- `@zama-fhe/sdk` 3.6.0 (reports `@fhevm/sdk` 0.13.2). Source clone for reference (scratchpad, may be gone): `github.com/zama-ai/sdk`; `examples/node-viem` is the closest pattern.
- Sepolia needs no `relayerUrl`: the chain preset carries it. Node uses `node()` from `@zama-fhe/sdk/node`; the user's React app uses `web()`.
- `createToken(addr)` works on any ERC7984. `sdk.decryption.decryptValues([{ encryptedValue, contractAddress }])` decrypts any handle the signer is allowed on.
- The transfer amount handle comes from `topics[3]` of the `ConfidentialTransfer` log in the receipt.

## Repo state
- Branch `feat/confidential-stock`, HEAD `e721249`. Solidity is committed and has had one code review round (Codex P1 fixed, P2 deferred).
- **Uncommitted**: `.gitignore` (adds `node_modules/`, `broadcast/`, `demo/.state.json`), `script/DeployConfidentialStock.s.sol`, `demo/` (`demo.ts`, `probe.ts`, `package.json`, `tsconfig.json`, lockfile). `.env.example` was edited but is gitignored.
- Nothing pushed. Commits need `gpg --card-status` first if signing fails (YubiKey).
