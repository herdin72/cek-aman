# Cek Aman — Agent Claim Check

**Community safety reports for free-claim contracts on BSC, written only by Agent ID holders.**

## Live

- **Contract (BSC mainnet):** [`0xcC417b42e8a7db7615bfb6bebE32143759a19c6D`](https://bscscan.com/address/0xcC417b42e8a7db7615bfb6bebE32143759a19c6D#code) — source verified on BscScan and Sourcify (exact match). Deployed 25 Nov 2026.
- **Web page:** https://herdin72.github.io/cek-aman/

*Cek Aman* is Indonesian for "check it's safe". Free claims and mints are everywhere in the Agent ID ecosystem, and so are traps: "free" claims that quietly charge a fee, prompts that encode someone else's name so you pay gas for nothing, contracts that ask for approvals, fake branded "inscriptions". Hunters usually find out the hard way, one by one.

Cek Aman turns those individual experiences into a shared, Sybil-resistant signal: before you claim, check what other Agent ID holders reported.

## How it works

| | |
|---|---|
| **One Agent ID = one voice** | `report()` reverts unless `balanceOf(msg.sender) > 0` on the official SPACE ID Agent ID registry (`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`). Agent IDs are soulbound, one per address and cannot be burned, so each holder is exactly one reporter. Each holder has at most one active report per target; reporting again updates it. |
| **Proof of claim** | When you report, Cek Aman makes a gas-capped, read-only `balanceOf(you)` call on the target. If you actually hold the token/NFT you claimed, your report is marked **proof-backed** and counted separately (`proofSafe`, `proofScam`). |
| **Verdict + reason** | `SAFE` (reasons: gas-only worked, received the asset, verified source with no risky owner powers) or `SCAM` (hidden fee, asked for approval, reverted and gas lost, fake branding, nothing received). |
| **Guardian badge** | Your first report mints a free, soulbound **Guardian** badge (ERC-721 + ERC-5192, fully on-chain SVG showing your `name.ai` and your number of active reports). Not transferable, no monetary value. |
| **Contracts only** | Targets must be contracts. Wallets (EOAs) cannot be reported, so Cek Aman can never be used to label or look up people. |

### Contract interface

```solidity
// write (Agent ID holders only, gas only, value 0)
function report(address target, uint8 verdict, uint8 reason) external; // verdict 1 = SAFE, 2 = SCAM
function withdraw(address target) external;                            // remove your own report

// read
function getTally(address target) external view returns (
    uint32 safe, uint32 scam, uint32 proofSafe, uint32 proofScam,
    uint8 status,            // 0 none, 1 SAFE majority, 2 SCAM majority, 3 MIXED (tie)
    uint40 firstReportAt, uint40 lastReportAt);
function statusOf(address target) external view returns (uint8);
function reportOf(address target, address reporter) external view returns (uint8 verdict, uint8 reason, bool proof, uint40 updatedAt);
function getRecent(uint256 count) external view returns (address[] memory); // newest first
function getPage(uint256 offset, uint256 limit) external view returns (address[] memory);
function reasonLabel(uint8 reason) external pure returns (string memory);
function isAgent(address account) external view returns (bool);
```

Other contracts and agents can gate on it, for example `require(cekAman.statusOf(target) != 2)` before interacting with an unknown contract.

## Safety properties

- **No owner, no admin, no upgrades, no pause.** Nothing can be changed after deployment.
- **No payable functions; holds no funds; never transfers tokens; never asks for approvals.**
- **Only read-only external calls:** the Agent ID registry (`balanceOf`, `handleOf`) and a `balanceOf` staticcall on the target capped at 30,000 gas that copies at most 32 bytes back, so a hostile target cannot change state, re-enter, burn your gas or return-bomb the call (covered by tests).
- **Users sign everything themselves** from their own wallet, with their own confirmation. The web page is read-only: no wallet connect, no login, no QR/pairing codes, never asks for keys or seed phrases.
- Reports are community opinions, not financial advice.

## Repository layout

```
src/CekAman.sol            contract (Solidity 0.8.24, MIT)
test/CekAman.t.sol         unit + fuzz tests (mock registry, hostile targets)
test/CekAman.fork.t.sol    fork tests against the real Agent ID registry on BSC
index.html                 static read-only front end (public BSC RPC), served by GitHub Pages
script/make-deploy-calldata.sh   builds CREATE2 deploy calldata + gas estimate (sends nothing)
deploy/standard-json-input.json  for block-explorer source verification
```

## Build & test

```bash
forge install foundry-rs/forge-std --no-git   # dependency (not committed)
forge build
forge test                       # unit + fuzz + fork tests (fork tests need internet)
forge test --match-contract CekAmanForkTest -vv
```

Results (25 Nov 2026): **29/29 tests pass** — 22 unit/fuzz tests (512 fuzz runs) and 7 fork tests on BSC mainnet state with a real Agent ID holder (`aibou.ai`), a non-holder, a real free-claim NFT (proof-of-claim) and a target without `balanceOf`.

Gas on BSC fork: first report including badge mint ≈ 248k gas; later reports ≈ 124k gas (at 0.05 gwei ≈ 0.000012 BNB and 0.000006 BNB).

Static analysis: Slither, 6 informational results, all reviewed and intentional (ceiling division in Base64, strict `== 0` checks, inline assembly in the gas-capped proof call).

## License

MIT — see [LICENSE](LICENSE).
