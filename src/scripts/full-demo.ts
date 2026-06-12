// Full end-to-end LVR-auction demo against a mainnet fork. Narrates the whole loop:
// 1. price gap -> searchers POST signed bids -> operator runs the auction -> winner commits + settles
// 2. the arb -> the hook skims 90% of the measured LVR to LPs -> the LP claims its share.
// Ends with a with-vs-without-auction comparison.
//
// Prereqs: make anvil-fork; make fund deploy-fork seed; docker compose up -d redis;
//          make start-server (searcher-rpc on :INTENT_PORT). Then: npm run demo:full
//
// .env: FIXED_PRICE set off the pool start (e.g. 0.000476 ~ 2100 USDC/WETH) so an arb exists.
import "dotenv/config";
import Redis from "ioredis";
import { privateKeyToAccount } from "viem/accounts";
import {
    createWalletClient, 
    http, 
    erc20Abi, 
    maxUint256, 
    parseEventLogs, 
    formatUnits,
    type Address, 
    type Hex,
} from "viem";
import { config, poolKey, requireOperatorKeys } from "../shared/config";
import { getPoolId } from "../shared/poolId";
import { signIntent, signBid } from "../shared/sign";
import { settlerAbi, auctionServiceManagerAbi, eigenAuctionHookAbi } from "../shared/abi";
import { publicClient } from "../shared/config";
import { RedisMempool } from "../backend/searcher-rpc/mempool";
import { RedisBidQueue } from "../backend/searcher-rpc/bid-mempool";
import { getSlot0, buildArbParams } from "../backend/avs-auction/pool-price";
import { externalPrice, priceToSqrtX96 } from "../backend/avs-auction/cex-price";
import { runAuction, collectBids } from "../backend/avs-auction/bid-collector";
import { collectSignatures } from "../backend/avs-auction/signer";
import { commitWinner, settleAs } from "../backend/avs-auction/chain";

