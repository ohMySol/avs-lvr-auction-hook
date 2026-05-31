// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ILPRewardDistributor} from "./interfaces/ILPRewardDistributor.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title LPRewardDistributor
/// @author ohMySol
/// @notice This destributor contract is responsible for fee-per-share rewards accounting.
/// It receives the winning bid and lets LPs claim proportionally to the liquidity they had in the crossed ticks.
contract LPRewardDistributor is ILPRewardDistributor {
    /* IMMUTABLE VARIABLES */

    /// @inheritdoc ILPRewardDistributor
    address public immutable hook;

    /* STORAGE */

    /// @inheritdoc ILPRewardDistributor
    mapping (PoolId => uint256) public rewardPerShareStored;

    /// @inheritdoc ILPRewardDistributor
    mapping (PoolId => uint256) public totalLiquidity;
    
    /// @inheritdoc ILPRewardDistributor
    mapping(PoolId => mapping(address => uint128)) public lpLiquidity;

    /// @inheritdoc ILPRewardDistributor
    mapping(PoolId => mapping(address => uint256)) public rewardDebt;
    
    /// @inheritdoc ILPRewardDistributor
    mapping(PoolId => mapping(address => uint256)) public pendingRewards;

    /* MODIFIERS */

    /// @dev Modifier to restrict access to hook only
    modifier onlyHook() {
        if (msg.sender != hook) revert ErrorsLib.LPRewardDistributor_OnlyHook();
        _;
    }

    /// @dev Constructor initilize the hook contract connected to this distributor
    /// @param _hook Hook contract address
    constructor(address _hook) {
        if (_hook == address(0)) revert ErrorsLib.LPRewardDistributor_HookAddressZero();
        hook = _hook;
    }

    /// @inheritdoc ILPRewardDistributor
    function receiveArbitrageFee(PoolId poolId) external payable override onlyHook {
        uint256 total = totalLiquidity[poolId];
        if (total == 0) return;
        rewardPerShareStored[poolId] += (msg.value * 1e18) / total;
        emit EventsLib.RewardsReceived(poolId, msg.value);
    }

    /// @inheritdoc ILPRewardDistributor
    function updateShares(
        PoolId poolId,
        address lp,
        uint128 oldLiquidity,
        uint128 newLiquidity
    ) external override onlyHook {
        _settle(poolId, lp);
        totalLiquidity[poolId] = totalLiquidity[poolId] - uint256(oldLiquidity) + uint256(newLiquidity);
        lpLiquidity[poolId][lp] = newLiquidity;
    }

    /// @inheritdoc ILPRewardDistributor
    function claimRewards(PoolId poolId) external override {
        _settle(poolId, msg.sender);
        
        uint256 amount = pendingRewards[poolId][msg.sender];
        if (amount == 0) revert ErrorsLib.LPRewardDistributor_NothingToClaim();
        
        pendingRewards[poolId][msg.sender] = 0;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert ErrorsLib.LPRewardDistributor_TransferFailed();
        
        emit EventsLib.RewardsClaimed(poolId, msg.sender, amount);
    }

    function _settle(PoolId poolId, address lp) internal {
        uint256 rps = rewardPerShareStored[poolId];
        uint256 earned = (uint256(lpLiquidity[poolId][lp]) * (rps - rewardDebt[poolId][lp])) / 1e18;
        
        pendingRewards[poolId][lp] += earned;
        rewardDebt[poolId][lp] = rps;
    }
}