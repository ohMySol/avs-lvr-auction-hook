// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {DeployCore} from "./base/DeployCore.sol";
import {ConfigLib, NetworkConfig} from "./libs/ConfigLib.sol";
import {FaucetToken} from "./helpers/FaucetToken.sol";

/// @dev Minimal ERC20 approve surface for seeding liquidity through the hook.
interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title DeployTestnet
/// @author ohMySol
/// @notice Public-testnet deployment (e.g. Sepolia). Same protocol deployment as `Deploy`
/// (via the shared `DeployCore`), but additionally deploys two FaucetTokens for the pool, mints demo
/// balances, starts the pool at 1:1, and seeds an in-range LP straight through the hook so the venue is
/// liquid and the deployer shows up on the dashboard with a claimable position.
///
/// Never uses node cheats — demo balances come from the mintable FaucetTokens, and any wallet can top
/// up later via `FaucetToken.faucet()`.
///
/// Required env:
///   DEPLOYER_PK  — deploys contracts + tokens; AVS owner, pool initialiser, and the seeded LP
///   OPERATOR_PK  — the AVS operator that registers into the operator set
///
/// Run: `forge script script/DeployTestnet.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast`
contract DeployTestnet is DeployCore {
    /// @dev sqrt(1) * 2**96 — the pool starts at 1:1 and the off-chain FIXED_PRICE supplies the arb
    /// gap, so the price math is independent of which FaucetToken sorts as currency0.
    uint160 constant START_SQRT_PRICE_X96 = 79228162514264337593543950336;

    // Full usable range for tickSpacing 60, plus a generous seed and mint so the pool is liquid.
    int24 constant SEED_TICK_LOWER = -887220;
    int24 constant SEED_TICK_UPPER = 887220;
    uint128 constant SEED_LIQUIDITY = 100e18;
    uint256 constant MINT_AMOUNT = 1_000_000e18;

    function run() external {
        NetworkConfig memory config = ConfigLib.readNetwork(vm, block.chainid);
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        uint256 operatorPk = vm.envUint("OPERATOR_PK");
        address deployer = vm.addr(deployerPk);
        address operator = vm.addr(operatorPk);

        // Step 1 — tokens + protocol + pool + seeded LP (deployer == AVS/hook owner and the LP).
        vm.startBroadcast(deployerPk);
        (
            Currency currency0, 
            Currency currency1, 
            uint8 decimals0, 
            uint8 decimals1
        ) = _resolveTokens(config, deployer, operator);

        ProtocolContracts memory protocol = _deployProtocol(config, deployer);
        PoolKey memory key = _poolKey(config, address(protocol.hook), currency0, currency1);
        IPoolManager(config.poolManager).initialize(key, START_SQRT_PRICE_X96);

        // Seed an in-range LP through the hook itself so reward attribution stays intact.
        IERC20Approve(Currency.unwrap(currency0)).approve(address(protocol.hook), type(uint256).max);
        IERC20Approve(Currency.unwrap(currency1)).approve(address(protocol.hook), type(uint256).max);
        protocol.hook.addLiquidity(key, SEED_TICK_LOWER, SEED_TICK_UPPER, SEED_LIQUIDITY);
        vm.stopBroadcast();

        // Step 2 — register the operator into the AVS operator set.
        vm.startBroadcast(operatorPk);
        _registerOperator(config, address(protocol.avs), operator);
        vm.stopBroadcast();

        // Step 3 — persist the artifact the backend/frontend read.
        _writeDeployment(config, key, protocol, decimals0, decimals1);
    }

    /// @dev Returns the pool's currency pair. When the config leaves the pair unset (zero), deploys two
    /// FaucetTokens, mints demo balances to the deployer + operator, and returns them address-sorted
    /// (V4 requires currency0 < currency1). When the config names real tokens, uses them verbatim.
    function _resolveTokens(NetworkConfig memory config, address deployer, address operator)
        internal
        returns (Currency currency0, Currency currency1, uint8 decimals0, uint8 decimals1)
    {
        if (config.currency0 != address(0) && config.currency1 != address(0)) {
            return (
                Currency.wrap(config.currency0),
                Currency.wrap(config.currency1),
                config.currency0Decimals,
                config.currency1Decimals
            );
        }

        FaucetToken a = new FaucetToken("Mock USDC", "mUSDC", 18, 10_000);
        FaucetToken b = new FaucetToken("Mock Ether", "mETH", 18, 10);
        (FaucetToken lowerToken, FaucetToken higherToken) = address(a) < address(b) ? (a, b) : (b, a);

        lowerToken.mint(deployer, MINT_AMOUNT);
        lowerToken.mint(operator, MINT_AMOUNT);
        higherToken.mint(deployer, MINT_AMOUNT);
        higherToken.mint(operator, MINT_AMOUNT);

        return (Currency.wrap(address(lowerToken)), Currency.wrap(address(higherToken)), 18, 18);
    }
}
