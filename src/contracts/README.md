# Contracts

Solidity contracts for EigenAuction. Three core contracts — a Uniswap V4 hook, an atomic settlement contract, and an EigenLayer AVS service manager — working together to run a per-block arbitrage auction and return arb profits to LPs.

---

## Architecture overview

```
                    ┌──────────────────────────────────┐
                    │       AuctionServiceManager       │
                    │  (EigenLayer AVS)                 │
                    │                                   │
                    │  commitWinner()                   │
                    │  ├─ verify m-of-n operator sigs   │
                    │  └─ store winner + bidAmount       │
                    │                                   │
                    │  challengeWinner()                │
                    │  ├─ verify higher signed bid       │
                    │  └─ slash signing operators        │
                    └──────────┬───────────────────────┘
                               │ getWinner()
                    ┌──────────▼───────────────────────┐
                    │           Settler                 │
                    │                                   │
                    │  settle(key, rewardAmount,        │
                    │         arb, intents)             │
                    │  ├─ check msg.sender == winner    │
                    │  ├─ transferFrom(winner→hook,     │
                    │  │   rewardAmount)                │
                    │  ├─ Step 1: arb swap              │
                    │  └─ Step 2: fill user intents     │
                    └──────────┬───────────────────────┘
                               │ swap()
                    ┌──────────▼───────────────────────┐
                    │       EigenAuctionHook            │
                    │  (Uniswap V4 Hook)                │
                    │                                   │
                    │  beforeSwap:                      │
                    │  ├─ pool lock (settler only)      │
                    │  └─ JIT guard                     │
                    │                                   │
                    │  afterSwap:                       │
                    │  ├─ cross tick accumulators       │
                    │  └─ fold rewardAmount into        │
                    │     rewardGrowthGlobalX128         │
                    │                                   │
                    │  afterRemoveLiquidity:            │
                    │  └─ auto-pay earned rewards       │
                    └──────────────────────────────────┘
```

---

## Contracts

### `EigenAuctionHook.sol`

Uniswap V4 hook that enforces the pool lock and distributes arb rewards to LPs.

#### Pool lock

Once `setSettler(address)` is called by the owner, the hook rejects all swaps that do not originate from the registered `settler` address. This gives the auction winner exclusive access to move the pool price.

Two escape hatches prevent permanent lock-in:
- If no `settler` has been set yet, public swaps are allowed.
- If `FALLBACK_PERIOD` blocks pass without any settlement, the pool re-opens to public swaps. This prevents a liveness failure if the operator goes offline.

```solidity
// beforeSwap access control (simplified)
if (sender == settler) return allow;
if (settler == address(0) || block.number > lastSettledBlock + FALLBACK_PERIOD) return allow;
revert EigenAuctionHook_NotSettler();
```

#### JIT guard

Before the arb swap executes, `Settler` reads the pool's active liquidity and passes it as `expectedLiquidity` in hookData. In `beforeSwap`, the hook reads current pool liquidity and reverts if they differ. This prevents a JIT LP from adding liquidity after the operator's snapshot to dilute existing LPs' share of the reward.

```solidity
if (poolManager.getLiquidity(poolId) != uint128(expectedLiquidity)) {
    revert EigenAuctionHook_LiquidityMismatch();
}
```

#### Reward distribution

Rewards are distributed using a **V3-style tick-outside accumulator** — the same mechanism Uniswap V3 uses for fee distribution. Every LP position earns proportionally to its liquidity and the time it was in range.

**Global accumulator** — after each arb swap, the reward is folded into `rewardGrowthGlobalX128`:

```solidity
rewardGrowthGlobalX128[poolId] += FullMath.mulDiv(rewardAmount, Q128, poolLiquidity);
```

**Tick-outside values** — each tick registered as a position boundary stores `tickGrowthOutside`. When the arb swap crosses a tick, the outside value is flipped: `outside = global - outside`. This is how the hook knows how much growth accrued "below" vs "above" any given tick.

**Position checkpoint** — each position stores `lastGrowthInsideX128`. On add/remove, the hook computes `growthInside = global - below - above` and accumulates the delta into `position.owed`. On remove, `owed` is transferred directly to the LP — no separate claim transaction needed.

#### Hook callbacks

| Callback | Triggered by | Action |
|---|---|---|
| `beforeSwap` | Any swap attempt | Pool lock check, JIT guard, tick snapshot |
| `afterSwap` | After any swap | Tick crossing, reward accumulation |
| `afterAddLiquidity` | External LP add via router | Record position in reward ledger, register tick boundaries |
| `afterRemoveLiquidity` | External LP remove via router | Update position, auto-pay earned rewards |

#### LP entry points

