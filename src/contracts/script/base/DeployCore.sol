// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IAllocationManager, IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IPermissionController} from "eigenlayer-contracts/src/contracts/interfaces/IPermissionController.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IStakeRegistry} from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";

import {AuctionServiceManager} from "../../src/AuctionServiceManager.sol";
import {EigenAuctionHook} from "../../src/EigenAuctionHook.sol";
import {Settler} from "../../src/Settler.sol";
import {ConstantsLib} from "../../src/libraries/ConstantsLib.sol";
import {ConfigLib, NetworkConfig, Deployment} from "../libs/ConfigLib.sol";

/// @title DeployCore
/// @author ohMySol
/// @notice Shared, config-driven deployment logic for the AVS-secured LVR auction.
/// Concrete scripts (`Deploy`, `DeployTestnet`) inherit this and differ only
/// in how the token pair is sourced and whether demo liquidity is seeded — every address comes from
/// `config/networks/<chainId>.json`, so there are no chain-specific branches here.
///
/// Broadcast scoping is the caller's responsibility: wrap `_deployProtocol`/pool-init in the deployer's
/// `vm.startBroadcast(deployerPk)` and `_registerOperator` in the operator's broadcast.
abstract contract DeployCore is Script {
    using PoolIdLibrary for PoolKey;

    /// @notice The three protocol contracts produced by a deployment.
    struct ProtocolContracts {
        AuctionServiceManager avs;
        EigenAuctionHook hook;
        Settler settler;
    }

    /// @dev Hook permission flags this hook encodes in its address.
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG |
        Hooks.AFTER_SWAP_FLAG |
        Hooks.AFTER_ADD_LIQUIDITY_FLAG |
        Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
    );
    
    /// @dev Deploys the three contracts (AVS proxy, mined-address hook, Settler) and wires them: points
    /// the hook at the Settler, registers AVS metadata, and creates the slashable operator set. Must run
    /// inside the deployer's broadcast (the deployer becomes the AVS + hook owner).
    function _deployProtocol(NetworkConfig memory config, address owner) internal returns (ProtocolContracts memory protocol) {
        protocol.avs = _deployAvs(config, owner);
        protocol.hook = _deployHook(config.poolManager, address(protocol.avs), owner);
        protocol.settler = new Settler(config.poolManager, address(protocol.avs));
        protocol.hook.setSettler(address(protocol.settler));
        // AllocationManager requires AVS metadata to exist before an operator set can be created.
        protocol.avs.registerAvsMetadata("https://eigen-auction.local/avs.json");
        _createOperatorSet(protocol.avs, config.stakeStrategy);
    }

    /// @dev Assembles the PoolKey from config + a resolved token pair and the deployed hook.
    function _poolKey(
        NetworkConfig memory config, 
        address hook, 
        Currency currency0, 
        Currency currency1
    ) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0, 
            currency1: currency1, 
            fee: config.fee, 
            tickSpacing: config.tickSpacing, 
            hooks: IHooks(hook)
        });
    }

    /// @dev Registers `operator` as an EigenLayer operator and into this AVS's operator set — the
    /// membership `commitWinner` checks. Must run inside the operator's broadcast.
    /// On a mainnet fork the operator may already be registered (mainnet state is preserved); the
    /// `isOperator` guard skips re-registration so the script doesn't revert with ActivelyDelegated.
    function _registerOperator(NetworkConfig memory config, address avs, address operator) internal {
        if (!IDelegationManager(config.delegationManager).isOperator(operator)) {
            IDelegationManager(config.delegationManager).registerAsOperator(address(0), 0, "");
        }
        uint32[] memory setIds = new uint32[](1);
        setIds[0] = ConstantsLib.OPERATOR_SET_ID;
        
        IAllocationManager(config.allocationManager).registerForOperatorSets(
            operator,
            IAllocationManagerTypes.RegisterParams({
                avs: avs, 
                operatorSetIds: setIds, 
                data: ""
            })
        );
    }

    /// @dev Writes deployments/<chainId>.json — the single artifact the backend/frontend read — and logs
    /// the deployed addresses.
    function _writeDeployment(
        NetworkConfig memory config, 
        PoolKey memory key, 
        ProtocolContracts memory protocol, 
        uint8 decimals0, 
        uint8 decimals1
    ) internal {
        Deployment memory deployment = Deployment({
            chainId: block.chainid,
            poolManager: config.poolManager,
            stateView: config.stateView,
            auctionServiceManager: address(protocol.avs),
            hook: address(protocol.hook),
            settler: address(protocol.settler),
            currency0: Currency.unwrap(key.currency0),
            currency1: Currency.unwrap(key.currency1),
            currency0Decimals: decimals0,
            currency1Decimals: decimals1,
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            poolId: PoolId.unwrap(key.toId()),
            deployedBlock: block.number
        });
        ConfigLib.writeDeployment(vm, deployment);

        console2.log("currency0: ", Currency.unwrap(key.currency0));
        console2.log("currency1: ", Currency.unwrap(key.currency1));
        console2.log("AuctionServiceManager: ", address(protocol.avs));
        console2.log("EigenAuctionHook: ", address(protocol.hook));
        console2.log("Settler: ", address(protocol.settler));
    }

    /* INTERNAL BUILDING BLOCKS */

    /// @dev Deploy the AVS implementation wired to the live EL core, behind an initialised proxy.
    function _deployAvs(NetworkConfig memory config, address owner) internal returns (AuctionServiceManager avs) {
        AuctionServiceManager impl = new AuctionServiceManager(
            IAVSDirectory(config.avsDirectory),
            IRewardsCoordinator(config.rewardsCoordinator),
            ISlashingRegistryCoordinator(address(0)),
            IStakeRegistry(address(0)),
            IPermissionController(config.permissionController),
            IAllocationManager(config.allocationManager),
            config.threshold
        );
        bytes memory initData = abi.encodeCall(AuctionServiceManager.initialize, (owner, owner));
        avs = AuctionServiceManager(address(new ERC1967Proxy(address(impl), initData)));
    }

    /// @dev Mine a hook address carrying the required permission flags, then deploy via CREATE2.
    function _deployHook(address poolManager, address avs, address owner) internal returns (EigenAuctionHook hook) {
        bytes memory args = abi.encode(poolManager, avs, owner);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY, 
            HOOK_FLAGS, 
            type(EigenAuctionHook).creationCode, 
            args
        );

        hook = new EigenAuctionHook{salt: salt}(poolManager, avs, owner);
        
        require(address(hook) == hookAddr, "DeployCore: hook address mismatch");
    }

    /// @dev Create the AVS's operator set, slashable against the configured stake strategy.
    function _createOperatorSet(AuctionServiceManager avs, address stakeStrategy) internal {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(stakeStrategy);
        avs.createOperatorSet(strategies);
    }
}
