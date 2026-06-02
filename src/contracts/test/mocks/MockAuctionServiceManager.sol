// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";

import {IAuctionServiceManager, AuctionResult} from "../../src/interfaces/IAuctionServiceManager.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {EventsLib} from "../../src/libraries/EventsLib.sol";

/// @title MockAuctionServiceManager
/// @author ohMySol
/// @notice Test double for `EigenAuctionHook` unit tests. A single trusted owner commits winners
/// directly, bypassing the ECDSA quorum and EigenLayer entirely. The `signatures` argument to
/// `commitWinner` is ignored, and the EigenLayer-only methods (`initialize`, `createOperatorSet`,
/// `configureSlashing`, `challengeWinner`) are stubs. Never deploy to production.
/// @dev Implements the full `IAuctionServiceManager` surface so it is drop-in compatible with the
/// hook, which only ever reads `getWinner`.
contract MockAuctionServiceManager is IAuctionServiceManager {
    /* STORAGE */

    /// @notice Address allowed to commit winners. Set to the deployer at construction.
    address public owner;

    /// @notice poolId => targetBlock => committed auction result.
    mapping(PoolId => mapping(uint256 => AuctionResult)) private _results;

    /* MODIFIERS */

    /// @dev Restricts a function to the contract owner.
    modifier onlyOwner() {
        if (msg.sender != owner) revert ErrorsLib.AuctionServiceManager_NotOwner();
        _;
    }

    /* CONSTRUCTOR */

    /// @dev Initializes the owner to the deployer.
    constructor() {
        owner = msg.sender;
    }

    /* INERT EIGENLAYER STUBS */

    /// @inheritdoc IAuctionServiceManager
    /// @dev No quorum in the mock — always returns 0.
    function threshold() external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IAuctionServiceManager
    /// @dev No-op: the mock has no EigenLayer wiring to initialise.
    function initialize(address, address) external override {}

    /// @inheritdoc IAuctionServiceManager
    /// @dev No-op: the mock has no EigenLayer operator set.
    function createOperatorSet(IStrategy[] calldata) external override {}

    /// @inheritdoc IAuctionServiceManager
    /// @dev No-op: the mock cannot slash.
    function configureSlashing(IStrategy[] calldata, uint256[] calldata) external override {}

    /// @inheritdoc IAuctionServiceManager
    /// @dev No-op: the mock has no challenge or slashing logic.
    function challengeWinner(PoolId, uint256, address, uint256, bytes calldata) external override {}

    /* WINNER COMMITMENT */

    /// @inheritdoc IAuctionServiceManager
    /// @dev The `signatures` argument is ignored in mock implementation. Stores the result directly so hook
    /// tests can set up a committed winner without producing operator signatures.
    function commitWinner(
        PoolId poolId,
        uint256 targetBlock,
        address winner,
        uint256 bidAmount,
        bytes[] calldata /* signatures */
    ) external override onlyOwner {
        if (winner == address(0)) revert ErrorsLib.AuctionServiceManager_ZeroWinner();

        _results[poolId][targetBlock] = AuctionResult({
            bidAmount: bidAmount,
            winner: winner,
            committed: true,
            challenged: false,
            committedBlock: block.number,
            signers: new address[](0)
        });

        emit EventsLib.WinnerCommitted(poolId, targetBlock, winner, bidAmount);
    }

    /* VIEW FUNCTIONS */

    /// @inheritdoc IAuctionServiceManager
    function getWinner(PoolId poolId, uint256 blockNumber)
        external
        view
        override
        returns (AuctionResult memory)
    {
        return _results[poolId][blockNumber];
    }
}
