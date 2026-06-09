// External (CEX/oracle) reference price for the pool, plus its sqrtPriceX96 encoding.
// price is denominated as currency1 per currency0 in whole tokens — the human convention. The
// conversion below folds in token decimals so the result matches the pool's raw-unit sqrtPriceX96.
import { config } from "../../shared/config";

// Integer square root (Newton's method) so a 33-digit sqrtPriceX96 stays exact — Number math would
// lose the low ~17 digits.
function isqrt(value: bigint): bigint {
    if (value < 0n) throw new Error("isqrt of negative");
    if (value < 2n) return value;
    let x = value;
    let y = (x + 1n) / 2n;
    while (y < x) {
        x = y;
        y = (x + value / x) / 2n;
    }
    return x;
}

// Fetch the external market price. Demo: a fixed env value; testnet: swap in the binance ws feed
// (Milestone 5) or an on-chain oracle read. Kept async so the L1 implementation is a drop-in.
export async function externalPrice(): Promise<number> {
    if (config.priceSource === "fixed") return config.fixedPrice;
    throw new Error(`price source not implemented: ${config.priceSource}`);
}

// Convert a human price (currency1 per currency0, whole tokens) into Uniswap's sqrtPriceX96.
//   price_raw  = price * 10^(decimals1 - decimals0)      // raw units, as the pool stores it
//   sqrtP_X96  = floor( sqrt(price_raw) * 2^96 ) = floor( sqrt(price_raw * 2^192) )
// Without the decimal term a 6/18 pair like USDC/WETH is off by 10^6 in sqrt space.
export function priceToSqrtX96(price: number, decimals0 = 18, decimals1 = 18): bigint {
    // 18 digits of fixed-point precision on the (possibly fractional) human price.
    const PRICE_SCALE = 10n ** 18n;
    const priceScaled = BigInt(Math.round(price * 1e18));

    let numerator = priceScaled << 192n; // priceScaled * 2^192
    let denominator = PRICE_SCALE;

    const decDiff = decimals1 - decimals0;
    if (decDiff >= 0) {
        numerator *= 10n ** BigInt(decDiff);
    } else {
        denominator *= 10n ** BigInt(-decDiff);
    }

    return isqrt(numerator / denominator);
}
