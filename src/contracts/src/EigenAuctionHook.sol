// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";

import {IEigenAuctionHook, Position, LiquidityCallback} from "./interfaces/IEigenAuctionHook.sol";
import {IAuctionServiceManager} from "./interfaces/IAuctionServiceManager.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {RewardGrowthLib} from "./libraries/RewardGrowthLib.sol";
import {ConstantsLib} from "./libraries/ConstantsLib.sol";

/// @title EigenAuctionHook
/// @author ohMySol
/// @notice Uniswap V4 hook that locks the pool to a single settler contract and distributes
/// arb-auction proceeds to in-range LPs.
///
/// Pool lock
/// ----------
/// Once `setSettler` is called, only `settler` may initiate swaps. Any other caller is rejected
/// unless `FALLBACK_PERIOD` blocks have elapsed with no settlement — at which point the pool
/// re-opens to prevent a permanent liveness failure.
///
/// Reward distribution
/// -------------------
/// The settler pre-funds `rewardAmount` of currency0 into the pool manager before executing the
/// arb swap, and encodes `(isArb=true, rewardAmount, expectedLiquidity)` in hookData. This hook
/// collects the pre-funded amount in `afterSwap` and folds it into a per-tick reward-growth
/// accumulator (always in currency0). If `expectedLiquidity > 0` and the actual pool liquidity
/// differs, the hook reverts — this is the JIT guard: a JIT add changes liquidity between the
/// operator's snapshot and the swap, making the tx revert.
contract EigenAuctionHook is BaseHook, IEigenAuctionHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    /* IMMUTABLES */

    /// @inheritdoc IEigenAuctionHook
    IAuctionServiceManager public immutable avs;

    /// @inheritdoc IEigenAuctionHook
    address public immutable owner;

    /* POOL LOCK STATE */

    /// @inheritdoc IEigenAuctionHook
    address public settler;

    /// @inheritdoc IEigenAuctionHook
    uint256 public lastSettledBlock;

    /* REWARD ACCOUNTING STORAGE */

    /// @inheritdoc IEigenAuctionHook
    mapping(PoolId => uint256) public rewardGrowthGlobalX128;

    /// @dev positionKey => position. Keyed by `keccak256(poolId, owner, lower, upper, salt)`.
    mapping(bytes32 => Position) private _positions;

    /// @dev Per-tick reward-growth outside values — initialized when a tick is first used as a
    /// position boundary and flipped on every arb-swap crossing. Mirrors the V3 feeGrowthOutside
    /// model. Rewards are always in currency0 so a single uint256 per tick suffices.
    mapping(PoolId => mapping(int24 => uint256)) private _tickGrowthOutside;

    /// @dev All unique tick values registered as position boundaries in this pool.
    mapping(PoolId => int24[]) private _tickBoundaries;

    /// @dev Guards _tickBoundaries insertion so each tick is pushed at most once per pool.
    mapping(PoolId => mapping(int24 => bool)) private _tickBoundaryRegistered;

    /// @dev Pool tick snapshotted in `_beforeSwap` for the most recent arb-flagged swap.
    mapping(PoolId => int24) private _priorTick;

    /* CONSTRUCTOR */

    /// @param _poolManager Address of the Uniswap V4 pool manager.
    /// @param _avs Address of the auction service manager that commits winners.
    /// @param _owner Address permitted to call `setSettler` once.
    constructor(address _poolManager, address _avs, address _owner) BaseHook(IPoolManager(_poolManager)) {
        if (_avs == address(0) || _owner == address(0)) revert ErrorsLib.EigenAuctionHook_ZeroAddress();
        avs = IAuctionServiceManager(_avs);
        owner = _owner;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /* POOL LOCK */

    /// @inheritdoc IEigenAuctionHook
    function setSettler(address _settler) external {
        if (msg.sender != owner) revert ErrorsLib.EigenAuctionHook_Unauthorized();
        if (_settler == address(0)) revert ErrorsLib.EigenAuctionHook_ZeroAddress();
        if (settler != address(0)) revert ErrorsLib.EigenAuctionHook_SettlerAlreadySet();
        settler = _settler;
        lastSettledBlock = block.number;
        emit EventsLib.SettlerSet(_settler);
    }

    /// @inheritdoc IEigenAuctionHook
    function recordSettlement() external {
        if (msg.sender != settler) revert ErrorsLib.EigenAuctionHook_NotSettler();
        lastSettledBlock = block.number;
    }

    /* LP LIQUIDITY */

    /// @inheritdoc IEigenAuctionHook
    function addLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        if (liquidity == 0) revert ErrorsLib.EigenAuctionHook_ZeroLiquidity();
        poolManager.unlock(
            abi.encode(
                LiquidityCallback({
                    key: key,
                    lp: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidity))
                })
            )
        );
        emit EventsLib.LiquidityAdded(key.toId(), msg.sender, tickLower, tickUpper, liquidity);
    }

    /// @inheritdoc IEigenAuctionHook
    function removeLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        if (liquidity == 0) revert ErrorsLib.EigenAuctionHook_ZeroLiquidity();
        poolManager.unlock(
            abi.encode(
                LiquidityCallback({
                    key: key,
                    lp: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(uint256(liquidity))
                })
            )
        );
        emit EventsLib.LiquidityRemoved(key.toId(), msg.sender, tickLower, tickUpper, liquidity);
    }

    /// @notice Pool-manager unlock callback for the hook's own LP add/remove flow.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        LiquidityCallback memory cb = abi.decode(data, (LiquidityCallback));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            cb.key,
            ModifyLiquidityParams({
                tickLower: cb.tickLower,
                tickUpper: cb.tickUpper,
                liquidityDelta: cb.liquidityDelta,
                salt: bytes32(uint256(uint160(cb.lp)))
            }),
            ""
        );

        // V4 skips a hook's own liquidity callbacks on self-calls, so the reward ledger is updated
        // inline here keyed to the real LP.
        PoolId poolId = cb.key.toId();
        _recordLiquidity(poolId, cb.lp, cb.tickLower, cb.tickUpper, bytes32(0), cb.liquidityDelta);

        // Auto-pay accrued rewards on removal so the LP never needs a separate claim step.
        if (cb.liquidityDelta < 0) {
            _payRewards(poolId, _positionKey(poolId, cb.lp, cb.tickLower, cb.tickUpper, bytes32(0)), cb.key.currency0, cb.lp);
        }

        _settlePrincipal(cb.key.currency0, delta.amount0(), cb.lp);
        _settlePrincipal(cb.key.currency1, delta.amount1(), cb.lp);
        return "";
    }

    function _settlePrincipal(Currency currency, int128 amount, address lp) private {
        if (amount < 0) {
            poolManager.sync(currency);
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(lp, address(poolManager), uint256(uint128(-amount)));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, lp, uint256(uint128(amount)));
        }
    }

    /// @inheritdoc IEigenAuctionHook
    function earned(
        PoolKey calldata key,
        address owner_,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint256 amount) {
        PoolId poolId = key.toId();
        Position storage pos = _positions[_positionKey(poolId, owner_, tickLower, tickUpper, salt)];
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        uint256 insideX128 = _growthInsideWithTick(poolId, currentTick, tickLower, tickUpper);
        amount = pos.owed + RewardGrowthLib.rewardsOf(insideX128, pos.lastGrowthInsideX128, pos.liquidity);
    }

    /// @inheritdoc IEigenAuctionHook
    function positionLiquidity(
        PoolKey calldata key,
        address owner_,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view override returns (uint128) {
        return _positions[_positionKey(key.toId(), owner_, tickLower, tickUpper, salt)].liquidity;
    }

    /* SWAP HOOKS */

    /// @dev Allows swaps from `settler` unconditionally; allows public swaps only after the
    /// fallback period elapses or before a settler is registered. For arb-flagged settler swaps,
    /// snapshots the current tick so `_afterSwap` can detect crossed position boundaries.
    /// @dev JIT guard and tick snapshot for arb-flagged swaps.
    ///
    /// The JIT check is done here (pre-swap) rather than in `_afterSwap` because pool liquidity
    /// legitimately changes when a swap crosses tick boundaries. Checking pre-swap ensures we are
    /// comparing against the liquidity the operator read before submitting the transaction.
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        (bool isArb, uint256 rewardAmount, uint256 expectedLiquidity) = _decodeArbHookData(hookData);

        // Tick snapshot and JIT guard apply to all arb-flagged swaps regardless of which access
        // control path allows them.
        if (isArb) {
            PoolId poolId = key.toId();
            (, int24 tick,,) = poolManager.getSlot0(poolId);
            _priorTick[poolId] = tick;

            // JIT guard: if the operator committed to a pre-swap pool liquidity, reject any JIT
            // add that changed it between the operator's snapshot and this pre-swap hook.
            if (rewardAmount > 0 && expectedLiquidity > 0) {
                if (poolManager.getLiquidity(poolId) != uint128(expectedLiquidity)) {
                    revert ErrorsLib.EigenAuctionHook_LiquidityMismatch();
                }
            }
        }

        if (sender == settler) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        if (settler == address(0) || block.number > lastSettledBlock + ConstantsLib.FALLBACK_PERIOD) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        revert ErrorsLib.EigenAuctionHook_NotSettler();
    }

    /// @dev For arb-flagged swaps: decodes `(isArb, rewardAmount, expectedLiquidity)` from hookData.
    ///
    /// JIT guard: if `expectedLiquidity > 0` and the actual pool liquidity differs, the tx reverts —
    /// a JIT add between the operator's snapshot and the swap is detected and rejected.
    ///
    /// Tick-outside accumulators are flipped for any registered position boundary crossed, BEFORE
    /// adding the new reward to the global accumulator. This keeps `growthInside` correct for
    /// narrow positions whose price range the arb exited.
    ///
    /// If `rewardAmount > 0`, the hook folds the reward into `rewardGrowthGlobalX128`. The reward
    /// must have been transferred directly to this contract by the Settler before the swap.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        (bool isArb, uint256 rewardAmount,) = _decodeArbHookData(hookData);
        if (!isArb) return (this.afterSwap.selector, 0);

        PoolId poolId = key.toId();
        (, int24 newTick,,) = poolManager.getSlot0(poolId);

        // Always cross ticks before any early return — even zero-reward arbs must flip outside
        // accumulators, because the arb may have exited the last LP's range.
        _crossTicks(poolId, _priorTick[poolId], newTick);

        if (rewardAmount == 0) return (this.afterSwap.selector, 0);

        // Post-swap active liquidity — may differ from the pre-swap value if the swap crossed
        // tick boundaries. If nobody is in range at the post-arb tick, skip distribution.
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        if (poolLiquidity == 0) return (this.afterSwap.selector, 0);

        // The reward was transferred directly to this contract by the Settler/caller before the
        // swap (outside V4 flash accounting). We just update the accumulator here. Added after
        // crossing ticks so it accrues only to positions in-range at the post-arb price.
        unchecked {
            rewardGrowthGlobalX128[poolId] += FullMath.mulDiv(rewardAmount, FixedPoint128.Q128, poolLiquidity);
        }

        emit EventsLib.ArbitrageSettled(poolId, sender, rewardAmount);
        return (this.afterSwap.selector, 0);
    }

    /* LIQUIDITY HOOKS */

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _recordLiquidity(key.toId(), sender, params.tickLower, params.tickUpper, params.salt, params.liquidityDelta);
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        _recordLiquidity(poolId, sender, params.tickLower, params.tickUpper, params.salt, params.liquidityDelta);
        _payRewards(poolId, _positionKey(poolId, sender, params.tickLower, params.tickUpper, params.salt), key.currency0, sender);
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /* INTERNAL HELPERS */

    /// @dev Transfers any settled-but-unpaid rewards for `pk` directly to `lp` and emits the event.
    /// No-op when nothing is owed.
    function _payRewards(PoolId poolId, bytes32 pk, Currency currency0, address lp) private {
        uint256 owed = _positions[pk].owed;
        if (owed == 0) return;
        _positions[pk].owed = 0;
        currency0.transfer(lp, owed);
        emit EventsLib.RewardsClaimed(poolId, lp, owed);
    }

    /// @dev Records a liquidity change in the reward ledger and registers tick boundaries for
    /// outside-accumulator tracking. Shared by `unlockCallback` (self-calls) and the after-liquidity
    /// hooks (external-router calls).
    function _recordLiquidity(
        PoolId poolId,
        address owner_,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        int256 liquidityDelta
    ) private {
        _updatePosition(poolId, owner_, tickLower, tickUpper, salt, liquidityDelta);
        if (liquidityDelta > 0) {
            _registerTickBoundary(poolId, tickLower);
            _registerTickBoundary(poolId, tickUpper);
        }
    }

    /// @dev Settles accrued rewards into `owed`, then applies the liquidity delta.
    function _updatePosition(
        PoolId poolId,
        address owner_,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        int256 liquidityDelta
    ) private {
        bytes32 pk = _positionKey(poolId, owner_, tickLower, tickUpper, salt);
        _settle(poolId, pk, tickLower, tickUpper);
        Position storage pos = _positions[pk];
        if (liquidityDelta > 0) {
            pos.liquidity += uint128(uint256(liquidityDelta));
        } else if (liquidityDelta < 0) {
            uint128 dec = uint128(uint256(-liquidityDelta));
            pos.liquidity = pos.liquidity >= dec ? pos.liquidity - dec : 0;
        }
    }

    /// @dev Accrues rewards for `pk` into `owed` and advances the growth checkpoint.
    function _settle(PoolId poolId, bytes32 pk, int24 tickLower, int24 tickUpper) private {
        Position storage pos = _positions[pk];
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        uint256 insideX128 = _growthInsideWithTick(poolId, currentTick, tickLower, tickUpper);
        unchecked {
            pos.owed += RewardGrowthLib.rewardsOf(insideX128, pos.lastGrowthInsideX128, pos.liquidity);
        }
        pos.lastGrowthInsideX128 = insideX128;
    }

    /// @dev Returns reward growth accumulated inside [tickLower, tickUpper) using stored outside values.
    function _growthInsideWithTick(
        PoolId poolId,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper
    ) private view returns (uint256) {
        return RewardGrowthLib.growthInside(
            currentTick,
            tickLower,
            tickUpper,
            rewardGrowthGlobalX128[poolId],
            _tickGrowthOutside[poolId][tickLower],
            _tickGrowthOutside[poolId][tickUpper]
        );
    }

    /// @dev Registers a tick as a position boundary (once per pool). Initialises its outside
    /// accumulator following the V3 convention: if the current price is at or above the tick,
    /// the outside value equals the global accumulator (all historical growth is "below").
    function _registerTickBoundary(PoolId poolId, int24 tick) private {
        if (_tickBoundaryRegistered[poolId][tick]) return;
        _tickBoundaryRegistered[poolId][tick] = true;
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        if (currentTick >= tick) {
            _tickGrowthOutside[poolId][tick] = rewardGrowthGlobalX128[poolId];
        }
        _tickBoundaries[poolId].push(tick);
    }

    /// @dev Flips the outside accumulator for every registered tick boundary the arb swap crossed.
    /// Called before writing the new global growth so the flip is relative to the pre-reward state.
    function _crossTicks(PoolId poolId, int24 priorTick, int24 newTick) private {
        if (priorTick == newTick) return;
        bool movingDown = newTick < priorTick;
        uint256 g = rewardGrowthGlobalX128[poolId];
        int24[] storage boundaries = _tickBoundaries[poolId];
        uint256 n = boundaries.length;
        for (uint256 j; j < n; ++j) {
            int24 t = boundaries[j];
            bool crossed = movingDown
                ? (newTick < t && t <= priorTick)
                : (priorTick < t && t <= newTick);
            if (crossed) {
                unchecked {
                    _tickGrowthOutside[poolId][t] = g - _tickGrowthOutside[poolId][t];
                }
            }
        }
    }

    /// @dev Derives the storage key for a position.
    function _positionKey(
        PoolId poolId,
        address owner_,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            PoolId.unwrap(poolId), 
            owner_, 
            tickLower, 
            tickUpper, 
            salt
        ));
    }

    /// @dev Decodes arb hookData in one of two formats:
    ///   - 32 bytes:  abi.encode(bool isArb)                               — legacy/test format
    ///   - 96 bytes:  abi.encode(bool isArb, uint256 rewardAmount, uint256 expectedLiquidity)
    /// Unknown lengths return (false, 0, 0).
    function _decodeArbHookData(bytes calldata hookData)
        private pure
        returns (bool isArb, uint256 rewardAmount, uint256 expectedLiquidity)
    {
        if (hookData.length == 32) {
            isArb = abi.decode(hookData, (bool));
        } else if (hookData.length == 96) {
            (isArb, rewardAmount, expectedLiquidity) = abi.decode(hookData, (bool, uint256, uint256));
        }
    }
}
