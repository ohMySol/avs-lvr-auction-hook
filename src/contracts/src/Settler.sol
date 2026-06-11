// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {ISettler, SwapIntent} from "./interfaces/ISettler.sol";
import {IAuctionServiceManager, AuctionResult} from "./interfaces/IAuctionServiceManager.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

/// @dev Minimal ERC-20 surface needed for token settlement.
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Minimal hook surface needed to reset the fallback liveness timer.
interface IHookSettlement {
    function recordSettlement() external;
}

/// @title Settler
/// @author ohMySol
/// @notice Chain-wide atomic settlement contract for all EigenAuction pools. Deploy once per chain;
/// register on each pool's hook via `hook.setSettler(address(this))`.
///
/// The AVS-committed winning operator calls `settle(key, rewardAmount, arb, intents)` once per
/// pool per block to execute two phases inside a single Uniswap V4 flash-accounting context:
///
/// Step 1 — Top-of-block arb rebalance.
/// Before executing the arb swap, the operator's `rewardAmount` of currency0 is deposited into
/// the pool manager. The hook collects it in `afterSwap` and distributes it to in-range LPs.
/// The pool's current liquidity is read immediately before the swap and passed as `expectedLiquidity`
/// in hookData, so the hook can revert if a JIT add lands between the read and the swap.
///
/// Step 2 — User intent fills.
/// Each `SwapIntent` is signature-verified, pool-checked, and executed at the post-arb price.
contract Settler is ISettler, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /* CONSTANTS */

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant _INTENT_TYPEHASH = keccak256(
        "SwapIntent(address user,bytes32 poolId,bool zeroForOne,uint128 amountIn,uint128 minAmountOut,uint64 nonce,uint64 deadline)"
    );

    /* IMMUTABLES */

    /// @inheritdoc ISettler
    IPoolManager public immutable poolManager;

    /// @inheritdoc ISettler
    IAuctionServiceManager public immutable avs;

    /// @inheritdoc ISettler
    bytes32 public immutable DOMAIN_SEPARATOR;

    /* STORAGE */

    /// @dev user => (nonce >> 8) => 256-bit bitmap.
    mapping(address => mapping(uint248 => uint256)) private _nonces;

    /* CONSTRUCTOR */

    /// @param _poolManager Uniswap V4 pool manager.
    /// @param _avs AVS service manager that commits per-block auction winners.
    constructor(address _poolManager, address _avs) {
        if (_poolManager == address(0) || _avs == address(0)) revert ErrorsLib.EigenAuctionHook_ZeroAddress();

        poolManager = IPoolManager(_poolManager);
        avs = IAuctionServiceManager(_avs);

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            _DOMAIN_TYPEHASH,
            keccak256("EigenAuction Settler"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    /* MODIFIERS */

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert ErrorsLib.Settler_NotPoolManager();
        _;
    }

    /* SETTLEMENT */

    /// @inheritdoc ISettler
    function settle(
        PoolKey calldata key,
        uint256 rewardAmount,
        SwapParams calldata arb,
        SwapIntent[] calldata intents
    ) external {
        if (arb.amountSpecified == 0 && intents.length == 0) revert ErrorsLib.Settler_NothingToSettle();

        PoolId poolId = key.toId();
        AuctionResult memory result = avs.getWinner(poolId, block.number);
        if (!result.committed)  revert ErrorsLib.Settler_AuctionNotCommitted();
        if (result.challenged)  revert ErrorsLib.Settler_WinnerChallenged();
        if (msg.sender != result.winner) revert ErrorsLib.Settler_NotWinner();

        IHookSettlement(address(key.hooks)).recordSettlement();

        poolManager.unlock(abi.encode(msg.sender, key, rewardAmount, arb, intents));

        emit EventsLib.BlockSettled(poolId, block.number, msg.sender);
    }

    /* V4 UNLOCK CALLBACK */

    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        (
            address operator,
            PoolKey memory key,
            uint256 rewardAmount,
            SwapParams memory arb,
            SwapIntent[] memory intents
        ) = abi.decode(data, (address, PoolKey, uint256, SwapParams, SwapIntent[]));

        // Step 1: arb swap with pre-funded LP reward.
        if (arb.amountSpecified != 0) {
            PoolId poolId = key.toId();

            // Transfer the operator's reward directly to the hook before the swap. The hook
            // distributes it in afterSwap after the tick crossing. The operator must have approved
            // this contract for at least rewardAmount of currency0.
            if (rewardAmount > 0) {
                bool ok = IERC20(Currency.unwrap(key.currency0)).transferFrom(
                    operator, address(key.hooks), rewardAmount
                );
                if (!ok) revert ErrorsLib.Settler_TransferFailed();
            }

            // Snapshot pool liquidity for JIT detection. The hook will revert if liquidity changed
            // between here and the swap (meaning a JIT add slipped in).
            uint256 expectedLiquidity = poolManager.getLiquidity(poolId);

            BalanceDelta d = poolManager.swap(
                key, arb, abi.encode(true, rewardAmount, expectedLiquidity)
            );
            _settleDeltas(key, arb.zeroForOne, operator, d);
        }

        // Step 2: user intent fills at the post-arb price.
        uint256 n = intents.length;
        for (uint256 i; i < n; ++i) {
            _fill(key, intents[i]);
        }

        return "";
    }

    /* NONCE MANAGEMENT */

    /// @inheritdoc ISettler
    function invalidateNonce(uint64 nonce) external {
        _useNonce(msg.sender, nonce);
        emit EventsLib.NonceInvalidated(msg.sender, nonce);
    }

    /// @inheritdoc ISettler
    function isNonceUsed(address user, uint64 nonce) external view returns (bool) {
        return _nonces[user][uint248(nonce >> 8)] & (1 << (nonce & 0xff)) != 0;
    }

    /* INTERNAL */

    function _fill(PoolKey memory key, SwapIntent memory intent) private {
        if (PoolId.unwrap(key.toId()) != intent.poolId) revert ErrorsLib.Settler_WrongPool();
        if (block.timestamp > intent.deadline)          revert ErrorsLib.Settler_IntentExpired();
        _useNonce(intent.user, intent.nonce);
        _verifySignature(intent);

        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: intent.zeroForOne,
                amountSpecified: -int256(uint256(intent.amountIn)),
                sqrtPriceLimitX96: intent.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 rawOut = intent.zeroForOne ? d.amount1() : d.amount0();
        uint256 amountOut = uint256(int256(rawOut));
        if (amountOut < intent.minAmountOut) revert ErrorsLib.Settler_SlippageExceeded();

        _settleDeltas(key, intent.zeroForOne, intent.user, d);

        emit EventsLib.IntentFilled(key.toId(), intent.user, intent.zeroForOne, intent.amountIn, amountOut);
    }

    function _settleDeltas(PoolKey memory key, bool zeroForOne, address user, BalanceDelta delta) private {
        (Currency tokenIn, Currency tokenOut) = zeroForOne
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);

        int128 deltaIn  = zeroForOne ? delta.amount0() : delta.amount1();
        int128 deltaOut = zeroForOne ? delta.amount1() : delta.amount0();

        if (deltaIn < 0) {
            poolManager.sync(tokenIn);
            bool ok = IERC20(Currency.unwrap(tokenIn)).transferFrom(
                user, address(poolManager), uint256(-int256(deltaIn))
            );
            if (!ok) revert ErrorsLib.Settler_TransferFailed();
            poolManager.settle();
        }
        if (deltaOut > 0) {
            poolManager.take(tokenOut, user, uint256(int256(deltaOut)));
        }
    }

    function _useNonce(address user, uint64 nonce) private {
        uint248 word = uint248(nonce >> 8);
        uint256 bit  = 1 << (nonce & 0xff);
        uint256 prev = _nonces[user][word];
        if (prev & bit != 0) revert ErrorsLib.Settler_NonceUsed();
        _nonces[user][word] = prev | bit;
    }

    function _verifySignature(SwapIntent memory intent) private view {
        bytes32 structHash = keccak256(abi.encode(
            _INTENT_TYPEHASH,
            intent.user,
            intent.poolId,
            intent.zeroForOne,
            intent.amountIn,
            intent.minAmountOut,
            intent.nonce,
            intent.deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR, structHash));
        address signer = _recover(digest, intent.signature);
        if (signer == address(0) || signer != intent.user) revert ErrorsLib.Settler_InvalidSignature();
    }

    function _recover(bytes32 digest, bytes memory sig) private pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        return ecrecover(digest, v, r, s);
    }
}
