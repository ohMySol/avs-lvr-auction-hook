// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IEigenAuctionHookLike {
    function claimRewards(PoolKey calldata key, int24 tickLower, int24 tickUpper, bytes32 salt) external;
}

/// @title DemoLP
/// @notice Minimal liquidity provider for the end-to-end demo. `EigenAuctionHook` keys reward
/// accounting by the `modifyLiquidity` caller, so an EOA can't be the tracked LP — this contract is.
/// It adds liquidity from its own token balance and forwards claimed rewards to its owner, letting
/// the demo show LPs actually receiving their share of the captured LVR.
contract DemoLP is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable owner;

    error NotOwner();
    error NotPoolManager();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Add liquidity to `key`. This contract must already hold enough currency0/currency1.
    function addLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        onlyOwner
    {
        poolManager.unlock(abi.encode(key, tickLower, tickUpper, liquidityDelta));
    }

    /// @notice Claim accrued rewards from the hook and forward exactly the claimed amount to owner.
    function claim(PoolKey calldata key, address hook, int24 tickLower, int24 tickUpper) external onlyOwner {
        IERC20 t0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(key.currency1));
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));

        IEigenAuctionHookLike(hook).claimRewards(key, tickLower, tickUpper, bytes32(0));

        uint256 r0 = t0.balanceOf(address(this)) - b0;
        uint256 r1 = t1.balanceOf(address(this)) - b1;
        if (r0 > 0) t0.transfer(owner, r0);
        if (r1 > 0) t1.transfer(owner, r1);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
            abi.decode(data, (PoolKey, int24, int24, int256));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    /// @dev Pay an owed principal (negative delta) from this contract; take any credit (positive).
    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(poolManager), uint256(uint128(-amount)));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