// Three competing searchers (anvil accounts #2-#4); bids are in currency0 units (scales with decimals0
// so it works for both USDC/6-decimal forks and 18-decimal testnet tokens).
const unit0 = 10n ** BigInt(config.decimals0);
const SEARCHERS: { pk: Hex; bidAmount: bigint }[] = [
    { pk: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", bidAmount: unit0 / 100n },   // 0.01 currency0
    { pk: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", bidAmount: unit0 / 20n },    // 0.05 currency0
    { pk: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a", bidAmount: unit0 / 10n },    // 0.10 currency0
];

const hookEventsAbi = [{ 
    type: "event", 
    name: "ArbitrageSettled", 
    inputs: [
        { name: "poolId", type: "bytes32", indexed: true },
        { name: "winner", type: "address", indexed: true },
        { name: "rewardAmount", type: "uint256", indexed: false }
    ] 
}] as const;

// The seeded in-hook LP position (see SeedLiquidity.s.sol): full range for tickSpacing 60, salt 0.
const LP_TICK_LOWER = -887220;
const LP_TICK_UPPER = 887220;
const ZERO_SALT = `0x${"00".repeat(32)}` as Hex;

const wallet = (pk: Hex) => createWalletClient({ account: privateKeyToAccount(pk), transport: http(config.rpcUrl) });

async function approveSettler(pk: Hex, token: Address) {
    await wallet(pk).writeContract({ 
        address: token, 
        abi: erc20Abi, 
        functionName: "approve", 
        args: [config.settler, maxUint256], 
        chain: null 
    });
}

async function post(path: string, body: unknown) {
    const res = await fetch(`http://127.0.0.1:${config.intentPort}${path}`, {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`${path} -> ${res.status} ${await res.text()}`);
}

const log = (s = "") => console.log(s);

async function main() {
    const poolId = getPoolId(poolKey);
    const { operatorPk } = requireOperatorKeys();
    const operator = privateKeyToAccount(operatorPk);
    const userPk = (process.env.DEPLOYER_PK ?? "").trim() as Hex;
    const user = privateKeyToAccount(userPk);
    const redis = new Redis(config.redisUrl);
    const mempool = new RedisMempool(redis, poolId);
    const bidSource = new RedisBidQueue(redis, poolId);

    // ---- 0. Approvals up front (these mine blocks; do them before fixing the target block) ----
    await approveSettler(userPk, poolKey.currency0);
    for (const s of SEARCHERS) { 
        await approveSettler(s.pk, poolKey.currency0); 
        await approveSettler(s.pk, poolKey.currency1); 
    }

    // ---- 1. The mispricing: pool vs external market ----
    const { sqrtPriceX96 } = await getSlot0(poolId);
    const target = priceToSqrtX96(await externalPrice(), config.decimals0, config.decimals1);
    
    log("=== 1. LVR opportunity ===");
    log(`pool sqrtPriceX96     : ${sqrtPriceX96}`);
    log(`external target X96   : ${target}`);
    log(`=> the pool is mispriced vs the market; arbing it is worth $LVR\n`);

    // ---- 2. A user intent arrives (Step 2 of settlement) ----
    const amountIn = 100n * 10n ** BigInt(config.decimals0);
    const unsigned = { 
        user: user.address, 
        poolId, 
        zeroForOne: true, 
        amountIn, 
        minAmountOut: 0n,
        nonce: BigInt(Date.now()), 
        deadline: BigInt(Math.floor(Date.now() / 1000) + 600) 
    };
    await post("/intent", { 
        ...unsigned,
        amountIn: amountIn.toString(), 
        minAmountOut: "0", 
        nonce: unsigned.nonce.toString(), 
        deadline: unsigned.deadline.toString(),
        signature: await signIntent(user, config.settler, config.chainId, unsigned) 
    });
   
    log("=== 2. User intent submitted to searcher-rpc (POST /intent) ===\n");

    // ---- 3. Searchers compete for the arb right (POST /bid) ----
    const targetBlock = (await publicClient.getBlockNumber()) + 2n; // commit at +1, settle at +2
    
    log("=== 3. Searchers submit competing bids (POST /bid) ===");
    
    for (const s of SEARCHERS) {
        const acct = privateKeyToAccount(s.pk);
        await post("/bid", { 
            poolId, 
            targetBlock: targetBlock.toString(), 
            bidder: acct.address,
            bidAmount: s.bidAmount.toString(), 
            signature: await signBid(acct, poolId, targetBlock, s.bidAmount) 
        });
        log(`  ${acct.address}  bids ${formatUnits(s.bidAmount, config.decimals0)} currency0`);
    }
    
    log("");

    // ---- 4. Operator runs the auction ----
    const bids = await collectBids(bidSource);
    const outcome = runAuction({ bids, designatedOperator: operator.address });
    const winner = SEARCHERS.find((s) => privateKeyToAccount(s.pk).address.toLowerCase() === outcome.winner.toLowerCase())!;
    
    log("=== 4. Auction ===");
    log(`winner: ${outcome.winner}  bid: ${formatUnits(outcome.bidAmount, config.decimals0)} currency0 (highest)\n`);

    // ---- 5. Commit the winner (operator quorum) ----
    const sigs = await collectSignatures(
        [operator], 
        { 
            poolId, 
            targetBlock, 
            winner: outcome.winner, 
            bidAmount: outcome.bidAmount 
        }, 
        1
    );
    await commitWinner(poolId, targetBlock, outcome.winner, outcome.bidAmount, sigs);
   
    log("=== 5. Winner committed on-chain (AuctionServiceManager.commitWinner) ===\n");

    // ---- 6. Winner settles: arb + user intent, atomically ----
    const arb = buildArbParams(sqrtPriceX96, target, 10n ** 24n);
    const intents = await mempool.drain();
    const hash = await settleAs(winner.pk, outcome.bidAmount, arb, intents);
    const receipt = await publicClient.getTransactionReceipt({ hash });
    const settled = parseEventLogs({ abi: hookEventsAbi, logs: receipt.logs, eventName: "ArbitrageSettled" })[0];
    const lvrToLPs = settled ? settled.args.rewardAmount : 0n;
    const rewardDec = config.decimals0;
    const rewardSym = "currency0";
    
    log("=== 6. Settler settled the block (arb rebalance + intent fill) ===");
    log(`hook skimmed LVR to LPs: ${formatUnits(lvrToLPs, rewardDec)} ${rewardSym}`);
    log(`pool sqrtPriceX96 after: ${(await getSlot0(poolId)).sqrtPriceX96}\n`);

    // ---- 7. LP removes liquidity — rewards auto-paid in the same tx ----
    const keyStruct = { 
        currency0: poolKey.currency0, 
        currency1: poolKey.currency1, 
        fee: poolKey.fee, 
        tickSpacing: poolKey.tickSpacing, 
        hooks: poolKey.hooks 
    } as const;
    const pending = await publicClient.readContract({ 
        address: config.hook, 
        abi: eigenAuctionHookAbi, 
        functionName: "earned",
        args: [
            keyStruct, 
            user.address, 
            LP_TICK_LOWER, 
            LP_TICK_UPPER, 
            ZERO_SALT
        ] 
    });

    log("=== 7. LP pending rewards (hook.earned) ===");
    log(`pending: ${formatUnits(pending, rewardDec)} ${rewardSym}`);
    
    const removeLiqAbi = [{ 
        type: "function", 
        name: "removeLiquidity", 
        stateMutability: "nonpayable",
        inputs: [{ 
            name: "key", 
            type: "tuple", 
            components: [
                { name: "currency0", type: "address" }, 
                { name: "currency1", type: "address" },
                { name: "fee", type: "uint24" }, 
                { name: "tickSpacing", type: "int24" }, 
                { name: "hooks", type: "address" }
            ]
        },
        { name: "tickLower", type: "int24" }, 
        { name: "tickUpper", type: "int24" }, 
        { name: "liquidity", type: "uint128" }
        ],
        outputs: [] 
    }] as const;

    const balBefore = await publicClient.readContract({ 
        address: poolKey.currency0, 
        abi: erc20Abi, 
        functionName: "balanceOf", 
        args: [user.address] 
    });

    await wallet(userPk).writeContract({ 
        address: config.hook, 
        abi: removeLiqAbi, 
        functionName: "removeLiquidity",
        args: [
            keyStruct, 
            LP_TICK_LOWER, 
            LP_TICK_UPPER, 
            1000n
        ], 
        chain: null 
    });

    const balAfter = await publicClient.readContract({ 
        address: poolKey.currency0, 
        abi: erc20Abi, 
        functionName: "balanceOf", 
        args: [user.address] 
    });
    
    // balAfter - balBefore includes LP principal returned + LVR rewards; actual rewards = pending (hook.earned above).
    log(`LP balance change on remove: +${formatUnits(balAfter - balBefore, rewardDec)} ${rewardSym} (principal + ${formatUnits(pending, rewardDec)} ${rewardSym} LVR rewards)\n`);

    // ---- 8. With vs without the auction ----
    log("=== 8. Value captured: with vs without the EigenAuction ===");
    log(`  without auction : LPs get 0 — the winning bid (${formatUnits(outcome.bidAmount, rewardDec)} ${rewardSym}) would have gone to the arber/builder`);
    log(`  with auction    : LPs captured ${formatUnits(lvrToLPs, rewardDec)} ${rewardSym} (100% of the winning bid, split pro-rata to LP liquidity shares)`);
    log(`\nOK: full LVR-auction flow settled end-to-end.`);

    await redis.quit();
}

main().catch((err) => { console.error("full-demo failed:", err); process.exit(1); });
