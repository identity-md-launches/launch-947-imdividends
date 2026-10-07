# IMDIVIDENDS (DIVIDENDS)

A fixed-supply ERC-20 with an initial 7% tax on ordinary wallet transfers and a pool-token dividend vault. The constructor mints **1,000,000,000 DIVIDENDS, with 18 decimals**, entirely to its caller. There is no later mint, burn, upgrade, blacklist, seizure or transfer-pause function.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Solidity is pinned to **0.8.26**, targeting Cancun, with optimization and `bytecode_hash = "none"`. Dependencies are ordinary vendored source files in `lib/`; no install, submodule, RPC, fork, environment variable, FFI or filesystem cheatcode is required. The verifier must provide the pinned compiler. Dependency versions and licenses are recorded in [DEPENDENCIES.md](DEPENDENCIES.md).

The delivered tests cover ERC-20 behavior, exact launch allocations, ownership, fee conversion, timed dividends, changing balances, rounding, failed/malicious reward-token calls, funding limits, and stateful supply/reward conservation. Integration tests use a real Uniswap v4 PoolManager for single-sided seeding and swaps in both directions, including both ERC-20 currency orderings and native ETH pairing. Revision regressions cover settle/take and ERC-6909 tax relays, late distributor registration, disabled funding and guarded renunciation. Test helpers are not production contracts.

## Deployment parameters

Deploy `src/IMDIVIDENDS.sol:IMDIVIDENDS` with these **static constructor arguments in order**:

| Argument | Type | Meaning |
| --- | --- | --- |
| `factory_` | `address` | Launch factory; use `$factory` in a launch manifest. |
| `poolManager_` | `address` | PoolManager receiving untaxed settlement deposits; use `$poolManager`. Outflows to ordinary holders are taxed. Must be nonzero and distinct from the factory. |
| `launchNumber_` | `uint64` | Registry key; use `$launchNumber`. |
| `initialOwner` | `address` | Requester's administrative address, normally `$requester`. Must be nonzero. |
| `rewardToken` | `address` | Existing ERC-20 pool/paired token paying dividends. Must contain code. |

The factory must be the constructor caller for a network launch. The whole supply goes to **`msg.sender`, independently of `initialOwner`**. The token constructor also creates its immutable `DividendVault`; obtain its address through `dividendVault()`. Do not deploy another vault or schedule initialization calls. The internal vault constructor does not move any DIVIDENDS.

Manifest token fields are `name: IMDIVIDENDS`, `symbol: DIVIDENDS`, `decimals: 18`, `totalSupply: "1000000000000000000000000000"`, and contract `src/IMDIVIDENDS.sol:IMDIVIDENDS`. No separately deployed application contract is needed. This assignment supplies no chain addresses, pool economics or requested opening price, so it does not invent a launch manifest. The launch coordinator must supply those values and attest the actual token creation code and constructor arguments.

For a standalone deployment, set `factory_` to the constructor caller. An EOA or contract without `distributorOf(uint64)` is supported and has no distributor exemption. The initial owner may be a different address.

**Pool-token assumption:** dividends use one immutable ERC-20 selected at deployment, normally the pool's paired currency. A fungible LP token could be selected instead if it satisfies the same transfer requirements; v4 liquidity positions themselves are not ERC-20 dividend assets. For a native ETH pair, configure its deployed wrapped ERC-20 as the reward token and fund with wrapped tokens. The deployment/admission environment must supply code at that address; a codeless wrapped-token placeholder is intentionally rejected. Native ETH is not accepted by this vault. No chain-specific token address is assumed or verified here.

## Fees and launch compatibility

An ordinary transfer of 100 DIVIDENDS debits 100, sends 93 to the recipient and retains 7 at the **token contract**. Allowances decrease by the gross amount. Fees round down in base units. Zero-value and self transfers have no tax. The owner can set the tax from 0 to **1,000 basis points (10%)**, inclusive; the initial rate is 700 basis points. Changes apply immediately, without a delay: a pending transfer executes at the rate in effect when it is mined.