`addLiquidity` and `removeLiquidity` are the hook's own entry points for LP management. They call `poolManager.unlock()` internally so the hook can update the reward ledger keyed to the real LP address (V4 skips liquidity callbacks on self-calls, so the ledger update is done inline in `unlockCallback`).

#### Storage

| Variable | Type | Description |
|---|---|---|
| `settler` | `address` | The only address permitted to initiate swaps |
| `lastSettledBlock` | `uint256` | Block of the most recent settlement, for fallback period tracking |
| `rewardGrowthGlobalX128` | `mapping(PoolId => uint256)` | Per-pool cumulative reward accumulator |
| `_positions` | `mapping(bytes32 => Position)` | Per-position reward state: liquidity, lastGrowthInsideX128, owed |
| `_tickGrowthOutside` | `mapping(PoolId => mapping(int24 => uint256))` | Per-tick outside accumulator |
| `_tickBoundaries` | `mapping(PoolId => int24[])` | All registered tick boundaries — iterated on every arb swap |

---

### `Settler.sol`

Chain-wide atomic settlement contract. Deploy once per chain; register on each pool's hook via `hook.setSettler(address(this))`.

The winning operator calls `settle()` once per pool per block. Everything executes atomically inside a single Uniswap V4 `unlock()` context — either the full settlement succeeds or nothing changes.

#### `settle()` — entry point

```solidity
function settle(
    PoolKey calldata key,
    uint256 rewardAmount,
    SwapParams calldata arb,
    SwapIntent[] calldata intents
) external
```

Before entering the V4 unlock, three checks run:

1. **Auction committed** — `avs.getWinner(poolId, block.number).committed` must be true
2. **Not challenged** — the result must not have been invalidated by a fraud proof
3. **Caller is winner** — `msg.sender == result.winner`; only the committed winner can settle

#### Step 1 — Arb swap

Inside `unlockCallback`, if `arb.amountSpecified != 0`:

1. Transfer `rewardAmount` of currency0 from the winner to the hook (`transferFrom`). The hook distributes this to LPs in `afterSwap`.
2. Read current pool liquidity for the JIT guard snapshot.
3. Execute the arb swap with hookData `(isArb=true, rewardAmount, expectedLiquidity)`.
4. Settle the winner's token deltas (pay token in, receive token out).

The reward transfer happens **outside V4 flash accounting** (direct ERC20 `transferFrom` before the swap, not via `sync/settle`). This avoids `CurrencyNotSettled` reverts — V4 only tracks tokens moved through its own accounting.

#### Step 2 — User intent fills

For each `SwapIntent` in the intents array:

1. Pool ID match check
2. Deadline check
3. Nonce consumed (bitmap — prevents replay)
4. EIP-712 signature verified on-chain
5. Swap executed at the post-arb price
6. Slippage check: `amountOut >= minAmountOut`
7. User's token deltas settled

#### `SwapIntent` — EIP-712 structure

```solidity
struct SwapIntent {
    address  user;          // signer and token recipient
    bytes32  poolId;
    bool     zeroForOne;    // swap direction
    uint128  amountIn;      // exact input
    uint128  minAmountOut;  // slippage protection
    uint64   nonce;         // replay protection
    uint64   deadline;      // unix timestamp
    bytes    signature;     // EIP-712 sig over the above fields
}
```

Users sign intents off-chain (no gas) and submit them to `searcher-rpc`. The operator batches them into the settlement. The signature is verified on-chain by `Settler` before execution.

#### Nonce bitmap

Nonces use a packed 256-bit bitmap per user per word (`nonce >> 8` selects the word; `nonce & 0xff` selects the bit). A used nonce is permanently set — there is no way to reset it. Users can proactively invalidate a pending intent by calling `invalidateNonce(nonce)`.

---

### `AuctionServiceManager.sol`

EigenLayer AVS service manager. Inherits `ServiceManagerBase` from `eigenlayer-middleware` — all EigenLayer infrastructure (operator registration, rewards, metadata) is handled by the base. On top, it adds per-block auction winner commitment with ECDSA `m-of-n` threshold validation, a fraud-proof challenge window, and EigenLayer slashing.

#### EigenLayer integration

Operators join the AVS by calling `AllocationManager.registerForOperatorSets` on EigenLayer. Admission is permissionless at the application layer — the economic gate is EigenLayer's restaking requirement. The `AuctionServiceManager` implements `IAVSRegistrar`, making it its own registrar: `registerOperator` and `deregisterOperator` are called by EigenLayer's `AllocationManager` when membership changes.

**Setup sequence (owner, once post-deployment):**

