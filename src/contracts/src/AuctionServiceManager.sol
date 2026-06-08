// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";
import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IAllocationManager, IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IPermissionController} from "eigenlayer-contracts/src/contracts/interfaces/IPermissionController.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";
import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IStakeRegistry} from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";
import {ServiceManagerBase} from "eigenlayer-middleware/src/ServiceManagerBase.sol";
import {IAVSRegistrar} from "eigenlayer-contracts/src/contracts/interfaces/IAVSRegistrar.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {IAuctionServiceManager, AuctionResult} from "./interfaces/IAuctionServiceManager.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ConstantsLib} from "./libraries/ConstantsLib.sol";

/// @title AuctionServiceManager
/// @author ohMySol
/// @notice EigenLayer AVS service manager for the arbitrage-auction hook. Inherits `ServiceManagerBase`
/// so all EigenLayer integration — rewards, metadata, admin/appointee management - is handled by the
/// base. On top, it validates per-block auction winner commitments via an ECDSA `m-of-n` threshold.
///
/// Operator membership is resolved entirely via EigenLayer's `AllocationManager`:
/// an operator is considered authorised if it is a member of `OPERATOR_SET_ID` for this AVS.
/// Operators join by calling `AllocationManager.registerForOperatorSets`.
///
/// Committed results sit in a `CHALLENGE_WINDOW`- block window. Anyone can submit a fraud proof —
/// a signed bid from a higher bidder that operators ignored. A successful challenge marks the result
/// as invalid and triggers EigenLayer slashing of every operator who signed the fraudulent commitment.
///
/// @dev Deploy as a proxy (`ERC1967Proxy` or `TransparentUpgradeableProxy`). Call `initialize` once.
contract AuctionServiceManager is ServiceManagerBase, IAuctionServiceManager, IAVSRegistrar {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /* IMMUTABLE VARIABLES */

    /// @inheritdoc IAuctionServiceManager
    uint256 public immutable threshold;

    /* STORAGE */

    /// @notice Strategies slashed per operator on a successful challenge.
    IStrategy[] private _slashableStrategies;

    /// @notice Slash proportion per strategy in wads (1e18 = 100 %).
    uint256[] private _slashWads;

    /// @notice poolId ==> targetBlock ==> committed auction result.
    mapping(PoolId => mapping(uint256 => AuctionResult)) private _results;

    /* CONSTRUCTOR */

    /// @param _avsDirectory         EigenLayer `AVSDirectory` proxy.
    /// @param _rewardsCoordinator   EigenLayer `RewardsCoordinator` proxy.
    /// @param _registryCoordinator  `SlashingRegistryCoordinator` for this AVS (may be `address(0)`).
    /// @param _stakeRegistry        `StakeRegistry` for this AVS (may be `address(0)`).
    /// @param _permissionController EigenLayer `PermissionController` proxy.
    /// @param _allocationManager    EigenLayer `AllocationManager` proxy.
    /// @param _threshold            Minimum unique operator signatures required to commit a winner.
    constructor(
        IAVSDirectory _avsDirectory,
        IRewardsCoordinator _rewardsCoordinator,
        ISlashingRegistryCoordinator _registryCoordinator,
        IStakeRegistry _stakeRegistry,
        IPermissionController _permissionController,
        IAllocationManager _allocationManager,
        uint256 _threshold
    )
        ServiceManagerBase(
            _avsDirectory,
            _rewardsCoordinator,
            _registryCoordinator,
            _stakeRegistry,
            _permissionController,
            _allocationManager
        )
    {
        if (_threshold == 0) revert ErrorsLib.AuctionServiceManager_InvalidThreshold();
        threshold = _threshold;
    }

    /* INITIALIZER */

    /// @inheritdoc IAuctionServiceManager
    function initialize(address initialOwner, address rewardsInitiator) external initializer {
        __ServiceManagerBase_init(initialOwner, rewardsInitiator);
    }

    /* EIGENLAYER OPERATOR SET SETUP */

    /// @notice Creates this AVS's operator set in EigenLayer with the given slashable strategies.
    /// @dev Owner-only. Call once post-deployment; operators then join via
    /// `AllocationManager.registerForOperatorSets`. Not part of the hook-facing interface because it
    /// references `IStrategy`, whose import would otherwise pull EigenLayer's `^0.8.27` pragma into
    /// the V4 (`=0.8.26`) hook compile unit.
    /// @param strategies Strategies (staked assets) slashable on a successful challenge.
    function createOperatorSet(IStrategy[] calldata strategies) external onlyOwner {
        IAllocationManagerTypes.CreateSetParams[] memory params = new IAllocationManagerTypes.CreateSetParams[](1);
        
        params[0] = IAllocationManagerTypes.CreateSetParams({
            operatorSetId: ConstantsLib.OPERATOR_SET_ID, 
            strategies: strategies
        });

        _allocationManager.createOperatorSets(address(this), params);
    }

    /// @notice Sets the strategies and slash proportions applied to each signer on a successful
    /// challenge. Owner-only. `strategies` must match the operator set; proportions are in wads
    /// (1e17 = 10%, 1e18 = 100%). Kept off the hook-facing interface for the same `IStrategy`
    /// pragma reason as `createOperatorSet`.
    /// @param strategies Strategies to slash.
    /// @param wads Slash proportion per strategy, in wads. Same length as `strategies`.
    function configureSlashing(IStrategy[] calldata strategies, uint256[] calldata wads)
        external
        onlyOwner
    {
        if (strategies.length != wads.length) {
            revert ErrorsLib.AuctionServiceManager_SlashConfigLengthMismatch();
        }
        delete _slashableStrategies;
        delete _slashWads;
        for (uint256 i = 0; i < strategies.length; i++) {
            _slashableStrategies.push(strategies[i]);
            _slashWads.push(wads[i]);
        }
    }

    /* IAVSRegistrar — operator-set admission */

    // EigenLayer's AllocationManager defaults the AVS registrar to the AVS address itself when none is
    // set, so this contract IS its own registrar. Without these hooks `registerForOperatorSets` would
    // revert and no operator could ever join the set, making `commitWinner` permanently unsatisfiable.

    /// @dev Restricts the IAVSRegistrar hooks to calls from EigenLayer's AllocationManager.
    modifier onlyAllocationManager() {
        if (msg.sender != address(_allocationManager)) {
            revert ErrorsLib.AuctionServiceManager_NotAllocationManager();
        }
        _;
    }

    /// @inheritdoc IAVSRegistrar
    /// @dev Called by AllocationManager when an operator joins. Admission is permissionless — the
    /// economic gate is the operator's EigenLayer stake/slashing enforced by AllocationManager; we
    /// only assert the registration targets this AVS and the single operator set this AVS runs.
    function registerOperator(
        address operator,
        address avs,
        uint32[] calldata operatorSetIds,
        bytes calldata /* data */
    ) external onlyAllocationManager {
        if (avs != address(this)) revert ErrorsLib.AuctionServiceManager_InvalidAvs();
        for (uint256 i = 0; i < operatorSetIds.length; i++) {
            if (operatorSetIds[i] != ConstantsLib.OPERATOR_SET_ID) {
                revert ErrorsLib.AuctionServiceManager_InvalidOperatorSet();
            }
        }
        emit EventsLib.OperatorRegistered(operator, ConstantsLib.OPERATOR_SET_ID);
    }

    /// @inheritdoc IAVSRegistrar
    /// @dev Called by AllocationManager when an operator leaves. Membership state lives in
    /// AllocationManager; we just acknowledge the deregistration.
    function deregisterOperator(address operator, address avs, uint32[] calldata /* operatorSetIds */)
        external
        onlyAllocationManager
    {
        if (avs != address(this)) revert ErrorsLib.AuctionServiceManager_InvalidAvs();
        emit EventsLib.OperatorDeregistered(operator, ConstantsLib.OPERATOR_SET_ID);
    }

    /// @inheritdoc IAVSRegistrar
    function supportsAVS(address avs) external view returns (bool) {
        return avs == address(this);
    }

    /* WINNER COMMITMENT */

    /// @inheritdoc IAuctionServiceManager
    function commitWinner(
        PoolId poolId,
        uint256 targetBlock,
        address winner,
        uint256 bidAmount,
        bytes[] calldata signatures
    ) external override {
        if (winner == address(0)) revert ErrorsLib.AuctionServiceManager_ZeroWinner();
        if (block.number > targetBlock + 1) revert ErrorsLib.AuctionServiceManager_StaleBlock();
        if (_results[poolId][targetBlock].committed) revert ErrorsLib.AuctionServiceManager_AlreadyCommitted();

        bytes32 ethHash =
            keccak256(abi.encodePacked(poolId, targetBlock, winner, bidAmount)).toEthSignedMessageHash();

        (uint256 validSigs, address[] memory signers) = _countUniqueOperatorSigs(ethHash, signatures);
        if (validSigs < threshold) revert ErrorsLib.AuctionServiceManager_QuorumNotMet();

        _results[poolId][targetBlock] = AuctionResult({
            bidAmount: bidAmount,
            winner: winner,
            committed: true,
            challenged: false,
            committedBlock: block.number,
            signers: signers
        });

        emit EventsLib.WinnerCommitted(poolId, targetBlock, winner, bidAmount);
    }

    /* CHALLENGE */

    /// @inheritdoc IAuctionServiceManager
    /// @dev Fraud-proof format: `higherBidder` must have signed
    /// `ethSignedMessageHash(keccak256(abi.encodePacked(poolId, targetBlock, higherBidAmount)))`.
    /// If slashing strategies are not yet configured the result is still marked as challenged
    /// and `WinnerChallenged` is emitted — only the on-chain slash call is skipped.
    function challengeWinner(
        PoolId poolId,
        uint256 targetBlock,
        address higherBidder,
        uint256 higherBidAmount,
        bytes calldata bidderSignature
    ) external {
        AuctionResult storage result = _results[poolId][targetBlock];

        if (!result.committed) revert ErrorsLib.AuctionServiceManager_NotCommitted();
        if (result.challenged) revert ErrorsLib.AuctionServiceManager_AlreadyChallenged();
        if (block.number > result.committedBlock + ConstantsLib.CHALLENGE_WINDOW) {
            revert ErrorsLib.AuctionServiceManager_ChallengeWindowClosed();
        }
        if (higherBidAmount <= result.bidAmount) revert ErrorsLib.AuctionServiceManager_NotHigherBid();

        bytes32 bidHash =
            keccak256(abi.encodePacked(poolId, targetBlock, higherBidAmount)).toEthSignedMessageHash();
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(bidHash, bidderSignature);
        if (err != ECDSA.RecoverError.NoError || recovered != higherBidder) {
            revert ErrorsLib.AuctionServiceManager_InvalidBidSignature();
        }

        result.challenged = true;

        address[] memory signers = result.signers;
        for (uint256 i = 0; i < signers.length; i++) {
            _slashSigner(signers[i]);
        }

        emit EventsLib.WinnerChallenged(poolId, targetBlock, msg.sender, higherBidder, higherBidAmount);
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

    /* EIGENLAYER VIEW OVERRIDES */

    /// @dev Return `new address[](0)` because we handle strategy configuration through `AllocationManager` 
    /// directly (via `createOperatorSet` and `configureSlashing`), not through the legacy StakeRegistry path.
    function getRestakeableStrategies() external pure override returns (address[] memory) {
        return new address[](0);
    }

    /// @dev Return `new address[](0)` because we handle strategy configuration through `AllocationManager` 
    /// directly (via `createOperatorSet` and `configureSlashing`), not through the legacy StakeRegistry path.
    function getOperatorRestakedStrategies(address)
        external
        pure
        override
        returns (address[] memory)
    {
        return new address[](0);
    }

    /* INTERNAL HELPERS */

    /// @dev Calls `AllocationManager.slashOperator` for `signer`. Silently no-ops when no
    /// slashing strategies are configured yet.
    function _slashSigner(address signer) internal {
        if (_slashableStrategies.length == 0) return;

        IAllocationManagerTypes.SlashingParams memory params = IAllocationManagerTypes.SlashingParams({
            operator: signer,
            operatorSetId: ConstantsLib.OPERATOR_SET_ID,
            strategies: _slashableStrategies,
            wadsToSlash: _slashWads,
            description: "AuctionServiceManager: fraudulent winner commitment"
        });

        (uint256 slashId,) = _allocationManager.slashOperator(address(this), params);
        emit EventsLib.OperatorSlashed(signer, slashId);
    }

    /// @dev Recovers each signature, checks EigenLayer operator-set membership, deduplicates.
    /// An address is authorised if `AllocationManager.isMemberOfOperatorSet` returns true.
    function _countUniqueOperatorSigs(bytes32 ethHash, bytes[] calldata signatures)
        internal
        view
        returns (uint256 validSigs, address[] memory signers)
    {
        OperatorSet memory opSet = OperatorSet({
            avs: address(this), 
            id: ConstantsLib.OPERATOR_SET_ID
        });
        address[] memory seen = new address[](signatures.length);

        for (uint256 i = 0; i < signatures.length; i++) {
            (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(ethHash, signatures[i]);
            if (err != ECDSA.RecoverError.NoError) continue;
            if (!_allocationManager.isMemberOfOperatorSet(signer, opSet)) continue;

            bool duplicate = false;
            for (uint256 j = 0; j < validSigs; j++) {
                if (seen[j] == signer) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;

            seen[validSigs] = signer;
            validSigs++;
        }

        signers = new address[](validSigs);
        for (uint256 i = 0; i < validSigs; i++) {
            signers[i] = seen[i];
        }
    }
}
