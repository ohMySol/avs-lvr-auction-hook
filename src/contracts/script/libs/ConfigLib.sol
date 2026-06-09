// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @notice Canonical, externally-deployed addresses for a network — the curated input read from
/// `config/networks/<chainId>.json`. These are never written by tooling.
struct NetworkConfig {
    // Uniswap V4
    address poolManager;
    address stateView;
    address permit2;
    // EigenLayer core
    address allocationManager;
    address delegationManager;
    address avsDirectory;
    address rewardsCoordinator;
    address permissionController;
    address strategyManager;
    address stakeStrategy;
    address stakeToken;
    // Pool
    address currency0;
    address currency1;
    uint8 currency0Decimals;
    uint8 currency1Decimals;
    uint24 fee;
    int24 tickSpacing;
    // AVS
    uint256 threshold;
}

/// @notice Addresses produced by a deployment — the generated output written to
/// `deployments/<chainId>.json` and consumed by the backend/frontend as the single source of truth.
struct Deployment {
    uint256 chainId;
    address poolManager;
    address stateView;
    address auctionServiceManager;
    address hook;
    address settler;
    address currency0;
    address currency1;
    uint8 currency0Decimals;
    uint8 currency1Decimals;
    uint24 fee;
    int24 tickSpacing;
    bytes32 poolId;
    uint256 deployedBlock;
}

/// @title ConfigLib
/// @notice Reads the curated per-network config and writes the generated deployment artifact, so the
/// deploy script stays declarative and the backend/frontend read one JSON keyed by chainId.
library ConfigLib {
    using stdJson for string;

    // config/ and deployments/ live at the repo root (shared by contracts + backend + frontend),
    // which is two levels above the Foundry root (src/contracts).
    function repoRoot(Vm vm) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/../..");
    }

    /// @dev Reads `config/networks/<chainId>.json` and decodes it into a NetworkConfig.
    function readNetwork(Vm vm, uint256 chainId) internal view returns (NetworkConfig memory cfg) {
        string memory path =
            string.concat(repoRoot(vm), "/config/networks/", vm.toString(chainId), ".json");
        string memory json = vm.readFile(path);

        cfg.poolManager = json.readAddress(".uniswap.poolManager");
        cfg.stateView = json.readAddress(".uniswap.stateView");
        cfg.permit2 = json.readAddress(".uniswap.permit2");

        cfg.allocationManager = json.readAddress(".eigenlayer.allocationManager");
        cfg.delegationManager = json.readAddress(".eigenlayer.delegationManager");
        cfg.avsDirectory = json.readAddress(".eigenlayer.avsDirectory");
        cfg.rewardsCoordinator = json.readAddress(".eigenlayer.rewardsCoordinator");
        cfg.permissionController = json.readAddress(".eigenlayer.permissionController");
        cfg.strategyManager = json.readAddress(".eigenlayer.strategyManager");
        cfg.stakeStrategy = json.readAddress(".eigenlayer.stakeStrategy");
        cfg.stakeToken = json.readAddress(".eigenlayer.stakeToken");

        cfg.currency0 = json.readAddress(".pool.currency0");
        cfg.currency1 = json.readAddress(".pool.currency1");
        cfg.currency0Decimals = uint8(json.readUint(".pool.currency0Decimals"));
        cfg.currency1Decimals = uint8(json.readUint(".pool.currency1Decimals"));
        cfg.fee = uint24(json.readUint(".pool.fee"));
        cfg.tickSpacing = int24(json.readInt(".pool.tickSpacing"));

        cfg.threshold = json.readUint(".avs.threshold");
    }

    /// @dev Reads back a previously written `deployments/<chainId>.json` (e.g. for SeedLiquidity).
    function readDeployment(Vm vm, uint256 chainId) internal view returns (Deployment memory d) {
        string memory path =
            string.concat(repoRoot(vm), "/deployments/", vm.toString(chainId), ".json");
        string memory json = vm.readFile(path);

        d.chainId = chainId;
        d.poolManager = json.readAddress(".poolManager");
        d.stateView = json.readAddress(".stateView");
        d.auctionServiceManager = json.readAddress(".auctionServiceManager");
        d.hook = json.readAddress(".hook");
        d.settler = json.readAddress(".settler");
        d.currency0 = json.readAddress(".pool.currency0");
        d.currency1 = json.readAddress(".pool.currency1");
        d.currency0Decimals = uint8(json.readUint(".pool.currency0Decimals"));
        d.currency1Decimals = uint8(json.readUint(".pool.currency1Decimals"));
        d.fee = uint24(json.readUint(".pool.fee"));
        d.tickSpacing = int24(json.readInt(".pool.tickSpacing"));
        d.poolId = json.readBytes32(".pool.poolId");
    }

    /// @dev Writes `deployments/<chainId>.json` in the exact shape the backend config loader expects.
    function writeDeployment(Vm vm, Deployment memory d) internal {
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", d.chainId);
        vm.serializeAddress(obj, "poolManager", d.poolManager);
        vm.serializeAddress(obj, "stateView", d.stateView);
        vm.serializeAddress(obj, "auctionServiceManager", d.auctionServiceManager);
        vm.serializeAddress(obj, "hook", d.hook);
        vm.serializeAddress(obj, "settler", d.settler);

        // Nested "pool" object, mirroring config/networks and the artifact schema.
        string memory poolObj = "pool";
        vm.serializeAddress(poolObj, "currency0", d.currency0);
        vm.serializeAddress(poolObj, "currency1", d.currency1);
        vm.serializeUint(poolObj, "currency0Decimals", d.currency0Decimals);
        vm.serializeUint(poolObj, "currency1Decimals", d.currency1Decimals);
        vm.serializeUint(poolObj, "fee", d.fee);
        vm.serializeInt(poolObj, "tickSpacing", d.tickSpacing);
        string memory poolJson = vm.serializeBytes32(poolObj, "poolId", d.poolId);

        vm.serializeString(obj, "pool", poolJson);
        string memory finalJson = vm.serializeUint(obj, "deployedBlock", d.deployedBlock);

        string memory outPath =
            string.concat(repoRoot(vm), "/deployments/", vm.toString(d.chainId), ".json");
        vm.writeJson(finalJson, outPath);
    }
}
