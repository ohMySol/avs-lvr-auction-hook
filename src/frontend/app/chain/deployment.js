// Loads the address artifact the deploy script writes to repo-root deployments/<chainId>.json — the
// single source of truth shared by contracts, backend, and this frontend. All artifacts are bundled
// at build time and the one matching VITE_CHAIN_ID is selected. When none exists (no deploy yet) the
// app falls back to the mock data layer, so the UI still renders for design work.
const artifacts = import.meta.glob("../../../../deployments/*.json", { eager: true });

const byChainId = {};
for (const [path, mod] of Object.entries(artifacts)) {
  const match = path.match(/(\d+)\.json$/);
  // Skip the auxiliary <chainId>.demo.json files; only the canonical <chainId>.json is a deployment.
  if (match && !path.includes(".demo.")) byChainId[match[1]] = mod.default ?? mod;
}

export const CHAIN_ID = Number(import.meta.env.VITE_CHAIN_ID ?? "11155111");

// The searcher-rpc base URL (POST /intent, /bid; GET /status). Defaults to the local dev port.
export const INTENT_URL = import.meta.env.VITE_INTENT_URL ?? "http://127.0.0.1:8088";

export const DEPLOYMENT = byChainId[String(CHAIN_ID)] ?? null;

// True when a real deployment is wired in; the UI uses this to choose live vs mock data.
export const IS_LIVE = DEPLOYMENT != null;

// True on testnets (Sepolia, Anvil local, etc.) — shows Faucet button. False on Ethereum mainnet (chainId 1).
export const IS_TESTNET = IS_LIVE && CHAIN_ID !== 1;

// The V4 PoolKey assembled from the artifact, ready to pass to contract calls.
export const POOL_KEY = DEPLOYMENT
  ? {
      currency0: DEPLOYMENT.pool.currency0,
      currency1: DEPLOYMENT.pool.currency1,
      fee: DEPLOYMENT.pool.fee,
      tickSpacing: DEPLOYMENT.pool.tickSpacing,
      hooks: DEPLOYMENT.hook,
    }
  : null;

if (!IS_LIVE) {
  // eslint-disable-next-line no-console
  console.warn(
    `[chain] No deployment artifact for chain ${CHAIN_ID}. Run the deploy script (writes ` +
      `deployments/${CHAIN_ID}.json); the UI is showing mock data until then.`
  );
}
