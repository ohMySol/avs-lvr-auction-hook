// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {
    IAllocationManager,
    IAllocationManagerTypes
} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
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

import {AuctionServiceManager} from "../src/AuctionServiceManager.sol";
import {EigenAuctionHook} from "../src/EigenAuctionHook.sol";
import {Settler} from "../src/Settler.sol";
import {ConstantsLib} from "../src/libraries/ConstantsLib.sol";
import {ConfigLib, NetworkConfig, Deployment} from "./libs/ConfigLib.sol";

/// @title DeployFork
/// @author ohMySol
/// @notice Fork-mode deployment: reuses the forked chain's Uniswap V4 + EigenLayer core (read from
/// config/networks/<chainId>.json) and deploys only this project's contracts — AuctionServiceManager
/// (proxy), EigenAuctionHook (mined CREATE2 address), and Settler. It then creates the AVS operator
/// set, registers the operator into it, initialises the pool, and writes deployments/<chainId>.json
/// for the backend/frontend.
///
/// Out of scope here (node-level, not broadcast-safe): funding the deployer/operator with tokens and
/// seeding LP liquidity. forge cheatcodes (deal/prank) do not persist to a live anvil node under
/// --broadcast, so those run from the Makefile via anvil RPC cheats before SeedLiquidity.s.sol.
///
/// Required env:
///   DEPLOYER_PK  — deploys contracts; becomes AVS owner + pool initialiser
///   OPERATOR_PK  — the AVS operator that registers into the operator set
/// Optional:
///   DEPLOY_SQRT_PRICE_X96 — pool start price (defaults to ~the live market for the configured pair)
///
/// Run: `forge script script/DeployFork.s.sol --rpc-url $RPC_URL --broadcast`
contract DeployFork is Script {
    using PoolIdLibrary for PoolKey;

    /// @dev Canonical CREATE2 deployer proxy used by forge for salted deployments.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Hook permission flags this hook encodes in its address.
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
    );

    function run() external {
        NetworkConfig memory cfg = ConfigLib.readNetwork(vm, block.chainid);
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        uint256 operatorPk = vm.envUint("OPERATOR_PK");
        address deployer = vm.addr(deployerPk);
        address operator = vm.addr(operatorPk);

        // Step 1 — deploy this project's contracts and configure them (broadcaster == AVS owner).
        vm.startBroadcast(deployerPk);
        AuctionServiceManager avs = _deployAvs(cfg, deployer);
        EigenAuctionHook hook = _deployHook(cfg.poolManager, address(avs), deployer);
        Settler settler = new Settler(cfg.poolManager, address(avs));
        hook.setSettler(address(settler));
        // AllocationManager requires AVS metadata to exist before an operator set can be created.
        avs.registerAvsMetadata("https://eigen-auction.local/avs.json");
        _createOperatorSet(avs, cfg.stakeStrategy);

        PoolKey memory key = _poolKey(cfg, address(hook));
        uint160 startSqrtPriceX96 = uint160(vm.envOr("DEPLOY_SQRT_PRICE_X96", _defaultSqrtPrice()));
        IPoolManager(cfg.poolManager).initialize(key, startSqrtPriceX96);
        vm.stopBroadcast();

        // Step 2 — register the operator into the AVS operator set (broadcaster == operator).
        // registerForOperatorSets calls back into AuctionServiceManager.registerOperator (our
        // IAVSRegistrar), which is why that hook had to exist. Membership is what commitWinner checks.
        vm.startBroadcast(operatorPk);
        IDelegationManager(cfg.delegationManager).registerAsOperator(address(0), 0, "");
        _registerForOperatorSet(cfg.allocationManager, address(avs), operator);
        vm.stopBroadcast();

        // Step 3 — persist the artifact the backend/frontend read.
        _writeArtifact(cfg, key, address(avs), address(hook), address(settler));

        console2.log("AuctionServiceManager:", address(avs));
        console2.log("EigenAuctionHook:     ", address(hook));
        console2.log("Settler:              ", address(settler));
        console2.log("Operator registered:  ", operator);
    }

    /// @dev Deploy the AVS implementation wired to the forked EL core, behind an initialised proxy.
    function _deployAvs(NetworkConfig memory cfg, address owner) internal returns (AuctionServiceManager avs) {
        AuctionServiceManager impl = new AuctionServiceManager(
            IAVSDirectory(cfg.avsDirectory),
            IRewardsCoordinator(cfg.rewardsCoordinator),
            ISlashingRegistryCoordinator(address(0)),
            IStakeRegistry(address(0)),
            IPermissionController(cfg.permissionController),
            IAllocationManager(cfg.allocationManager),
            cfg.threshold
        );
        bytes memory initData = abi.encodeCall(AuctionServiceManager.initialize, (owner, owner));
        avs = AuctionServiceManager(address(new ERC1967Proxy(address(impl), initData)));
    }

    /// @dev Mine a hook address carrying the required permission flags, then deploy via CREATE2.
    function _deployHook(address poolManager, address avs, address owner)
        internal
        returns (EigenAuctionHook hook)
    {
        bytes memory args = abi.encode(poolManager, avs, owner);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(EigenAuctionHook).creationCode, args);
        hook = new EigenAuctionHook{salt: salt}(poolManager, avs, owner);
        require(address(hook) == hookAddr, "DeployFork: hook address mismatch");
    }

    /// @dev Create the AVS's operator set, slashable against the configured stake strategy.
    function _createOperatorSet(AuctionServiceManager avs, address stakeStrategy) internal {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(stakeStrategy);
        avs.createOperatorSet(strategies);
    }

    /// @dev Register the operator into OPERATOR_SET_ID of this AVS.
    function _registerForOperatorSet(address allocationManager, address avs, address operator) internal {
        uint32[] memory setIds = new uint32[](1);
        setIds[0] = ConstantsLib.OPERATOR_SET_ID;
        IAllocationManager(allocationManager).registerForOperatorSets(
            operator,
            IAllocationManagerTypes.RegisterParams({avs: avs, operatorSetIds: setIds, data: ""})
        );
    }

    /// @dev Assemble the PoolKey from config + the mined hook. V4 requires currency0 < currency1.
    function _poolKey(NetworkConfig memory cfg, address hook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(cfg.currency0),
            currency1: Currency.wrap(cfg.currency1),
            fee: cfg.fee,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(hook)
        });
    }

    /// @dev Default pool start price for USDC(6)/WETH(18), already decimal-adjusted.
    /// Derivation: price_raw = sqrtP/2^96 squared = 5e8 = (1/2000) * 10^(18-6) ⇒ ~2000 USDC per WETH.
    /// Override with DEPLOY_SQRT_PRICE_X96 for a different pair/price. Keep it distinct from the
    /// off-chain FIXED_PRICE target so there is an arb gap for the demo to close.
    function _defaultSqrtPrice() internal pure returns (uint256) {
        return 1771595571142957166518320255467520;
    }

    function _writeArtifact(
        NetworkConfig memory cfg,
        PoolKey memory key,
        address avs,
        address hook,
        address settler
    ) internal {
        Deployment memory d = Deployment({
            chainId: block.chainid,
            poolManager: cfg.poolManager,
            stateView: cfg.stateView,
            auctionServiceManager: avs,
            hook: hook,
            settler: settler,
            currency0: cfg.currency0,
            currency1: cfg.currency1,
            currency0Decimals: cfg.currency0Decimals,
            currency1Decimals: cfg.currency1Decimals,
            fee: cfg.fee,
            tickSpacing: cfg.tickSpacing,
            poolId: PoolId.unwrap(key.toId()),
            deployedBlock: block.number
        });
        ConfigLib.writeDeployment(vm, d);
    }
}
