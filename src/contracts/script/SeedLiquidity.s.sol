// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {ConfigLib, Deployment} from "./libs/ConfigLib.sol";

/// @dev Minimal ERC-20 surface for funding approvals.
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title SeedLiquidity
/// @notice Adds an in-range liquidity position to the deployed pool so the demo has LPs to reward.
/// Runs after DeployFork (reads deployments/<chainId>.json) and after `make fund` (so the broadcaster
/// holds USDC + WETH). Deploys a V4 test liquidity router and routes an add through it.
///
/// Note: liquidity added in a block is the JIT cohort and matures the next block, so let one block
/// pass before running the arb settlement so this position is reward-eligible.
///
/// Run: `forge script script/SeedLiquidity.s.sol --rpc-url $RPC_URL --broadcast`
contract SeedLiquidity is Script {
    // Full usable range for tickSpacing 60: floor(887272 / 60) * 60 = 887220.
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;
    int256 constant LIQUIDITY_DELTA = 1e15;

    function run() external {
        Deployment memory d = ConfigLib.readDeployment(vm, block.chainid);
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(d.currency0),
            currency1: Currency.wrap(d.currency1),
            fee: d.fee,
            tickSpacing: d.tickSpacing,
            hooks: IHooks(d.hook)
        });

        vm.startBroadcast(deployerPk);

        // The test router pulls input tokens from the broadcaster, so approve it for both currencies.
        PoolModifyLiquidityTest router = new PoolModifyLiquidityTest(IPoolManager(d.poolManager));
        IERC20(d.currency0).approve(address(router), type(uint256).max);
        IERC20(d.currency1).approve(address(router), type(uint256).max);

        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: LIQUIDITY_DELTA,
                salt: bytes32(0)
            }),
            ""
        );

        vm.stopBroadcast();

        console2.log("Seeded liquidity via router:", address(router));
    }
}
