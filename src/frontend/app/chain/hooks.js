// React hooks that bind the views to the deployed contracts via wagmi/viem. Every read is gated on a
// live deployment (`IS_LIVE`) and a connected account, so the UI degrades to the mock data layer when
// no artifact is present. Writes await their receipt before resolving so callers can refetch.
import React from "react";
import { useAccount, useConnect, useDisconnect, useReadContract, useWriteContract, useWatchContractEvent, useSignTypedData, useBlockNumber, useChainId } from "wagmi";
import { readContract, waitForTransactionReceipt } from "@wagmi/core";
import { maxUint256, zeroHash, parseUnits, formatUnits } from "viem";
import { wagmiConfig } from "./wagmi.js";
import { DEPLOYMENT, POOL_KEY, IS_LIVE, CHAIN_ID, INTENT_URL } from "./deployment.js";
import { hookAbi, stateViewAbi, erc20Abi } from "./abis.js";
import { getSqrtRatioAtTick, getLiquidityForAmounts, getAmountsForLiquidity, priceFromSqrtX96 } from "./v4Math.js";

// The seeded/frontend LP uses the full usable range at salt 0 (matches SeedLiquidity + DeployTestnet).
export const FULL_RANGE_LOWER = -887220;
export const FULL_RANGE_UPPER = 887220;

const HOOK = DEPLOYMENT?.hook;
const STATE_VIEW = DEPLOYMENT?.stateView;
const POOL_ID = DEPLOYMENT?.pool?.poolId;
export const DEC0 = DEPLOYMENT?.pool?.currency0Decimals ?? 18;
export const DEC1 = DEPLOYMENT?.pool?.currency1Decimals ?? 18;

/* ---------- wallet ---------- */

export function useWallet() {
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const injected = connectors[0];
  return {
    address,
    isConnected,
    connect: () => injected && connect({ connector: injected }),
    disconnect,
  };
}

/* ---------- reads ---------- */

// Pool spot price from the V4 StateView, refreshed roughly once per block.
export function usePoolPrice() {
  const { data, refetch } = useReadContract({
    address: STATE_VIEW, abi: stateViewAbi, functionName: "getSlot0", args: [POOL_ID],
    query: { enabled: IS_LIVE, refetchInterval: 12_000 },
  });
  const sqrtPriceX96 = data?.[0];
  return {
    sqrtPriceX96,
    tick: data?.[1],
    price: sqrtPriceX96 != null ? priceFromSqrtX96(sqrtPriceX96, DEC0, DEC1) : undefined,
    refetch,
  };
}

// Pending LVR rewards for `account`'s full-range position, in currency0. Paid out on removeLiquidity.
export function useEarned(account) {
  const { data, refetch } = useReadContract({
    address: HOOK, abi: hookAbi, functionName: "earned",
    args: [POOL_KEY, account, FULL_RANGE_LOWER, FULL_RANGE_UPPER, zeroHash],
    query: { enabled: IS_LIVE && !!account, refetchInterval: 12_000 },
  });
  return { amount: data, dec: DEC0, refetch };
}

// The hook-tracked liquidity of `account`'s full-range position.
export function usePositionLiquidity(account) {
  const { data, refetch } = useReadContract({
    address: HOOK, abi: hookAbi, functionName: "positionLiquidity",
    args: [POOL_KEY, account, FULL_RANGE_LOWER, FULL_RANGE_UPPER, zeroHash],
    query: { enabled: IS_LIVE && !!account },
  });
  return { liquidity: data, refetch };
}

// Wallet balances of both pool currencies.
export function useTokenBalances(account) {
  const enabled = IS_LIVE && !!account;
  const c0 = useReadContract({ address: POOL_KEY?.currency0, abi: erc20Abi, functionName: "balanceOf", args: [account], query: { enabled } });
  const c1 = useReadContract({ address: POOL_KEY?.currency1, abi: erc20Abi, functionName: "balanceOf", args: [account], query: { enabled } });
  return {
    balance0: c0.data, balance1: c1.data, dec0: DEC0, dec1: DEC1,
    refetch: () => { c0.refetch(); c1.refetch(); },
  };
}

