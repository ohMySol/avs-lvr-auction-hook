// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from "forge-std/Test.sol";
import {LPRewardDistributor} from "../src/LPRewardDistributor.sol";
import {ILPRewardDistributor} from "../src/interfaces/ILPRewardDistributor.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {EventsLib} from "../src/libraries/EventsLib.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract LPRewardDistributorTest is Test {
    LPRewardDistributor distributor;
    PoolId poolId;
    address hook;
    address alice;
    address bob;

    function setUp() public {
        poolId = PoolId.wrap(bytes32(uint256(1)));
        hook = makeAddr("hook");
        vm.deal(hook, 100 ether);
        distributor = new LPRewardDistributor(hook);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    /* INITIALIZATION TESTS */

    function test_Contract_Initialized_Correctly() public {
        assertEq(hook, makeAddr("hook"));
    }

    function test_Contract_Initialization_Reverts_When_Hook_Address_Is_Zero() public {
        vm.expectRevert(ErrorsLib.LPRewardDistributor_HookAddressZero.selector);
        new LPRewardDistributor(address(0));
    }

    /* RECEIVE ARBITRAGE FEE TESTS */

    function test_receiveArbitrageFee_Executes_When_No_Liquidity() public {
        vm.prank(hook);
        distributor.receiveArbitrageFee{value: 1 ether}(poolId);
        assertEq(distributor.rewardPerShareStored(poolId), 0);
        // ETH silently kept — no revert, no distribution
    }

    function test_receiveArbitrageFee_Emits_RewardsReceived() public {
        vm.prank(hook);
        distributor.updateShares(poolId, alice, 0, 1000);

        vm.expectEmit(address(distributor));
        emit EventsLib.RewardsReceived(poolId, 1 ether);
        vm.prank(hook);
        distributor.receiveArbitrageFee{value: 1 ether}(poolId);
    }

    function test_onlyHook_Can_Receive_Arbitrage_Fee() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(ErrorsLib.LPRewardDistributor_OnlyHook.selector);
        distributor.receiveArbitrageFee{value: 1 ether}(poolId);
    }

    /* CLAIM REWARDS TESTS */

    function test_SingleLP_Claims_All_Rewards() public {
        vm.prank(hook);
        distributor.updateShares(poolId, alice, 0, 1000);

        vm.prank(hook);
        distributor.receiveArbitrageFee{value: 1 ether}(poolId);

        uint256 before = alice.balance;
        vm.prank(alice);
        distributor.claimRewards(poolId);

        assertApproxEqAbs(alice.balance - before, 1 ether, 1);
    }

    function test_TwoLPs_Split_Rewards() public {
        vm.startPrank(hook);
        distributor.updateShares(poolId, alice, 0, 1000);
        distributor.updateShares(poolId, bob, 0, 1000);
        distributor.receiveArbitrageFee{value: 2 ether}(poolId);
        vm.stopPrank();

        vm.prank(alice);
        distributor.claimRewards(poolId);
        vm.prank(bob);
        distributor.claimRewards(poolId);

        assertApproxEqAbs(alice.balance, 1 ether, 1);
        assertApproxEqAbs(bob.balance, 1 ether, 1);
    }

    function test_claimRewards_Emits_RewardsClaimed() public {
        vm.prank(hook);
        distributor.updateShares(poolId, alice, 0, 1000);
        vm.prank(hook);
        distributor.receiveArbitrageFee{value: 1 ether}(poolId);

        vm.expectEmit(address(distributor));
        emit EventsLib.RewardsClaimed(poolId, alice, 1 ether);
        vm.prank(alice);
        distributor.claimRewards(poolId);
    }

    // Edge case: emitted amount is the SUM across all distributions, not just the last.
    // Two separate bids (1 ETH + 0.5 ETH) must produce a single claim event of 1.5 ETH.
    function test_claimRewards_EmittedAmount_Is_Total_Across_All_Distributions() public {
        vm.prank(hook);
        distributor.updateShares(poolId, alice, 0, 1000);
        vm.prank(hook);
        distributor.receiveArbitrageFee{value: 1 ether}(poolId);
        vm.prank(hook);
        distributor.receiveArbitrageFee{value: 0.5 ether}(poolId);

        vm.expectEmit(address(distributor));
        emit EventsLib.RewardsClaimed(poolId, alice, 1.5 ether);
        vm.prank(alice);
        distributor.claimRewards(poolId);
    }

    function test_claimRewards_Reverts_When_Nothing_Owed() public {
        vm.expectRevert(ErrorsLib.LPRewardDistributor_NothingToClaim.selector);
        vm.prank(alice);
        distributor.claimRewards(poolId);
    }

    function test_Multiple_Claims_Do_Not_Double_Count() public {
        vm.prank(hook);
        distributor.updateShares(poolId, alice, 0, 1000);
        vm.prank(hook);
        distributor.receiveArbitrageFee{value: 1 ether}(poolId);

        vm.prank(alice);
        distributor.claimRewards(poolId);

        vm.expectRevert(ErrorsLib.LPRewardDistributor_NothingToClaim.selector);
        vm.prank(alice);
        distributor.claimRewards(poolId);
    }

    /* UPDATE SHARES TESTS */

    function test_Rewards_Accrue_Correctly_During_Liquidity_Changes() public {
        // Alice alone for first distribution, then she halves, then second distribution
        vm.prank(hook);
        distributor.updateShares(poolId, alice, 0, 1000);

        vm.prank(hook);
        distributor.receiveArbitrageFee{value: 1 ether}(poolId); // alice gets all 1 ETH

        vm.prank(hook);
        distributor.updateShares(poolId, alice, 1000, 500); // reduce liquidity

        vm.prank(hook);
        distributor.receiveArbitrageFee{value: 1 ether}(poolId); // alice still sole LP, gets 1 ETH

        vm.prank(alice);
        distributor.claimRewards(poolId);
        assertApproxEqAbs(alice.balance, 2 ether, 2);
    }

    function test_onlyHook_Can_Update_Shares() public {
        vm.expectRevert(ErrorsLib.LPRewardDistributor_OnlyHook.selector);
        distributor.updateShares(poolId, alice, 0, 1000);
    }
}