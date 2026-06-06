import { keccak256, encodeAbiParameters, type Hex } from "viem";
import type { PoolKeyT } from "./types";

export function getPoolId(poolKey: PoolKeyT): Hex {
    return keccak256(encodeAbiParameters(
        [{
            type: "tuple",
            components: [
                {name: "currency0", type : "address"},
                {name: "currency1", type : "address"},
                {name: "fee", type : "uint24"},
                {name: "tickSpacing", type : "int24"},
                {name: "hooks", type : "address"}
            ]
        }],
        [poolKey]
    ));
}