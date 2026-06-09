// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {ConfigLib, Deployment} from "./libs/ConfigLib.sol";
import {DemoLP} from "./helpers/DemoLP.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title SetupDemoLP
/// @notice Deploys a DemoLP, funds it from the deployer's balance, and seeds an in-range position so
/// the full-flow demo has a claimable LP. Writes deployments/<chainId>.demo.json with the LP address.
/// Run after DeployFork + `make fund`. The seeded liquidity matures one block later (JIT guard).
contract SetupDemoLP is Script {
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

        DemoLP lp = new DemoLP(IPoolManager(d.poolManager));

        // Fund the LP from the deployer (funded by `make fund`). Generous amounts; the add pulls
        // only what the position needs and leaves the rest idle in the LP contract.
        IERC20(d.currency0).transfer(address(lp), 200_000 * (10 ** d.currency0Decimals));
        IERC20(d.currency1).transfer(address(lp), 100 * (10 ** d.currency1Decimals));

        lp.addLiquidity(key, TICK_LOWER, TICK_UPPER, LIQUIDITY_DELTA);

        vm.stopBroadcast();

        // Persist the LP address for the off-chain demo.
        string memory obj = "demo";
        string memory json = vm.serializeAddress(obj, "demoLP", address(lp));
        string memory path =
            string.concat(vm.projectRoot(), "/../../deployments/", vm.toString(block.chainid), ".demo.json");
        vm.writeJson(json, path);

        console2.log("DemoLP:", address(lp));
    }
}
