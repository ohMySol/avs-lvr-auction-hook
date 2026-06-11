# EigenAuction — LVR Auction Hook for Uniswap V4

EigenAuction is a Uniswap V4 hook that eliminates Loss-versus-Rebalancing (LVR) for LPs by running an on-chain arbitrage auction secured by EigenLayer. Instead of MEV searchers capturing arbitrage profit at LP expense, the auction routes that profit back to liquidity providers.

---

## The Problem

Every AMM suffers LVR: whenever the pool price diverges from the CEX price, arbitrageurs profit by pushing the pool back to fair value. That profit comes directly from LPs — it is a structural, unavoidable cost of providing liquidity. On Ethereum mainnet, LVR accounts for roughly 50–80% of LP losses on concentrated pools.

## The Solution

EigenAuction replaces open arbitrage competition with a per-block sealed auction, modelled on [Angstrom](https://sorellalabs.xyz):

1. Each block, EigenLayer-staked operators observe the pool vs CEX price gap and each compute how much arb profit they are willing to share with LPs (their bid)
2. The AVS quorum selects the operator with the highest bid as the block's exclusive settler
3. The winning operator calls `settle()`: pays their bid upfront to in-range LPs, then atomically executes the arb swap + all queued user swaps inside a single Uniswap V4 unlock
4. LPs receive arb profits proportional to their liquidity share; EigenLayer slashing punishes any operator that cheats

Operators are the arbitrageurs — they are EigenLayer-restaked nodes with skin in the game, not anonymous MEV bots. The pool is locked to the winning operator for the block, preventing anyone else from front-running or sandwiching.

**Current state (testnet demo):** single operator, `QUORUM_THRESHOLD = 1`. The operator commits itself as winner each block and settles immediately after the challenge window. The full multi-operator competitive quorum is the next milestone.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Uniswap V4 Pool                       │
│                                                          │
│   EigenAuctionHook                                       │
│   ├── beforeSwap: pool lock check + JIT guard            │
│   ├── afterSwap:  reward distribution to LPs             │
│   └── afterModifyLiquidity: position tracking            │
└──────────────┬───────────────────────────────────────────┘
               │ only settler can swap
┌──────────────▼───────────────────────────────────────────┐
│                      Settler.sol                         │
│   settle(key, rewardAmount, arbitrage, intents)          │
│   ├── Step 1: arbitrage swap (pool → CEX price)          │
│   └── Step 2: fill queued user intents (EIP-712)         │
└──────────────┬───────────────────────────────────────────┘
               │ winner check
┌──────────────▼───────────────────────────────────────────┐
│             AuctionServiceManager.sol (EigenLayer AVS)   │
│   commitWinner(poolId, block, winner, bid, signatures)   │
│   └── m-of-n ECDSA threshold, challenge window, slash    │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│                     Off-chain stack                      │
│   avs-auction   — operator loop: price watch → commit    │
│   searcher-rpc  — HTTP: intent + bid intake queue        │
│   frontend      — LP dashboard + trade UI (React/wagmi)  │
└──────────────────────────────────────────────────────────┘
```

---

## Repository layout

```
src/
  contracts/           Solidity (Foundry)
    src/
      EigenAuctionHook.sol      V4 hook, pool lock, reward distribution
      Settler.sol               Atomic arbitrage + intent settlement
      AuctionServiceManager.sol EigenLayer AVS, winner commit, challenge, slash
      interfaces/               Public interfaces for all three contracts
      libraries/                ErrorsLib, EventsLib, ConstantsLib, RewardGrowthLib
    script/
      DeployTestnet.s.sol       Sepolia: FaucetTokens + protocol + seeded LP
      Deploy.s.sol              Mainnet fork: uses real USDC/WETH
      base/DeployCore.sol       Shared deploy logic
    test/
      unit/                     53 Foundry tests across all contracts

  backend/
    avs-auction/         Operator node (runs the block-by-block auction loop)
    searcher-rpc/        HTTP API (intent + bid intake, Redis queue)
    shared/              Config, ABIs, types shared by both services

  frontend/
    app/                 React SPA — LP dashboard, pool stats, trade view
      chain/             wagmi hooks, deployment artifact loader, V4 math

deployments/             JSON artifacts written by deploy scripts, read by backend + frontend
```

---

## Contracts

See [src/contracts/](src/contracts/) for full Solidity source.

| Contract | Description |
|---|---|
| `EigenAuctionHook` | V4 hook — pool lock, JIT guard, V3-style tick-outside reward accumulator |
| `Settler` | Atomic settlement — arbitrage swap + EIP-712 intent fills in one V4 unlock |
| `AuctionServiceManager` | EigenLayer AVS — m-of-n ECDSA commit, challenge window, slashing |

---

## Quick start

### Sepolia testnet
! Script is working, but verification should be fixed. Contracts can be deployed successfully but needs to be verified.

```bash
cp .env.example .env           # fill SEPOLIA_RPC_URL, DEPLOYER_PK, OPERATOR_PK, ETHERSCAN_API_KEY
make deploy-testnet            # deploy + verify contracts, write deployments/11155111.json
docker compose up --build      # start all 4 services → http://localhost:8080
```

### Local mainnet fork

```bash
make anvil-fork                # terminal 1: fork mainnet at chainId 1
make fund deploy-fork seed     # terminal 2: fund wallets + deploy + seed LP
docker compose up -d redis
make start-server              # searcher-rpc
make start-operator            # avs-auction operator
make frontend-dev              # Vite dev server → http://localhost:5173
```

For a full narrated demo flow, see [DEMO_GUIDE.md](DEMO_GUIDE.md).

---

## Tests

```bash
make test          # all tests: forge (Solidity) + vitest (TypeScript)
make build         # compile contracts only
```

53 Foundry unit tests + 34 TypeScript tests. Coverage: reward distribution, JIT detection, pool lock, fallback period, EIP-712 nonce bitmaps, challenge window, slash mechanics.

---

## Key design decisions

**Rewards outside V4 accounting.** The operator calls `IERC20.transferFrom(operator, hook, rewardAmount)` directly — outside V4's sync/settle flow — before the arbitrage swap executes. This avoids `CurrencyNotSettled` reverts and keeps the reward accounting independent of V4 delta math.

**V3-style tick-outside accumulators.** `rewardGrowthGlobalX128` mirrors Uniswap V3's `feeGrowthGlobalX128`. Each LP position tracks `rewardGrowthInsideLast` at add/remove time; `earned()` computes the delta. Rewards are automatically paid when liquidity is removed — no separate claim transaction needed.

**JIT guard.** Before executing the arbitrage, the operator reads pool liquidity and passes it as `expectedLiquidity` in hookData. `beforeSwap` reverts if the actual liquidity differs, preventing JIT LPs from adding liquidity after the operator's snapshot to dilute existing LPs' rewards.

**Fallback period.** If no settlement lands within `FALLBACK_PERIOD` blocks, the pool re-opens to public swaps. This prevents a liveness failure if the operator goes offline.

**Single operator for testnet demo.** `QUORUM_THRESHOLD = 1`. The full Angstrom-style multi-operator quorum with BFT winner selection is the next milestone.

---

## Documentation

- [src/backend/README.md](src/backend/README.md) — operator node + searcher-rpc architecture
- [src/frontend/README.md](src/frontend/README.md) — React app, wagmi hooks, deployment artifact
- [DEMO_GUIDE.md](DEMO_GUIDE.md) — step-by-step testnet deployment and demo walkthrough
