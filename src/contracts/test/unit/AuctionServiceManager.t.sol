// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";
import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IPermissionController} from "eigenlayer-contracts/src/contracts/interfaces/IPermissionController.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IStakeRegistry} from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {AuctionServiceManager} from "../../src/AuctionServiceManager.sol";
import {IAuctionServiceManager, AuctionResult} from "../../src/interfaces/IAuctionServiceManager.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {EventsLib} from "../../src/libraries/EventsLib.sol";
import {ConstantsLib} from "../../src/libraries/ConstantsLib.sol";
import {MockAllocationManager} from "../mocks/MockAllocationManager.sol";

/// @notice Unit test suite for `AuctionServiceManager`.
/// @dev Operator-set membership and slashing are exercised against `MockAllocationManager`, so the
/// suite is deterministic and needs no RPC fork. The other EigenLayer dependencies are never called
/// by the contract, so they are passed as zero addresses. The real on-chain integration (operators
/// registering for the set, allocating stake, real slashing) belongs in a separate fork test.
contract AuctionServiceManagerTest is Test {
    using MessageHashUtils for bytes32;

    /* CONSTANTS */

    uint256 public constant THRESHOLD = 2;
    uint256 public constant BID = 1 ether;
    uint32 public constant OPERATOR_SET_ID = 1;

    /* STATE */

    AuctionServiceManager public asm;
    MockAllocationManager public allocationManager;

    PoolId public poolId;
    address public winner;

    // Operator signing keys and derived addresses.
    uint256 public op1Key = 0xA11CE;
    uint256 public op2Key = 0xB0B;
    uint256 public op3Key = 0xCAFE;
    address public op1;
    address public op2;
    address public op3;

    // A non-operator key used to prove non-member signatures are ignored.
    uint256 public strangerKey = 0xBADBED;
    address public stranger;

    // A higher bidder used in challenge tests.
    uint256 public bidderKey = 0xB1DDE7;
    address public higherBidder;

    // A dummy strategy used for slashing configuration.
    IStrategy public dummyStrategy = IStrategy(address(0x5712A7E69));

    /* SETUP */

    function setUp() public {
        poolId = PoolId.wrap(bytes32(uint256(1)));
        winner = makeAddr("winner");

        op1 = vm.addr(op1Key);
        op2 = vm.addr(op2Key);
        op3 = vm.addr(op3Key);
        stranger = vm.addr(strangerKey);
        higherBidder = vm.addr(bidderKey);

        allocationManager = new MockAllocationManager();

        AuctionServiceManager impl = new AuctionServiceManager(
            IAVSDirectory(address(0)),
            IRewardsCoordinator(address(0)),
            ISlashingRegistryCoordinator(address(0)),
            IStakeRegistry(address(0)),
            IPermissionController(address(0)),
            IAllocationManager(address(allocationManager)),
            THRESHOLD
        );

        bytes memory init =
            abi.encodeCall(AuctionServiceManager.initialize, (address(this), address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        asm = AuctionServiceManager(address(proxy));

        // Register all three operators as members of this AVS's operator set.
        allocationManager.setMember(op1, address(asm), OPERATOR_SET_ID, true);
        allocationManager.setMember(op2, address(asm), OPERATOR_SET_ID, true);
        allocationManager.setMember(op3, address(asm), OPERATOR_SET_ID, true);

        // Advance a couple of blocks so targetBlock arithmetic is comfortable.
        vm.roll(block.number + 2);
    }

    /* TEST HELPERS */

    /// @dev Produces an operator signature over the winner tuple, matching the contract's hash.
    function _signWinner(uint256 key, uint256 targetBlock, address winner_, uint256 bid)
        internal
        view
        returns (bytes memory)
    {
        bytes32 ethHash =
            keccak256(abi.encodePacked(poolId, targetBlock, winner_, bid)).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Produces a bidder signature over the bid tuple, matching `challengeWinner`'s hash.
    function _signBid(uint256 key, uint256 targetBlock, uint256 bid)
        internal
        view
        returns (bytes memory)
    {
        bytes32 ethHash =
            keccak256(abi.encodePacked(poolId, targetBlock, bid)).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Two-of-three operator signatures (op1 + op2) over the winner tuple.
    function _quorumSigs(uint256 targetBlock) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _signWinner(op1Key, targetBlock, winner, BID);
        sigs[1] = _signWinner(op2Key, targetBlock, winner, BID);
    }

    /// @dev Configures the operator set and slash parameters (10 % of `dummyStrategy`).
    function _configureSlashing() internal {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = dummyStrategy;
        uint256[] memory wads = new uint256[](1);
        wads[0] = 1e17; // 10 %

        asm.createOperatorSet(strategies);
        asm.configureSlashing(strategies, wads);
    }

    /* INITIALIZER / CONFIG TESTS */

    function test_Initialize_Sets_Owner() public view {
        assertEq(asm.owner(), address(this));
    }

    function test_Threshold_Is_Set() public view {
        assertEq(asm.threshold(), THRESHOLD);
    }

    function test_Constructor_Reverts_When_Threshold_Zero() public {
        vm.expectRevert(ErrorsLib.AuctionServiceManager_InvalidThreshold.selector);
        new AuctionServiceManager(
            IAVSDirectory(address(0)),
            IRewardsCoordinator(address(0)),
            ISlashingRegistryCoordinator(address(0)),
            IStakeRegistry(address(0)),
            IPermissionController(address(0)),
            IAllocationManager(address(allocationManager)),
            0
        );
    }

    function test_CreateOperatorSet_Calls_AllocationManager() public {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = dummyStrategy;
        asm.createOperatorSet(strategies);
        assertEq(allocationManager.createOperatorSetsCalls(), 1);
    }

    function test_CreateOperatorSet_Reverts_When_Not_Owner() public {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = dummyStrategy;
        vm.prank(stranger);
        vm.expectRevert();
        asm.createOperatorSet(strategies);
    }

    function test_ConfigureSlashing_Reverts_On_Length_Mismatch() public {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = dummyStrategy;
        uint256[] memory wads = new uint256[](2);
        vm.expectRevert(ErrorsLib.AuctionServiceManager_SlashConfigLengthMismatch.selector);
        asm.configureSlashing(strategies, wads);
    }

    /* COMMIT WINNER TESTS */

    function test_commitWinner_TwoOfThree_Succeeds() public {
        uint256 target = block.number;
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));

        AuctionResult memory r = asm.getWinner(poolId, target);
        assertTrue(r.committed);
        assertEq(r.winner, winner);
        assertEq(r.bidAmount, BID);
        assertFalse(r.challenged);
        assertEq(r.committedBlock, block.number);
    }

    function test_commitWinner_Stores_Signers() public {
        uint256 target = block.number;
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));

        AuctionResult memory r = asm.getWinner(poolId, target);
        assertEq(r.signers.length, 2);
        // Signers are recorded in the order their signatures appear in the bundle (op1, op2).
        assertEq(r.signers[0], op1);
        assertEq(r.signers[1], op2);
    }

    function test_commitWinner_Emits_WinnerCommitted() public {
        uint256 target = block.number;
        vm.expectEmit(true, true, true, true, address(asm));
        emit EventsLib.WinnerCommitted(poolId, target, winner, BID);
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));
    }

    function test_commitWinner_Reverts_When_QuorumNotMet_OneSig() public {
        uint256 target = block.number;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signWinner(op1Key, target, winner, BID);

        vm.expectRevert(ErrorsLib.AuctionServiceManager_QuorumNotMet.selector);
        asm.commitWinner(poolId, target, winner, BID, sigs);
    }

    function test_commitWinner_Ignores_NonOperator_Signature() public {
        uint256 target = block.number;
        // op1 (member) + stranger (not a member) ==> only 1 valid ==> quorum (2) not met.
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signWinner(op1Key, target, winner, BID);
        sigs[1] = _signWinner(strangerKey, target, winner, BID);

        vm.expectRevert(ErrorsLib.AuctionServiceManager_QuorumNotMet.selector);
        asm.commitWinner(poolId, target, winner, BID, sigs);
    }

    function test_commitWinner_Ignores_Duplicate_Signatures() public {
        uint256 target = block.number;
        // op1 signs twice ==> counted once ==> quorum (2) not met.
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signWinner(op1Key, target, winner, BID);
        sigs[1] = _signWinner(op1Key, target, winner, BID);

        vm.expectRevert(ErrorsLib.AuctionServiceManager_QuorumNotMet.selector);
        asm.commitWinner(poolId, target, winner, BID, sigs);
    }

    function test_commitWinner_Reverts_When_Stale_Block() public {
        uint256 staleTarget = block.number;
        vm.roll(block.number + 5); // now > staleTarget + 1
        vm.expectRevert(ErrorsLib.AuctionServiceManager_StaleBlock.selector);
        asm.commitWinner(poolId, staleTarget, winner, BID, _quorumSigs(staleTarget));
    }

    function test_commitWinner_Reverts_When_Already_Committed() public {
        uint256 target = block.number;
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));

        vm.expectRevert(ErrorsLib.AuctionServiceManager_AlreadyCommitted.selector);
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));
    }

    function test_commitWinner_Reverts_When_Zero_Winner() public {
        uint256 target = block.number;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signWinner(op1Key, target, address(0), BID);
        sigs[1] = _signWinner(op2Key, target, address(0), BID);

        vm.expectRevert(ErrorsLib.AuctionServiceManager_ZeroWinner.selector);
        asm.commitWinner(poolId, target, address(0), BID, sigs);
    }

    function test_commitWinner_Reverts_When_Sigs_For_Wrong_Bid() public {
        uint256 target = block.number;
        // Operators signed for BID; caller submits BID + 1 ==> digest mismatch ==> quorum fails.
        vm.expectRevert(ErrorsLib.AuctionServiceManager_QuorumNotMet.selector);
        asm.commitWinner(poolId, target, winner, BID + 1, _quorumSigs(target));
    }

    /* CHALLENGE TESTS */

    function test_challengeWinner_Succeeds_Marks_And_Slashes() public {
        _configureSlashing();
        uint256 target = block.number;
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));

        uint256 higherBid = BID + 1;
        bytes memory bidderSig = _signBid(bidderKey, target, higherBid);

        asm.challengeWinner(poolId, target, higherBidder, higherBid, bidderSig);

        // Result is invalidated.
        AuctionResult memory r = asm.getWinner(poolId, target);
        assertTrue(r.challenged);

        // Both signing operators were slashed.
        assertEq(allocationManager.slashCount(), 2);
        assertEq(allocationManager.slashedOperators(0), op1);
        assertEq(allocationManager.slashedOperators(1), op2);
    }

    function test_challengeWinner_Emits_WinnerChallenged() public {
        _configureSlashing();
        uint256 target = block.number;
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));

        uint256 higherBid = BID + 1;
        bytes memory bidderSig = _signBid(bidderKey, target, higherBid);

        vm.expectEmit(true, true, true, true, address(asm));
        emit EventsLib.WinnerChallenged(poolId, target, address(this), higherBidder, higherBid);
        asm.challengeWinner(poolId, target, higherBidder, higherBid, bidderSig);
    }

    function test_challengeWinner_Succeeds_Without_Slashing_Config() public {
        // No createOperatorSet / configureSlashing ==> slashing is skipped but challenge still marks.
        uint256 target = block.number;
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));

        uint256 higherBid = BID + 1;
        bytes memory bidderSig = _signBid(bidderKey, target, higherBid);

        asm.challengeWinner(poolId, target, higherBidder, higherBid, bidderSig);

        assertTrue(asm.getWinner(poolId, target).challenged);
        assertEq(allocationManager.slashCount(), 0);
    }

    function test_challengeWinner_Reverts_When_Not_Committed() public {
        uint256 target = block.number;
        bytes memory bidderSig = _signBid(bidderKey, target, BID + 1);
        vm.expectRevert(ErrorsLib.AuctionServiceManager_NotCommitted.selector);
        asm.challengeWinner(poolId, target, higherBidder, BID + 1, bidderSig);
    }

    function test_challengeWinner_Reverts_When_Already_Challenged() public {
        uint256 target = block.number;
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));

        uint256 higherBid = BID + 1;
        bytes memory bidderSig = _signBid(bidderKey, target, higherBid);
        asm.challengeWinner(poolId, target, higherBidder, higherBid, bidderSig);

        vm.expectRevert(ErrorsLib.AuctionServiceManager_AlreadyChallenged.selector);
        asm.challengeWinner(poolId, target, higherBidder, higherBid, bidderSig);
    }

    function test_challengeWinner_Reverts_When_Window_Closed() public {
        uint256 target = block.number;
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));

        vm.roll(block.number + ConstantsLib.CHALLENGE_WINDOW + 1);

        uint256 higherBid = BID + 1;
        bytes memory bidderSig = _signBid(bidderKey, target, higherBid);
        vm.expectRevert(ErrorsLib.AuctionServiceManager_ChallengeWindowClosed.selector);
        asm.challengeWinner(poolId, target, higherBidder, higherBid, bidderSig);
    }

    function test_challengeWinner_Reverts_When_Not_Higher_Bid() public {
        uint256 target = block.number;
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));

        // Equal bid is not strictly higher.
        bytes memory bidderSig = _signBid(bidderKey, target, BID);
        vm.expectRevert(ErrorsLib.AuctionServiceManager_NotHigherBid.selector);
        asm.challengeWinner(poolId, target, higherBidder, BID, bidderSig);
    }

    function test_challengeWinner_Reverts_When_Bid_Signature_Mismatch() public {
        uint256 target = block.number;
        asm.commitWinner(poolId, target, winner, BID, _quorumSigs(target));

        uint256 higherBid = BID + 1;
        // Signed by the bidder key, but claim a different higherBidder address ==> recovery mismatch.
        bytes memory bidderSig = _signBid(bidderKey, target, higherBid);
        vm.expectRevert(ErrorsLib.AuctionServiceManager_InvalidBidSignature.selector);
        asm.challengeWinner(poolId, target, makeAddr("notTheSigner"), higherBid, bidderSig);
    }

    /* GET WINNER TESTS */

    function test_getWinner_Returns_Empty_When_Not_Committed() public view {
        AuctionResult memory r = asm.getWinner(poolId, block.number);
        assertFalse(r.committed);
        assertEq(r.winner, address(0));
        assertEq(r.bidAmount, 0);
        assertEq(r.signers.length, 0);
    }
}
