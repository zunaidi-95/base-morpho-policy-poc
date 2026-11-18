# MORPHO-01 — Morpho loan-protection policies lack the post-execution health check

Foundry proof-of-concept for a Medium-severity finding (Tier 1) in the
Coinbase / Base bug bounty program (Cantina).

**The bug:** the live `MorphoLoanProtectionPolicy` and
`MorphoWETHLoanProtectionPolicy` have no `_onPostExecute` health check. When a
user's Morpho position has drifted above its liquidation LTV (LLTV), an
executor-signed top-up executes anyway: the policy's one-shot is consumed, the
position stays liquidatable, and a liquidator seizes the freshly supplied
collateral together with the rest of the position. The fix exists in the repo
(base/account-policies @ `e7e85ca` adds the `PostTopUpLtvAboveLltv` check) but
was never deployed to these live in-scope addresses.

## Setup

Install the dependencies (pinned versions — verified by the 8/8 test pass
below), then run the tests:

```sh
forge install foundry-rs/forge-std@v1.17.0
forge install morpho-org/morpho-blue@v1.0.0
forge install OpenZeppelin/openzeppelin-contracts@v5.7.0
forge install vectorized/solady@v0.1.26
forge install coinbase/smart-wallet@v1.1.0
forge install eth-infinitism/account-abstraction@v0.6.0
forge install base/webauthn-sol@v1.0.0
forge test
```

Expected: **8 passed, 0 failed** (stable across repeat runs).

Note: the `webauthn-sol` install pulls a large test fixture through its
`FreshCryptoLib` submodule (a committed `node_modules` tree), so the full
install needs roughly 1 GB of free disk.

The tests fork Base mainnet at pinned block **59043631** via the `base`
endpoint in `foundry.toml` (`https://mainnet.base.org`). To use a different
Base RPC, set `BASE_RPC_URL` (e.g.
`BASE_RPC_URL=https://mainnet.base.org forge test`). Local fork only — nothing
is sent to mainnet. Forge 1.9.0, solc 0.8.23, EVM Cancun. Dependencies are
installed with `forge install` (see Setup above) — nothing is vendored under
`lib/` in this repo. Version notes: forge-std v1.17.0, morpho-blue v1.0.0,
smart-wallet v1.1.0, account-abstraction v0.6.0 and webauthn-sol v1.0.0 were
pinned by matching the original vendored files against upstream tags;
solady v0.1.26 matches except formatting-only differences; OpenZeppelin
matched no v5 tag, so the latest stable v5.7.0 is used and the full suite
passing is the verification for it.

## Tests

`test/MorphoPostCheck.t.sol` — live bug reproduction (uses the LIVE deployed
contracts on-fork):

- `test_liveLoanProt_topUpIntoLiquidatablePosition` — live
  `MorphoLoanProtectionPolicy`: 100 WETH supplied, USDC borrowed to ~85% LTV;
  warp 4380 days → LTV 99.91% (≥ LLTV 86%); executor-signed 1-WETH top-up via
  `PolicyManager.execute` **succeeds**; post-top-up LTV **98.92%** (still ≥
  LLTV); liquidator seizes **all 101 WETH**, including the top-up.
- `test_counterfactual_noTopUp_spareWethSurvives` — same setup, no top-up:
  after liquidation the spare 1 WETH stays in the wallet.
- `test_liveWethLoanProt_topUpIntoLiquidatablePosition` — same flow via the
  ETH-wrapping variant (`MorphoWETHLoanProtectionPolicy`).

`test/FixedPolicyControl.t.sol` — negative control (repo-HEAD fixed policies,
deployed fresh by the test; everything else is live on-fork):

- `test_fixedLoanProt_revertsWhenTopUpCannotRestoreHealth` — fixed
  `MorphoLoanProtectionPolicy` reverts with
  `PostTopUpLtvAboveLltv(989208818362054883, 860000000000000000)`; one-shot
  preserved; no WETH supplied.
- `test_fixedWethLoanProt_revertsWhenTopUpCannotRestoreHealth` — same for the
  fixed WETH variant; spare ETH stays in the account.
- Plus the 3 live tests inherited under the fixed test contract (proving the
  fixed project reproduces the live bug identically).

## Affected contracts (Base mainnet, Tier 1 scope)

| Contract | Address |
|---|---|
| `MorphoLoanProtectionPolicy` | `0x001B6f938eA6D0A57D02B3e9503b958149A2a7e3` |
| `MorphoWETHLoanProtectionPolicy` | `0xe14A101ADF9AE492Dd8e9D2ED7763460A6AE8Cd7` |
| `PolicyManager` | `0x75b3015780776952102a8bFA6202d2e3c1F4EFc5` |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| WETH/USDC market (LLTV 86%) | `0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda` |

Market at fork block: supply ~$94M, borrow ~$82M, liquidity ~$12.6M.

## Live-configuration evidence

Both live policies are the **pre-fix** versions (Sourcify exact match,
verified 2026-04-07): no `_onPostExecute`, no `MAX_TRIGGER_LTV_RATIO`,
3-argument constructor; calling `MAX_TRIGGER_LTV_RATIO()` on the live
contracts reverts (getter absent). `src/` holds the live contract sources as
verified on Sourcify; `src/policies-fixed/` holds the repo-HEAD (fixed)
policy sources. No privileged accounts are used anywhere: all keys are fresh
test keys, the executor intent is genuinely EIP-712 signed with `vm.sign`,
and there is no `vm.prank` as any owner/admin. The only unreal element is
`vm.warp` (4380 days stands in for a price move — the oracle price is pinned
on a fork, so interest is the only lever that moves LTV; a ~15% WETH price
drop would jump LTV the same way instantly in production).

## Prior-art note

The same issue was reported in the April 2026 Cantina audit of
base/account-policies (Medium 3.1.1, recorded as "Fixed in commit 6b0f3f8,
fix verified"). The fix exists in the repository but was never deployed to
the live in-scope addresses above, so the vulnerability is live on the
deployed contracts today.
