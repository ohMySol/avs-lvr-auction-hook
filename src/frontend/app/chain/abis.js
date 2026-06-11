// Minimal ABIs the frontend needs, hand-written so the UI bundle stays free of the contracts package.
// Kept in sync with the on-chain interfaces: EigenAuctionHook (LP + rewards), the V4 StateView (pool
// price/liquidity), and an ERC20 + FaucetToken surface for balances, approvals, and the testnet drip.

// The V4 PoolKey tuple, reused across hook calls.
const poolKeyTuple = {
  name: "key",
  type: "tuple",
  components: [
    { name: "currency0", type: "address" },
    { name: "currency1", type: "address" },
    { name: "fee", type: "uint24" },
    { name: "tickSpacing", type: "int24" },
    { name: "hooks", type: "address" },
  ],
};

export const hookAbi = [
  // ---- LP actions (Angstrom-style in-hook liquidity) ----
  {
    type: "function",
    name: "addLiquidity",
    stateMutability: "nonpayable",
    inputs: [
      poolKeyTuple,
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "liquidity", type: "uint128" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "removeLiquidity",
    stateMutability: "nonpayable",
    inputs: [
      poolKeyTuple,
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "liquidity", type: "uint128" },
    ],
    outputs: [],
  },
  // ---- Rewards (paid automatically on removeLiquidity) ----
  {
    type: "function",
    name: "earned",
    stateMutability: "view",
    inputs: [
      poolKeyTuple,
      { name: "owner", type: "address" },
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "salt", type: "bytes32" },
    ],
    outputs: [{ name: "amount", type: "uint256" }],
  },
  {
    type: "function",
    name: "positionLiquidity",
    stateMutability: "view",
    inputs: [
      poolKeyTuple,
      { name: "owner", type: "address" },
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "salt", type: "bytes32" },
    ],
    outputs: [{ type: "uint128" }],
  },
  // ---- Events the pool-stats / dashboard views subscribe to ----
  {
    type: "event",
    name: "ArbitrageSettled",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "winner", type: "address", indexed: true },
      { name: "rewardAmount", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "LiquidityAdded",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "lp", type: "address", indexed: true },
      { name: "tickLower", type: "int24", indexed: false },
      { name: "tickUpper", type: "int24", indexed: false },
      { name: "liquidity", type: "uint128", indexed: false },
    ],
  },
  {
    type: "event",
    name: "RewardsClaimed",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "lp", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
];

export const stateViewAbi = [
  {
    type: "function",
    name: "getSlot0",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
      { name: "protocolFee", type: "uint24" },
      { name: "lpFee", type: "uint24" },
    ],
  },
  {
    type: "function",
    name: "getLiquidity",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ type: "uint128" }],
  },
];

// ERC20 plus the FaucetToken surface (faucet / faucetAmount) used by the "Get test tokens" button.
export const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
  { type: "function", name: "faucet", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { type: "function", name: "faucetAmount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
];