The factory, launch distributor, token contract and vault are exempt as transfer endpoints. Factory and distributor operators are also exempt, but still need allowances to use `transferFrom`. Transfers **to** the PoolManager are exempt so settlement deposits arrive whole. Transfers **from** the PoolManager to ordinary holders are taxed, and acting as the transfer operator does not give the PoolManager an exemption. This prevents a wallet from bypassing the tax by depositing into the permissionless manager and taking the same amount out, including through ERC-6909 claims.

These exemptions preserve the exact swarm allocation, contributor claims, pool seed and sell settlement required by the launch checks. **PoolManager buys are taxed; sells remain untaxed.** A buy delivering 100 gross DIVIDENDS pays 93 to the buyer at the initial rate. The manager debits the full 100 and settles normally. Other withdrawals to ordinary holders are taxed too. Integrators must measure the recipient's actual balance change for minimum-output checks and sell amounts; routing through an intermediate wallet can incur another ordinary-transfer tax. Revenue comes from ordinary transfers and taxed PoolManager outflows. The exemptions are immutable except for discovery of the factory's registered distributor; the owner cannot add privileged wallet exemptions.

The token resolves the distributor through the factory's `distributorOf(uint64)` registry using a bounded static call. Register it before sending its allocation and keep the registry stable. An unavailable registry resolves to zero; a network factory must reliably provide the standard getter within 30,000 gas. If registration is late, anyone can call `token.syncShares(distributor)` immediately after registration and **before starting reward streams**, without moving tokens or setting an arbitrary share amount. Every token transfer also clears any shares held by the currently resolved distributor. Synchronization checkpoints old shares before replacing them: rewards accrued before synchronization remain earned and cannot be reclaimed. The deployment coordinator remains responsible for registering and synchronizing before dividends begin.

The same infrastructure addresses, including the PoolManager, are excluded from dividend shares. Every other holder participates automatically, without staking or registration. This includes the owner/requester's remainder wallet: it may receive most or all of the first streams while the pool and distributor hold the excluded supply. There is no special preference for public buyers. Holding DIVIDENDS on an exchange or another contract accrues dividends to that contract, not its customers.

## Turning taxes into pool-token dividends

No router, price oracle or conversion rate was supplied. Conversion is therefore an explicit **owner-funded atomic exchange**, rather than an assumed automatic DEX swap:

1. Observe collected DIVIDENDS with `token.balanceOf(address(token))`.
2. The owner obtains the configured reward token and approves the **vault** for an exact `rewardAmount` in that token's base units.
3. The owner calls `token.convertFees(tokenAmount, rewardAmount, recipient)`.
4. The vault pulls reward tokens from that owner and queues them; the token sends the specified collected DIVIDENDS, without another tax, to `recipient`. Both steps succeed or the entire transaction reverts.

The owner is responsible for a fair exchange price and sufficient reward funding. There is no enforced minimum economic rate beyond nonzero reward funding; the owner can acquire the entire fee inventory for one reward-token base unit. This power affects the collected taxes, not holder balances or already funded reward assets. The owner may sell the purchased DIVIDENDS separately. Anyone may also approve the vault and call `vault.fund(amount)` to donate reward tokens to the next period. Both donations and fee conversion revert with `DistributionsDisabled` while new distributions are disabled, preserving the payer's tokens, allowance and fee inventory.

Amounts are always raw units of the configured reward token; the code does not assume its decimals. Funding and payouts verify exact balance deltas. Standard non-rebasing ERC-20 tokens, including tokens without boolean return values, are supported. Transfer-tax, rebasing and arbitrary callback behavior are not supported reward-token economics. A malicious or subsequently blocked/paused reward token can prevent payouts, so selection of this immutable asset is a deployment trust decision.

Use `fund` to send rewards. Direct reward transfers are unaccounted donations and cannot be recovered or distributed. Direct DIVIDENDS transfers to the token contract join its convertible fee inventory; DIVIDENDS sent to the vault are excluded and cannot be recovered. There is no owner sweep of assets.