// Subscribe to settled arbitrages (pool-stats live feed).
export function useArbEvents(onSettled) {
  useWatchContractEvent({ address: HOOK, abi: hookAbi, eventName: "ArbitrageSettled", onLogs: onSettled, enabled: IS_LIVE });
}

// Real block number and chain name from the connected wallet's chain.
const CHAIN_NAMES = { 1: 'Ethereum', 11155111: 'Sepolia', 31337: 'Anvil', 8453: 'Base', 84532: 'Base Sepolia' };
export function useChainInfo() {
  const { data: blockNumber } = useBlockNumber({ query: { enabled: IS_LIVE, refetchInterval: 12_000 } });
  const chainId = useChainId();
  return {
    blockNumber: blockNumber != null ? Number(blockNumber) : null,
    chainName: CHAIN_NAMES[chainId] ?? `Chain ${chainId}`,
  };
}

// Total pool liquidity from V4 StateView.
export function usePoolLiquidity() {
  const { data, refetch } = useReadContract({
    address: STATE_VIEW, abi: stateViewAbi, functionName: "getLiquidity", args: [POOL_ID],
    query: { enabled: IS_LIVE, refetchInterval: 12_000 },
  });
  return { poolLiquidity: data, refetch };
}

// Computed position amounts: derives token amounts from on-chain liquidity + pool sqrtPrice.
// Returns null when not live or position is empty.
export function usePositionAmounts(account) {
  const { liquidity: posLiquidity } = usePositionLiquidity(account);
  const { sqrtPriceX96, price: poolPrice } = usePoolPrice();
  const { poolLiquidity } = usePoolLiquidity();

  if (!posLiquidity || posLiquidity === 0n || !sqrtPriceX96) return null;

  const sqrtA = getSqrtRatioAtTick(FULL_RANGE_LOWER);
  const sqrtB = getSqrtRatioAtTick(FULL_RANGE_UPPER);
  const { amount0, amount1 } = getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, posLiquidity);

  const poolShareBps = poolLiquidity && poolLiquidity > 0n
    ? Number((posLiquidity * 10000n) / poolLiquidity)
    : 0;

  const amount0Human = Number(formatUnits(amount0, DEC0));
  const amount1Human = Number(formatUnits(amount1, DEC1));
  // Value in currency0 terms: amount0 + amount1 / (c1/c0 price)
  const valueC0 = poolPrice != null ? amount0Human + amount1Human / poolPrice : amount0Human;

  return { posLiquidity, poolShareBps, amount0Human, amount1Human, valueC0, poolPrice };
}

/* ---------- writes ---------- */

async function approveIfNeeded(writeContractAsync, account, token, amount) {
  const allowance = await readContract(wagmiConfig, { address: token, abi: erc20Abi, functionName: "allowance", args: [account, HOOK] });
  if (allowance < amount) {
    const hash = await writeContractAsync({ address: token, abi: erc20Abi, functionName: "approve", args: [HOOK, maxUint256] });
    await waitForTransactionReceipt(wagmiConfig, { hash });
  }
}

// Drip both FaucetTokens to the caller.
export function useFaucet() {
  const { writeContractAsync, isPending } = useWriteContract();
  async function faucet() {
    for (const token of [POOL_KEY.currency0, POOL_KEY.currency1]) {
      const hash = await writeContractAsync({ address: token, abi: erc20Abi, functionName: "faucet", args: [] });
      await waitForTransactionReceipt(wagmiConfig, { hash });
    }
  }
  return { faucet, isPending };
}

