// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IPermissionController} from "eigenlayer-contracts/src/contracts/interfaces/IPermissionController.sol";
import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IStakeRegistry} from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";

import {AuctionServiceManager} from "../src/AuctionServiceManager.sol";
import {EigenAuctionHook} from "../src/EigenAuctionHook.sol";

/// @title Deploy
/// @author ohMySol
/// @notice Deploys the AVS-secured arbitrage-auction system: the `AuctionServiceManager` (behind an
/// ERC1967 proxy) and the `EigenAuctionHook` (at a CREATE2 address mined for its permission flags).
///
/// Required env vars:
///   POOL_MANAGER          — Uniswap V4 PoolManager address
///   THRESHOLD             — minimum unique operator signatures to commit a winner
///   OWNER                 — AVS owner (defaults to the broadcaster)
///   REWARDS_INITIATOR     — AVS rewards initiator (defaults to the broadcaster)
/// Optional EigenLayer core (default address(0) where the slashing upgrade is absent):
///   AVS_DIRECTORY, REWARDS_COORDINATOR, REGISTRY_COORDINATOR, STAKE_REGISTRY,
///   PERMISSION_CONTROLLER, ALLOCATION_MANAGER
///
/// Run: `forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast`
contract Deploy is Script {
    /// @dev Canonical CREATE2 deployer proxy used by `forge script` for salted deployments.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (AuctionServiceManager avs, EigenAuctionHook hook) {
        vm.startBroadcast();
        avs = _deployAvs();
        hook = _deployHook(address(avs));
        vm.stopBroadcast();

        console2.log("AuctionServiceManager (proxy):", address(avs));
        console2.log("EigenAuctionHook:            ", address(hook));
    }

    /// @dev Deploys the AVS implementation and its initialised ERC1967 proxy. EigenLayer core
    /// addresses are read inline (defaulting to address(0)) to keep the stack shallow.
    function _deployAvs() internal returns (AuctionServiceManager avs) {
        AuctionServiceManager impl = new AuctionServiceManager(
            IAVSDirectory(vm.envOr("AVS_DIRECTORY", address(0))),
            IRewardsCoordinator(vm.envOr("REWARDS_COORDINATOR", address(0))),
            ISlashingRegistryCoordinator(vm.envOr("REGISTRY_COORDINATOR", address(0))),
            IStakeRegistry(vm.envOr("STAKE_REGISTRY", address(0))),
            IPermissionController(vm.envOr("PERMISSION_CONTROLLER", address(0))),
            IAllocationManager(vm.envOr("ALLOCATION_MANAGER", address(0))),
            vm.envUint("THRESHOLD")
        );

        bytes memory initData = abi.encodeCall(
            AuctionServiceManager.initialize,
            (vm.envOr("OWNER", msg.sender), vm.envOr("REWARDS_INITIATOR", msg.sender))
        );
        avs = AuctionServiceManager(address(new ERC1967Proxy(address(impl), initData)));
    }

    /// @dev Mines a hook address carrying the required permission flags, then deploys via CREATE2.
    function _deployHook(address avsAddr) internal returns (EigenAuctionHook hook) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        address hookOwner = vm.envOr("OWNER", msg.sender);
        bytes memory args = abi.encode(poolManager, avsAddr, hookOwner);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(EigenAuctionHook).creationCode, args);

        hook = new EigenAuctionHook{salt: salt}(poolManager, avsAddr, hookOwner);
        require(address(hook) == hookAddr, "Deploy: hook address mismatch");
    }
}