## Ten-minute operation

Funding enters a queue. Anyone calls `vault.distribute()` to start a funded period when no previous stream is active and at least one eligible holder exists. Initially each period lasts **600 seconds**. Its reward budget accrues linearly over that period, proportionally to eligible balances at each balance-changing timestamp. The contract checkpoints rewards using the old shares before replacing them, so transferring away a balance preserves its previously earned rewards and receiving tokens does not buy earlier rewards. A same-timestamp flash balance earns nothing.

Recipients can receive payouts no more often than once per **600 seconds**, and the first payout is no earlier than 600 seconds after deployment. `earned(account)` includes pending stream accrual but does not imply the cooldown has passed; check `nextClaimAt(account)`. Dividends never expire. Holders who sell their entire balance can still collect what they earned.

A chain does not execute transactions on a timer. An operator must maintain a funded keeper and monitor the contracts:

1. Fund/convert enough rewards for upcoming periods.
2. Call `distribute()` at the end of each funded period to start the next one. Donations during an active stream queue for the next period and do not reset its clock. Gaps in keeper activity delay the next period; rewards do not retroactively accrue through those gaps.
3. Index DIVIDENDS `Transfer` events to track holders and former holders with unpaid earnings. Around every ten minutes, submit batches of at most **50** addresses to `process(accounts)`. It pays each eligible holder at their own address, skips early/empty/duplicate entries, and cannot redirect a claim to the caller.
4. Handle a batch failure by identifying a recipient rejected by the reward token and retrying other recipients separately. The failed batch is atomic and loses no claims. Individual `claim()` and permissionless `claimFor(account)` remain available independently of the keeper.

The owner can call `configureVault(duration, enabled)` to set **future** periods between 600 seconds and one day, or disable funding and starting new periods. This does not alter an active stream, freeze transfers, block earned claims or change the 600-second payout cooldown. Previously queued rewards remain queued and require the owner to re-enable distributions. To meet the requested cadence, leave the duration at 600 seconds. If no eligible balances exist during part of a stream, that portion returns to the queue and may be scheduled later.

Payouts use a cumulative fixed-point index, without iterating over holders during transfers or distribution. Per-account fractional rewards carry forward across checkpoints. Index division rounds down, so tiny residual dust may remain in the vault; it is never swept or promised twice. Lifetime accepted funding is bounded by `2^128 - 1` reward-token base units to keep the cumulative index bounded. This is a lifetime cap, not a per-period cap.

## Administration and release responsibilities

Only the token owner may change the fee, configure future vault operation or exchange fee inventory. Ownership transfer requires the new owner to accept through `Ownable2Step`. `renounceOwnership()` reverts with `UnsafeRenunciation` unless the fee is zero, collected DIVIDENDS inventory is empty and distributions are enabled. To renounce, enable distributions, set the fee to zero and convert all existing inventory first. Queued rewards need not be empty because anyone can still schedule them. Renunciation permanently disables administration and fee conversion, clears any pending owner, and leaves public donations, distribution and claims available under the final configuration. Subsequent direct DIVIDENDS donations to the token contract cannot be converted. Operational owners should use a reviewed multisig and retain ownership while fee conversion is needed.

Before release, the deployer must verify factory/PoolManager/registry behavior, select and review the actual reward token, supply launch economics and price, arrange owner reward funding and keeper gas, and review creation/runtime bytes and constructor arguments. This task does not deploy, broadcast transactions, hold keys, set economics or operate a keeper.

The pinned external harness is deployment-driven and requires platform contracts, manifest-resolved bytecode and launch environment settings not supplied here. It was read as the launch specification; the local suite tests its relevant token requirements and the real v4 settlement paths without pretending to have run that external admission process. Foundry tests and local source review are not an independent security audit. An independent adversarial review remains a release responsibility. Slither and Mythril were not run.
