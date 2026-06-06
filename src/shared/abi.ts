export const settlerAbi = [
  { type: "function", name: "settle", stateMutability: "nonpayable", inputs: [
      { name: "key", type: "tuple", components: [
        { name: "currency0", type: "address" }, { name: "currency1", type: "address" },
        { name: "fee", type: "uint24" }, { name: "tickSpacing", type: "int24" },
        { name: "hooks", type: "address" }] },
      { name: "arb", type: "tuple", components: [
        { name: "zeroForOne", type: "bool" }, { name: "amountSpecified", type: "int256" },
        { name: "sqrtPriceLimitX96", type: "uint160" }] },
      { name: "intents", type: "tuple[]", components: [
        { name: "user", type: "address" }, { name: "poolId", type: "bytes32" },
        { name: "zeroForOne", type: "bool" }, { name: "amountIn", type: "uint128" },
        { name: "minAmountOut", type: "uint128" }, { name: "nonce", type: "uint64" },
        { name: "deadline", type: "uint64" }, { name: "signature", type: "bytes" }] },
    ], outputs: [] },
  { type: "function", name: "isNonceUsed", stateMutability: "view",
    inputs: [{ name: "user", type: "address" }, { name: "nonce", type: "uint64" }],
    outputs: [{ type: "bool" }] },
] as const;

export const auctionServiceManagerAbi = [
  { type: "function", name: "commitWinner", stateMutability: "nonpayable", inputs: [
      { name: "poolId", type: "bytes32" }, { name: "targetBlock", type: "uint256" },
      { name: "winner", type: "address" }, { name: "bidAmount", type: "uint256" },
      { name: "signatures", type: "bytes[]" }], outputs: [] },
  { type: "function", name: "challengeWinner", stateMutability: "nonpayable", inputs: [
      { name: "poolId", type: "bytes32" }, { name: "targetBlock", type: "uint256" },
      { name: "higherBidder", type: "address" }, { name: "higherBidAmount", type: "uint256" },
      { name: "bidderSignature", type: "bytes" }], outputs: [] },
  { type: "event", name: "WinnerCommitted", inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "targetBlock", type: "uint256", indexed: true },
      { name: "winner", type: "address", indexed: true },
      { name: "bidAmount", type: "uint256", indexed: false }] },
] as const;

export const stateViewAbi = [
  { type: "function", name: "getSlot0", stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }], outputs: [
      { name: "sqrtPriceX96", type: "uint160" }, { name: "tick", type: "int24" },
      { name: "protocolFee", type: "uint24" }, { name: "lpFee", type: "uint24" }] },
  { type: "function", name: "getLiquidity", stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }], outputs: [{ type: "uint128" }] },
] as const;