```solidity
registerAvsMetadata(metadataURI);          // register AVS with AllocationManager
createOperatorSet(strategies);             // create operator set with slashable strategies
configureSlashing(strategies, wads);       // set slash proportions per strategy
```

Operators then join independently via EigenLayer's `AllocationManager.registerForOperatorSets`.

#### `commitWinner()` — per-block auction result

```solidity
function commitWinner(
    PoolId poolId,
    uint256 targetBlock,
    address winner,
    uint256 bidAmount,
    bytes[] calldata signatures
) external
```

The operator calls this to record the auction result for `targetBlock`. The function:

1. Rejects stale blocks (must be committed within 1 block of `targetBlock`)
2. Rejects duplicate commits for the same `(poolId, targetBlock)` pair
3. Recovers each signature over `keccak256(poolId, targetBlock, winner, bidAmount)`
4. Checks each signer is an EigenLayer operator-set member via `AllocationManager.isMemberOfOperatorSet`
5. Deduplicates signers
6. Requires `validSigs >= threshold` — reverts with `QuorumNotMet` otherwise
7. Stores `AuctionResult { winner, bidAmount, committed: true, signers }`

#### `challengeWinner()` — fraud proof

```solidity
function challengeWinner(
    PoolId poolId,
    uint256 targetBlock,
    address higherBidder,
    uint256 higherBidAmount,
    bytes calldata bidderSignature
) external
```

Anyone can challenge a committed result within `CHALLENGE_WINDOW` blocks by providing a signed bid that was higher than the committed one. The challenge:

1. Verifies the result is committed and not already challenged
2. Verifies the challenge is within `CHALLENGE_WINDOW` blocks of commitment
3. Verifies `higherBidAmount > result.bidAmount`
4. Recovers `bidderSignature` over `keccak256(poolId, targetBlock, higherBidAmount)` and confirms it matches `higherBidder`
5. Marks the result as `challenged = true` (blocking `Settler.settle()`)
6. Calls `AllocationManager.slashOperator` for every operator who signed the fraudulent commitment

A successfully challenged result permanently blocks settlement for that block. The pool falls back to public access after `FALLBACK_PERIOD` blocks.

#### `AuctionResult` struct

```solidity
struct AuctionResult {
    uint256   bidAmount;
    address   winner;
    bool      committed;
    bool      challenged;
    uint256   committedBlock;
    address[] signers;       // kept for slashing on challenge
}
```

---

## Libraries

### `RewardGrowthLib.sol`

Pure math for the tick-outside accumulator, modelled on Uniswap V3's `feeGrowthInside` accounting. All arithmetic wraps intentionally (matching V3's `unchecked` design) so the inside/outside bookkeeping stays consistent as ticks are crossed.

**`growthInside(currentTick, tickLower, tickUpper, growthGlobal, lowerOutside, upperOutside)`**

Computes how much reward growth accrued inside `[tickLower, tickUpper]` using the stored outside values:

```
below  = currentTick >= tickLower ? lowerOutside : global - lowerOutside
above  = currentTick <  tickUpper ? upperOutside : global - upperOutside
inside = global - below - above
```

**`rewardsOf(insideNow, lastInside, liquidity)`**

Converts the growth delta into a token amount using `FullMath.mulDiv` for overflow-safe 512-bit intermediate multiplication:

```
reward = (insideNow - lastInside) * liquidity / Q128
```

### `ConstantsLib.sol`

| Constant | Value | Description |
|---|---|---|
| `CHALLENGE_WINDOW` | 50 blocks | Window after `commitWinner` during which a fraud proof can be submitted |
| `FALLBACK_PERIOD` | 5 blocks | Blocks without settlement before the pool re-opens to public swaps |
| `OPERATOR_SET_ID` | 1 | EigenLayer operator-set ID this AVS uses |

### `ErrorsLib.sol`

All custom errors for the system in one library, grouped by contract.

### `EventsLib.sol`

All events in one library.

| Event | Emitted by | When |
|---|---|---|
| `WinnerCommitted` | `AuctionServiceManager` | A valid `commitWinner` lands |
| `WinnerChallenged` | `AuctionServiceManager` | A fraud proof succeeds |
| `OperatorSlashed` | `AuctionServiceManager` | Each operator slashed after a challenge |
| `OperatorRegistered` | `AuctionServiceManager` | EigenLayer AllocationManager admits an operator |
| `OperatorDeregistered` | `AuctionServiceManager` | EigenLayer AllocationManager removes an operator |
| `ArbitrageSettled` | `EigenAuctionHook` | Arb swap completes and reward is folded into the growth accumulator |
| `RewardsClaimed` | `EigenAuctionHook` | LP receives earned rewards on `removeLiquidity` |
| `LiquidityAdded` | `EigenAuctionHook` | LP adds liquidity via the hook's entry point |
| `LiquidityRemoved` | `EigenAuctionHook` | LP removes liquidity via the hook's entry point |
| `IntentFilled` | `Settler` | A user `SwapIntent` executes successfully |
| `NonceInvalidated` | `Settler` | User cancels a pending intent |
| `BlockSettled` | `Settler` | Full settlement round (arb + intents) completes |
| `SettlerSet` | `EigenAuctionHook` | Settler address registered on the hook |