// Add a full-range position from human token amounts: sizes liquidity from the current price, approves
// what's needed, then calls the hook. PoolManager pulls the exact amounts for the computed liquidity.
export function useAddLiquidity() {
  const { writeContractAsync, isPending } = useWriteContract();
  async function addLiquidity(account, amount0Human, amount1Human) {
    const amount0 = parseUnits(String(amount0Human || "0"), DEC0);
    const amount1 = parseUnits(String(amount1Human || "0"), DEC1);
    const slot0 = await readContract(wagmiConfig, { address: STATE_VIEW, abi: stateViewAbi, functionName: "getSlot0", args: [POOL_ID] });
    const liquidity = getLiquidityForAmounts(
      slot0[0], getSqrtRatioAtTick(FULL_RANGE_LOWER), getSqrtRatioAtTick(FULL_RANGE_UPPER), amount0, amount1,
    );
    if (liquidity <= 0n) throw new Error("Amounts too small to mint liquidity");

    await approveIfNeeded(writeContractAsync, account, POOL_KEY.currency0, amount0);
    await approveIfNeeded(writeContractAsync, account, POOL_KEY.currency1, amount1);
    const hash = await writeContractAsync({
      address: HOOK, abi: hookAbi, functionName: "addLiquidity",
      args: [POOL_KEY, FULL_RANGE_LOWER, FULL_RANGE_UPPER, liquidity],
    });
    await waitForTransactionReceipt(wagmiConfig, { hash });
    return hash;
  }
  return { addLiquidity, isPending };
}

// Remove `liquidity` (a uint128 amount) from the caller's full-range position.
export function useRemoveLiquidity() {
  const { writeContractAsync, isPending } = useWriteContract();
  async function removeLiquidity(liquidity) {
    const hash = await writeContractAsync({
      address: HOOK, abi: hookAbi, functionName: "removeLiquidity",
      args: [POOL_KEY, FULL_RANGE_LOWER, FULL_RANGE_UPPER, liquidity],
    });
    await waitForTransactionReceipt(wagmiConfig, { hash });
    return hash;
  }
  return { removeLiquidity, isPending };
}

// EIP-712 types for SwapIntent — mirrors INTENT_TYPES in src/shared/sign.ts.
const SWAP_INTENT_TYPES = {
  SwapIntent: [
    { name: "user", type: "address" },
    { name: "poolId", type: "bytes32" },
    { name: "zeroForOne", type: "bool" },
    { name: "amountIn", type: "uint128" },
    { name: "minAmountOut", type: "uint128" },
    { name: "nonce", type: "uint64" },
    { name: "deadline", type: "uint64" },
  ],
};

// Sign a SwapIntent with the connected wallet and POST it to the searcher-rpc /intent endpoint.
// `onSigned` is called after the wallet signature resolves (before the HTTP POST), so the caller
// can advance its UI state (e.g. "signing" → "filling") while the POST is in flight.
export function useSubmitIntent() {
  const { signTypedDataAsync, isPending: isSigning } = useSignTypedData();
  const [isPosting, setIsPosting] = React.useState(false);

  async function submitIntent({ account, zeroForOne, amountIn, minAmountOut, onSigned }) {
    if (!DEPLOYMENT?.settler || !POOL_ID) throw new Error("No deployment artifact — run the deploy script first");

    // Use 64 bits of CSPRNG output — collision-free even under rapid submission.
    const rand = new Uint32Array(2);
    crypto.getRandomValues(rand);
    const nonce = (BigInt(rand[0]) << 32n) | BigInt(rand[1]);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 300);

    const domain = {
      name: "EigenAuction Settler",
      version: "1",
      chainId: CHAIN_ID,
      verifyingContract: DEPLOYMENT.settler,
    };

    const message = { user: account, poolId: POOL_ID, zeroForOne, amountIn, minAmountOut, nonce, deadline };

    const signature = await signTypedDataAsync({
      domain, types: SWAP_INTENT_TYPES, primaryType: "SwapIntent", message,
    });

    onSigned?.();
    setIsPosting(true);
    try {
      const res = await fetch(`${INTENT_URL}/intent`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          user: account,
          poolId: POOL_ID,
          zeroForOne,
          amountIn: amountIn.toString(),
          minAmountOut: minAmountOut.toString(),
          nonce: nonce.toString(),
          deadline: deadline.toString(),
          signature,
        }),
      });
      if (!res.ok) {
        const text = await res.text().catch(() => res.statusText);
        throw new Error(`Intent rejected (${res.status}): ${text}`);
      }
    } finally {
      setIsPosting(false);
    }
  }

  return { submitIntent, isPending: isSigning || isPosting };
}
