// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {DividendVault} from "src/DividendVault.sol";

contract DividendPropertiesTest is Fixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzCompleteExitPaysEachHolderForTheirHoldingTime(
        uint32 durationSeed,
        uint256 rateSeed,
        uint32 elapsedSeed,
        uint8 shareExponent
    ) public {
        uint32 duration = uint32(bound(durationSeed, 600, 86_400));
        uint256 rate = bound(rateSeed, 1, 1e24);
        uint256 elapsed = bound(elapsedSeed, 0, duration);
        // Powers of two remove index rounding: the oracle is simply seconds held * units/second.
        uint256 balance = uint256(1) << (shareExponent % 80);
        token.setFeeBps(0);
        token.configureVault(duration, true);
        _give(ALICE, balance);
        _start(rate * duration);
        uint256 start = block.timestamp;
        vm.warp(start + elapsed);
        vm.prank(ALICE);
        token.transfer(BOB, balance);
        assertEq(vault.earned(ALICE), rate * elapsed);
        assertEq(vault.earned(BOB), 0);
        vm.warp(start + duration);
        address[] memory accounts = new address[](2);
        accounts[0] = ALICE;
        accounts[1] = BOB;
        assertEq(vault.process(accounts), rate * duration);
        assertEq(reward.balanceOf(ALICE), rate * elapsed);
        assertEq(reward.balanceOf(BOB), rate * (duration - elapsed));
        assertEq(reward.balanceOf(address(vault)), 0);
        assertEq(vault.earned(ALICE), 0);
        assertEq(vault.earned(BOB), 0);
    }

    function testThreeHolderChangingShareTimeline() public {
        token.setFeeBps(0);
        _give(ALICE, 2);
        _give(BOB, 6);
        _start(4_800);
        uint256 start = block.timestamp;
        vm.warp(start + 150);
        vm.prank(ALICE);
        token.transfer(BOB, 2);
        vm.warp(start + 450);
        _give(CAROL, 8);
        vm.warp(start + 600);
        vault.claimFor(ALICE);
        vault.claimFor(BOB);
        vault.claimFor(CAROL);
        assertEq(reward.balanceOf(ALICE), 300);
        assertEq(reward.balanceOf(BOB), 3_900);
        assertEq(reward.balanceOf(CAROL), 600);
        assertEq(reward.balanceOf(address(vault)), 0);
    }

    function testIndependentCooldownsUseLastSuccessfulPayout() public {
        token.configureVault(1_800, true);
        _give(ALICE, 1);
        _give(BOB, 1);
        _start(1_800);
        uint256 start = block.timestamp;
        vm.warp(start + 600);
        vm.prank(ALICE);
        assertEq(vault.claim(), 300);
        vm.warp(start + 900);
        assertEq(vault.claimFor(BOB), 450);
        assertEq(vault.nextClaimAt(ALICE), start + 1_200);
        assertEq(vault.nextClaimAt(BOB), start + 1_500);
        vm.warp(start + 1_199);
        vm.expectRevert(DividendVault.ClaimTooEarly.selector);
        vault.claimFor(ALICE);
        assertEq(vault.lastClaim(ALICE), start + 600);
        vm.warp(start + 1_200);
        assertEq(vault.claimFor(ALICE), 300);
        vm.expectRevert(DividendVault.ClaimTooEarly.selector);
        vault.claimFor(BOB);
        vm.warp(start + 1_500);
        assertEq(vault.claimFor(BOB), 300);
        assertEq(reward.balanceOf(ALICE), 600);
        assertEq(reward.balanceOf(BOB), 750);
    }

    function testEmptyClaimDoesNotDelayLaterFundedClaim() public {
        _give(ALICE, 1);
        uint256 first = vault.firstClaimAt();
        vm.warp(first);
        vm.expectRevert(DividendVault.NothingToClaim.selector);
        vault.claimFor(ALICE);
        assertEq(vault.lastClaim(ALICE), 0);
        assertEq(vault.nextClaimAt(ALICE), first);
        _start(600);
        vm.warp(first + 1);
        assertEq(vault.claimFor(ALICE), 1);
        assertEq(vault.nextClaimAt(ALICE), first + 601);
    }

    function testMaximumBatchPaysUniqueHoldersOnlyOnce() public {
        address[] memory accounts = new address[](50);
        for (uint256 i; i < 25; ++i) {
            address holder = address(uint160(0x100_000 + i));
            _give(holder, 1);
            accounts[i] = holder;
            accounts[49 - i] = holder;
        }
        _start(25_000);
        vm.warp(block.timestamp + 600);
        uint256 paid = vault.process(accounts);
        // The index rounds down by less than one reward base unit per holder.
        assertApproxEqAbs(paid, 25_000, 25);
        for (uint256 i; i < 25; ++i) {
            assertApproxEqAbs(reward.balanceOf(accounts[i]), 1_000, 1);
            assertEq(vault.lastClaim(accounts[i]), block.timestamp);
        }
        assertEq(vault.process(accounts), 0);
        assertEq(vault.totalClaimed(), paid);
        assertEq(reward.balanceOf(address(vault)) + paid, 25_000);
    }

    function testLateKeeperDoesNotAllocateRewardsDuringIdleGap() public {
        token.setFeeBps(0);
        _give(ALICE, 1);
        _start(600);
        uint256 finish = vault.streamEnd();
        vm.warp(finish + 30 days);
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        assertEq(vault.earned(ALICE), 600);
        assertEq(vault.earned(BOB), 0);
        _fund(600);
        vault.distribute();
        assertEq(vault.streamStart(), finish + 30 days);
        assertEq(vault.earned(BOB), 0);
        vm.warp(block.timestamp + 600);
        assertEq(vault.claimFor(ALICE), 600);
        assertEq(vault.claimFor(BOB), 600);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzCheckpointFrequencyCannotDestroyWholeRewards(
        uint256 balanceSeed,
        uint128 fundingSeed,
        uint8 countSeed
    ) public {
        _give(ALICE, bound(balanceSeed, 1, token.totalSupply()));
        uint256 funding = bound(fundingSeed, 1, type(uint128).max);
        _start(funding);
        uint256 start = block.timestamp;
        uint256 snapshot = vm.snapshotState();
        vm.warp(start + 600);
        uint256 uninterrupted = vault.earned(ALICE);
        assertTrue(vm.revertToState(snapshot));
        uint256 count = bound(countSeed, 1, 64);
        for (uint256 i = 1; i <= count; ++i) {
            vm.warp(start + 600 * i / count);
            vm.prank(ALICE);
            token.transfer(ALICE, 0);
        }
        uint256 checkpointed = vault.earned(ALICE);
        assertLe(checkpointed, uninterrupted);
        // At most 64 index roundings; 64 * maximum shares < SCALE, so loss is <= 1 base unit.
        assertApproxEqAbs(checkpointed, uninterrupted, 1);
        assertApproxEqAbs(checkpointed, funding, 1);
        address[] memory accounts = new address[](1);
        accounts[0] = ALICE;
        assertEq(vault.process(accounts), checkpointed);
        assertEq(reward.balanceOf(ALICE), checkpointed);
    }

    function testLifetimeFundingCapAcrossDonorsAndPeriodsIsAtomic() public {
        _give(ALICE, 1);
        uint256 maximum = vault.MAX_FUNDING();
        _start(maximum - 1);
        vm.warp(block.timestamp + 600);
        assertEq(vault.claimFor(ALICE), maximum - 1);
        reward.mint(BOB, 2);
        vm.prank(BOB);
        reward.approve(address(vault), 2);
        vm.prank(BOB);
        vault.fund(1);
        vault.distribute();
        vm.warp(block.timestamp + 600);
        assertEq(vault.claimFor(ALICE), 1);
        vm.prank(BOB);
        vm.expectRevert(DividendVault.InvalidAmount.selector);
        vault.fund(1);
        assertEq(reward.allowance(BOB, address(vault)), 1);
        assertEq(reward.balanceOf(BOB), 1);
        assertEq(vault.totalFunded(), maximum);
        assertEq(vault.totalClaimed(), maximum);
        assertEq(reward.balanceOf(address(vault)), 0);
    }
}