---

## Full settlement flow

```
1. COMMIT (operator, pre-block)
   operator.commitWinner(poolId, targetBlock, winner, bidAmount, [sig1, sig2, ...])
   → AuctionServiceManager validates quorum, stores AuctionResult

2. CHALLENGE WINDOW
   50 blocks during which anyone can submit a fraud proof.
   A successful challenge marks the result invalid and slashes all signers.

3. SETTLE (winner, after challenge window)
   winner.settle(poolKey, rewardAmount, arb, intents)
   → Settler checks: committed ✓, not challenged ✓, msg.sender == winner ✓
   → hook.recordSettlement()  — resets fallback timer
   → poolManager.unlock(...)
       → Settler.unlockCallback:
           a. transferFrom(winner, hook, rewardAmount)    — reward pre-funded outside V4 accounting
           b. getLiquidity(poolId)                        — JIT snapshot
           c. poolManager.swap(arb, hookData=(true, rewardAmount, expectedLiquidity))
               → beforeSwap: pool lock ✓, JIT guard ✓, tick snapshot
               → afterSwap:  cross tick accumulators, fold reward into rewardGrowthGlobalX128
           d. settleDeltas(winner, arb)                   — winner pays tokenIn, receives tokenOut
           e. for each intent:
               → verify deadline, nonce, EIP-712 sig
               → poolManager.swap(intent params)
               → slippage check
               → settleDeltas(user, intent)

4. LP REWARDS (at any future removeLiquidity)
   hook.removeLiquidity(key, lower, upper, liquidity)
   → hook.unlockCallback:
       → _payRewards: transfer earned() directly to LP in the same tx
       → settle principal token deltas
```

---

## Known limitations

**`_tickBoundaries` O(n) loop.** Every arb swap iterates all registered tick boundaries for the pool to flip outside accumulators. Gas cost grows linearly with the number of unique tick values registered. For a demo pool with a few LPs (4–10 tick boundaries) this is negligible. At scale this needs a bounded traversal — only ticks between `priorTick` and `newTick` need flipping.

**Reward lost when pool liquidity is zero post-arb.** If the arb pushes the price past all active positions, `poolLiquidity == 0` after the swap and accumulation is skipped. The `rewardAmount` was already transferred to the hook and remains there with no owner.

**Single-operator quorum.** `QUORUM_THRESHOLD = 1` for the testnet demo. Multi-operator competitive quorum is the next milestone.

---

## Tests

```bash
forge test --root src/contracts -vvv
```

53 tests across four files:

| File | Coverage |
|---|---|
| `EigenAuctionHook.t.sol` | Reward distribution, pool lock, fallback period, JIT guard |
| `EigenAuctionHookLP.t.sol` | Add/earn/remove, tick crossing, two-LP proportional split |
| `Settler.t.sol` | Intent fill, nonce replay, slippage, arb + reward, full integration with real hook |
| `AuctionServiceManager.t.sol` | Commit, quorum check, challenge, slash window, signer deduplication (27 tests) |

---

## Deployment

### Sepolia testnet

```bash
make deploy-testnet
```

Deploys `AuctionServiceManager`, `EigenAuctionHook`, `Settler`, two `FaucetToken`s, initialises the pool at 1:1, seeds an LP position, registers the operator into the AVS operator set, and writes `deployments/11155111.json`. Contracts are verified on Etherscan automatically via `--verify`.

### Local mainnet fork

```bash
make deploy-fork
```

Uses real USDC/WETH from the forked mainnet state. Writes `deployments/1.json`.

### Post-deployment AVS setup (owner, once)

```solidity
// 1. Register AVS metadata with EigenLayer AllocationManager
asm.registerAvsMetadata("https://...");

// 2. Create the operator set with slashable strategies
asm.createOperatorSet([stEthStrategy, ...]);

// 3. Configure slash proportions (wads: 1e18 = 100%, 1e17 = 10%)
asm.configureSlashing([stEthStrategy], [1e17]);
```

Operators then join independently via EigenLayer:

```solidity
allocationManager.registerForOperatorSets(
    operator,
    [{ avs: asmAddress, operatorSetIds: [1] }],
    ""
);
```
