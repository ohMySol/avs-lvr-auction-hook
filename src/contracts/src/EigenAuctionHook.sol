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
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

import {IEigenAuctionHook, Position, FreshLiquidity, LiquidityCallback} from "./interfaces/IEigenAuctionHook.sol";
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
/// The settler flags the top-of-block arb swap with `hookData = abi.encode(true)`. This hook
/// reads the committed bid from the AVS, skims it from the swap's output via `afterSwapReturnDelta`,
/// and folds it into a per-tick reward-growth accumulator. In-range LPs accumulate rewards
/// proportional to their liquidity and claim them with `claimRewards`.
contract EigenAuctionHook is BaseHook, IEigenAuctionHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

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
    mapping(PoolId => uint256[2]) public rewardGrowthGlobalX128;

    /// @dev positionKey => position. Keyed by `keccak256(poolId, owner, lower, upper, salt)`.
    mapping(bytes32 => Position) private _positions;

    /// @dev poolId => current-block fresh in-range liquidity snapshot (the JIT cohort).
    mapping(PoolId => FreshLiquidity) private _fresh;

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
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /* POOL LOCK */

    /// @inheritdoc IEigenAuctionHook
    function setSettler(address _settler) external {
        if (msg.sender != owner) revert ErrorsLib.EigenAuctionHook_Unauthorized();
        if (_settler == address(0)) revert ErrorsLib.EigenAuctionHook_ZeroAddress();
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
    /// @dev Only the pool manager may call this. The hook is the V4-level position owner, so positions
    /// are kept apart in the pool by using the LP address as the position salt; the LP is also passed
    /// through `hookData` so `_afterAddLiquidity`/`_afterRemoveLiquidity` attribute the reward ledger
    /// to the real owner rather than to the hook.
    /// @dev `onlyPoolManager` is inherited from `ImmutableState` (via `BaseHook`). The function is
    /// dispatched by the pool manager on selector, so it needs no interface inheritance.
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

        // V4 skips a hook's own liquidity callbacks on self-calls (the `noSelfCall` guard), so the
        // reward ledger is updated inline here — keyed to the real LP — rather than from
        // `_afterAddLiquidity`/`_afterRemoveLiquidity`, which only fire for external routers.
        _recordLiquidity(cb.key.toId(), cb.lp, cb.tickLower, cb.tickUpper, bytes32(0), cb.liquidityDelta);

        // `callerDelta` covers principal plus any swap fees accrued to the position. Pay the owed legs
        // from the LP (add) and forward credited legs to the LP (remove).
        _settlePrincipal(cb.key.currency0, delta.amount0(), cb.lp);
        _settlePrincipal(cb.key.currency1, delta.amount1(), cb.lp);
        return "";
    }

    /// @dev Settles one currency leg of an LP modify against the pool manager. A negative amount is
    /// owed to the pool and is pulled from the LP via `transferFrom`; a positive amount is credited
    /// and taken straight to the LP.
    function _settlePrincipal(Currency currency, int128 amount, address lp) private {
        if (amount < 0) {
            poolManager.sync(currency);
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(lp, address(poolManager), uint256(uint128(-amount)));
            poolManager.settle();
        } else if (amount > 0) {
            poolManager.take(currency, lp, uint256(uint128(amount)));
        }
    }

    /* REWARD CLAIMING */

    /// @inheritdoc IEigenAuctionHook
    function claimRewards(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external {
        PoolId poolId = key.toId();
        bytes32 pk = _positionKey(poolId, msg.sender, tickLower, tickUpper, salt);

        _settle(poolId, pk, tickLower, tickUpper);

        Position storage pos = _positions[pk];
        uint256 owed0 = pos.owed[0];
        uint256 owed1 = pos.owed[1];
        if (owed0 == 0 && owed1 == 0) revert ErrorsLib.EigenAuctionHook_NothingToClaim();

        pos.owed[0] = 0;
        pos.owed[1] = 0;

        if (owed0 > 0) key.currency0.transfer(msg.sender, owed0);
        if (owed1 > 0) key.currency1.transfer(msg.sender, owed1);

        emit EventsLib.RewardsClaimed(poolId, msg.sender, owed0, owed1);
    }

    /// @inheritdoc IEigenAuctionHook
    function earned(
        PoolKey calldata key,
        address owner_,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        Position storage pos = _positions[_positionKey(poolId, owner_, tickLower, tickUpper, salt)];
        // Mirror `_settle`: fresh liquidity contributes only once it has aged into a later block.
        bool mature = pos.freshBlock != 0 && block.number > pos.freshBlock;

        amount0 = pos.owed[0] + _earnedFor(poolId, pos, tickLower, tickUpper, 0, mature);
        amount1 = pos.owed[1] + _earnedFor(poolId, pos, tickLower, tickUpper, 1, mature);
    }

    /// @dev Pending (unsettled) rewards for one currency: the mature leg, plus the fresh leg once
    /// it has matured. Pure read mirror of `_settle`'s accrual.
    function _earnedFor(
        PoolId poolId,
        Position storage pos,
        int24 tickLower,
        int24 tickUpper,
        uint8 i,
        bool mature
    ) private view returns (uint256 amount) {
        uint256 insideX128 = _growthInside(poolId, tickLower, tickUpper, i);
        amount = RewardGrowthLib.rewardsOf(insideX128, pos.lastGrowthInsideX128[i], pos.liquidity);
        if (mature) {
            amount += RewardGrowthLib.rewardsOf(insideX128, pos.freshGrowthInsideX128[i], pos.freshLiquidity);
        }
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

    /// @dev Allows swaps from `settler` unconditionally. Allows public swaps only after the
    /// fallback period elapses (or before a settler is registered). Reverts otherwise.
    function _beforeSwap(
        address sender,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        if (sender == settler) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        if (settler == address(0) || block.number > lastSettledBlock + ConstantsLib.FALLBACK_PERIOD) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        revert ErrorsLib.EigenAuctionHook_NotSettler();
    }

    /// @dev For arb-flagged swaps: measures the arbitrage LVR from the realised swap and the pool's
    /// post-trade marginal price, skims `LVR_SHARE_WAD` of it from the output currency via the
    /// returned hook delta, and folds it into the reward-growth accumulator. Non-arb swaps pass
    /// through untouched. The charge needs no pre-trade snapshot and no oracle — it is derived
    /// entirely from on-chain state the arbitrageur cannot inflate.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (!_isArb(hookData)) {
            return (this.afterSwap.selector, 0);
        }

        PoolId poolId = key.toId();
        uint256 fee = _lvrFee(poolId, params.zeroForOne, delta);
        if (fee == 0) {
            return (this.afterSwap.selector, 0);
        }

        // Spread across reward-eligible liquidity only; the current block's JIT cohort is excluded so
        // it cannot dilute honest LPs. With nobody eligible there is nobody to pay, so skim nothing.
        uint128 eligible = _rewardEligibleLiquidity(poolId);
        if (eligible == 0) {
            return (this.afterSwap.selector, 0);
        }

        // The arb output is the swap's unspecified side: currency1 for zeroForOne, else currency0.
        uint8 i = params.zeroForOne ? 1 : 0;
        Currency feeCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        poolManager.take(feeCurrency, address(this), fee);
        rewardGrowthGlobalX128[poolId][i] += FullMath.mulDiv(fee, FixedPoint128.Q128, eligible);

        emit EventsLib.ArbitrageSettled(poolId, sender, i, fee);
        return (this.afterSwap.selector, fee.toInt128());
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
        // Reached only for liquidity added through an external router; the hook's own add is recorded
        // inline in `unlockCallback` because V4's `noSelfCall` skips this callback for self-calls.
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
        // External-router path only (see `_afterAddLiquidity`).
        _recordLiquidity(key.toId(), sender, params.tickLower, params.tickUpper, params.salt, params.liquidityDelta);
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /* INTERNAL HELPERS */

    /// @dev Measures the LP-owed share of the arbitrage LVR for a just-executed arb swap.
    ///
    /// LVR is the extra profit the arbitrageur walks away with. They paid `amountIn` and received
    /// `amountOut`. At the pool's price *after* the trade, that `amountIn` is only worth
    /// `amountIn * P`. Anything they got above that is free profit taken from LPs: `LVR = amountOut - amountIn * P`.
    /// This is measured purely from the trade itself and the pool's own after-trade price, so there
    /// is no price feed to trust and the arbitrageur cannot fake a bigger or smaller number. The
    /// hook returns `LVR_SHARE_WAD` of this amount (e.g. 90%) to hand back to LPs.
    ///
    /// @param poolId The pool that was arbed.
    /// @param zeroForOne Direction of the arb swap.
    /// @param delta The swapper balance delta returned by the arb swap.
    /// @return fee The amount, in the output currency, owed to LPs.
    function _lvrFee(PoolId poolId, bool zeroForOne, BalanceDelta delta) private view returns (uint256 fee) {
        // Input is the negative leg (owed to the pool), output the positive leg (paid to the arbitrageur).
        uint256 amountIn = uint256(uint128(zeroForOne ? -delta.amount0() : -delta.amount1()));
        uint256 amountOut = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        if (amountIn == 0 || amountOut == 0) return 0;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        // priceX96 = (token1 per token0), Q96-scaled. mulDiv keeps the 512-bit intermediate exact.
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);

        // Value of the input at the post-trade marginal price, expressed in the output currency.
        uint256 fairOut = zeroForOne
            ? FullMath.mulDiv(amountIn, priceX96, FixedPoint96.Q96) // token0 -> token1: * P
            : FullMath.mulDiv(amountIn, FixedPoint96.Q96, priceX96); // token1 -> token0: / P
        if (amountOut <= fairOut) return 0;

        fee = FullMath.mulDiv(amountOut - fairOut, ConstantsLib.LVR_SHARE_WAD, ConstantsLib.PRECISION);
    }

    /// @dev Pool liquidity eligible to receive arb rewards: in-range liquidity minus the current
    /// block's JIT cohort. Excluding same-block adds is the pool-level half of the JIT guard.
    function _rewardEligibleLiquidity(PoolId poolId) private view returns (uint128) {
        uint128 active = poolManager.getLiquidity(poolId);
        FreshLiquidity storage f = _fresh[poolId];
        uint128 fresh = f.blockNumber == uint64(block.number) ? f.inRange : 0;
        return active > fresh ? active - fresh : 0;
    }

    /// @dev Records a liquidity change in the reward ledger and maintains the pool-level JIT cohort.
    /// Shared by the hook's own `unlockCallback` (self-calls, where V4 skips the liquidity callbacks)
    /// and by `_afterAddLiquidity`/`_afterRemoveLiquidity` for positions opened through an external
    /// router. `owner_`/`salt` identify the position in the reward ledger.
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
            // Track the in-range JIT cohort so it is excluded from this block's reward denominator.
            if (_isInRange(poolId, tickLower, tickUpper)) {
                _accrueFresh(poolId, uint128(uint256(liquidityDelta)));
            }
        } else if (liquidityDelta < 0) {
            // Net same-block removals out of the JIT cohort so add-then-remove cancels cleanly.
            FreshLiquidity storage f = _fresh[poolId];
            if (f.blockNumber == uint64(block.number) && _isInRange(poolId, tickLower, tickUpper)) {
                uint128 dec = uint128(uint256(-liquidityDelta));
                f.inRange = f.inRange > dec ? f.inRange - dec : 0;
            }
        }
    }

    /// @dev Settles a position, then applies the liquidity delta. Additions enter the position's
    /// fresh (same-block) bucket; they earn nothing until they mature in a later block — this is the
    /// per-position half of the JIT guard. Removals drain the fresh bucket first, so an atomic
    /// add ==> arb ==> remove leaves no mature liquidity behind and accrues nothing.
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
        if (liquidityDelta >= 0) {
            if (pos.freshBlock == 0) {
                // Open a fresh cohort, checkpointed at the current (post-arb) growth so it never
                // back-claims an arb from the block it was added in.
                pos.freshGrowthInsideX128[0] = _growthInside(poolId, tickLower, tickUpper, 0);
                pos.freshGrowthInsideX128[1] = _growthInside(poolId, tickLower, tickUpper, 1);
                pos.freshBlock = block.number;
            }
            pos.freshLiquidity += uint128(uint256(liquidityDelta));
        } else {
            // get how much liquidity to subtract
            uint128 dec = uint128(uint256(-liquidityDelta));
            if (pos.freshLiquidity >= dec) {
                // remove entirely from the fresh bucket
                pos.freshLiquidity -= dec;
            } else {
                // fresh bucket isn't enough — take what's there, then zero it and take the rest from the mature bucket
                dec -= pos.freshLiquidity;
                pos.freshLiquidity = 0;
                pos.liquidity = pos.liquidity >= dec ? pos.liquidity - dec : 0;
            }
        }
    }

    /// @dev Accrues rewards for both currencies into `owed`, advancing the mature checkpoint. When
    /// the fresh bucket has aged into a later block it matures here: its rewards (which began
    /// accruing only after its add-block) are credited and the liquidity folds into `liquidity`.
    function _settle(PoolId poolId, bytes32 pk, int24 tickLower, int24 tickUpper) private {
        Position storage pos = _positions[pk];
        bool mature = pos.freshBlock != 0 && block.number > pos.freshBlock;
        for (uint8 i = 0; i < 2; i++) {
            uint256 insideX128 = _growthInside(poolId, tickLower, tickUpper, i);
            pos.owed[i] += RewardGrowthLib.rewardsOf(insideX128, pos.lastGrowthInsideX128[i], pos.liquidity);
            if (mature) {
                pos.owed[i] += RewardGrowthLib.rewardsOf(insideX128, pos.freshGrowthInsideX128[i], pos.freshLiquidity);
            }
            pos.lastGrowthInsideX128[i] = insideX128;
        }
        if (mature) {
            pos.liquidity += pos.freshLiquidity;
            pos.freshLiquidity = 0;
            pos.freshBlock = 0;
        }
    }

    /// @dev True when the pool's current tick lies within `[tickLower, tickUpper)`.
    function _isInRange(PoolId poolId, int24 tickLower, int24 tickUpper) private view returns (bool) {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        return tickLower <= tick && tick < tickUpper;
    }

    /// @dev Adds `amount` to the pool's current-block fresh in-range cohort, resetting on a new block.
    function _accrueFresh(PoolId poolId, uint128 amount) private {
        FreshLiquidity storage f = _fresh[poolId];
        if (f.blockNumber != uint64(block.number)) {
            f.blockNumber = uint64(block.number);
            f.inRange = amount;
        } else {
            f.inRange += amount;
        }
    }

    function _growthInside(PoolId poolId, int24 tickLower, int24 tickUpper, uint8 i)
        private
        view
        returns (uint256)
    {
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        return RewardGrowthLib.growthInside(
            currentTick, tickLower, tickUpper, rewardGrowthGlobalX128[poolId][i], 0, 0
        );
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

    /// @dev A swap is arb-flagged only when `hookData` is exactly `abi.encode(true)`.
    function _isArb(bytes calldata hookData) private pure returns (bool) {
        if (hookData.length != 32) return false;
        return abi.decode(hookData, (bool));
    }
}
