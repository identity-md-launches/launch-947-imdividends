// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {IMDIVIDENDS} from "../src/IMDIVIDENDS.sol";
import {DividendVault} from "../src/DividendVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract RevisionTest is Fixture {
    function testLateDistributorIsExcludedOnNextTransferBeforeRewardsStart() public {
        factory.setDistributor(address(0));
        _give(DISTRIBUTOR, 100_000_000 ether);
        assertEq(vault.shares(DISTRIBUTOR), 100_000_000 ether);
        factory.setDistributor(DISTRIBUTOR);
        _give(ALICE, 100_000_000 ether);
        assertEq(vault.shares(DISTRIBUTOR), 0);
        assertEq(vault.totalShares(), 100_000_000 ether);
        _start(1_000e6);
        vm.warp(block.timestamp + 600);
        assertEq(vault.earned(DISTRIBUTOR), 0);
        vm.expectRevert(DividendVault.NothingToClaim.selector);
        vault.claimFor(DISTRIBUTOR);
        vault.claimFor(ALICE);
        assertApproxEqAbs(reward.balanceOf(ALICE), 1_000e6, 1);
        assertEq(reward.balanceOf(DISTRIBUTOR), 0);
    }

    function testAnyoneCanSyncLateDistributorWithoutMovingItsTokens() public {
        factory.setDistributor(address(0));
        _give(DISTRIBUTOR, 100_000_000 ether);
        _give(ALICE, 100_000_000 ether);
        factory.setDistributor(DISTRIBUTOR);
        vm.prank(BOB);
        token.syncShares(DISTRIBUTOR);
        assertEq(token.balanceOf(DISTRIBUTOR), 100_000_000 ether);
        assertEq(vault.shares(DISTRIBUTOR), 0);
        assertEq(vault.totalShares(), 100_000_000 ether);
        _start(1_000e6);
        vm.warp(block.timestamp + 600);
        assertEq(vault.earned(DISTRIBUTOR), 0);
        assertApproxEqAbs(vault.earned(ALICE), 1_000e6, 1);
    }

    function testSyncUsesRealBalanceAndPreservesPastEarnings() public {
        _give(ALICE, 100 ether);
        _start(600e6);
        vm.warp(block.timestamp + 300);
        vm.startPrank(BOB);
        token.syncShares(ALICE);
        token.syncShares(BOB);
        token.syncShares(MANAGER);
        token.syncShares(address(0));
        vm.stopPrank();
        assertEq(vault.shares(ALICE), 100 ether);
        assertEq(vault.shares(BOB), 0);
        assertEq(vault.shares(MANAGER), 0);
        assertEq(vault.totalShares(), 100 ether);
        assertApproxEqAbs(vault.earned(ALICE), 300e6, 1);
        vm.warp(block.timestamp + 300);
        vault.claimFor(ALICE);
        assertApproxEqAbs(reward.balanceOf(ALICE), 600e6, 1);
    }

    function testLateRegistrationSyncStopsFutureAccrualButCannotUndoPastAccrual() public {
        factory.setDistributor(address(0));
        _give(DISTRIBUTOR, 100 ether);
        _give(ALICE, 100 ether);
        _start(600e6);
        vm.warp(block.timestamp + 300);
        factory.setDistributor(DISTRIBUTOR);
        token.syncShares(DISTRIBUTOR);
        assertApproxEqAbs(vault.earned(DISTRIBUTOR), 150e6, 1);
        vm.warp(block.timestamp + 300);
        assertApproxEqAbs(vault.earned(DISTRIBUTOR), 150e6, 1);
        assertApproxEqAbs(vault.earned(ALICE), 450e6, 1);
    }

    function testDisabledFundingRevertsWithoutTakingDonorTokensOrAllowance() public {
        token.configureVault(600, false);
        reward.mint(BOB, 1_000e6);
        vm.startPrank(BOB);
        reward.approve(address(vault), 1_000e6);
        vm.expectRevert(DividendVault.DistributionsDisabled.selector);
        vault.fund(1_000e6);
        vm.stopPrank();
        assertEq(reward.balanceOf(BOB), 1_000e6);
        assertEq(reward.allowance(BOB, address(vault)), 1_000e6);
        assertEq(reward.balanceOf(address(vault)), 0);
        assertEq(vault.totalFunded(), 0);
        assertEq(vault.queuedRewards(), 0);
        token.configureVault(600, true);
        vm.prank(BOB);
        vault.fund(1_000e6);
        assertEq(vault.queuedRewards(), 1_000e6);
    }

    function testDisabledConversionCannotMoveFeeInventoryOrOwnerRewards() public {
        _give(ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        reward.mint(address(this), 70e6);
        reward.approve(address(vault), 70e6);
        token.configureVault(600, false);
        vm.expectRevert(DividendVault.DistributionsDisabled.selector);
        token.convertFees(7 ether, 70e6, CAROL);
        assertEq(token.balanceOf(address(token)), 7 ether);
        assertEq(token.balanceOf(CAROL), 0);
        assertEq(reward.balanceOf(address(this)), 70e6);
        assertEq(reward.allowance(address(this), address(vault)), 70e6);
        assertEq(vault.totalFunded(), 0);
        token.configureVault(600, true);
        token.convertFees(7 ether, 70e6, CAROL);
        assertEq(token.balanceOf(CAROL), 7 ether);
        assertEq(vault.queuedRewards(), 70e6);
    }

    function testRenunciationRequiresOwnerAndZeroFee() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        token.renounceOwnership();
        vm.expectRevert(IMDIVIDENDS.UnsafeRenunciation.selector);
        token.renounceOwnership();
        assertEq(token.owner(), address(this));
        token.setFeeBps(0);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
        _give(ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 100 ether);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function testRenunciationRequiresEmptyInventoryEvenWithZeroFee() public {
        _give(ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        token.setFeeBps(0);
        vm.expectRevert(IMDIVIDENDS.UnsafeRenunciation.selector);
        token.renounceOwnership();
        assertEq(token.owner(), address(this));
        reward.mint(address(this), 70e6);
        reward.approve(address(vault), 70e6);
        token.convertFees(7 ether, 70e6, CAROL);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
        vault.distribute();
        vm.warp(block.timestamp + 600);
        assertGt(vault.claimFor(BOB), 0);
        assertGt(vault.claimFor(CAROL), 0);
    }

    function testRenunciationRequiresEnabledDistributionsWithOrWithoutQueuedRewards() public {
        token.setFeeBps(0);
        token.configureVault(600, false);
        vm.expectRevert(IMDIVIDENDS.UnsafeRenunciation.selector);
        token.renounceOwnership();
        token.configureVault(600, true);
        _give(ALICE, 1 ether);
        _fund(1_000e6);
        token.configureVault(600, false);
        vm.expectRevert(IMDIVIDENDS.UnsafeRenunciation.selector);
        token.renounceOwnership();
        assertEq(vault.queuedRewards(), 1_000e6);
        token.configureVault(600, true);
        token.transferOwnership(BOB);
        token.renounceOwnership();
        assertEq(token.pendingOwner(), address(0));
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        token.acceptOwnership();
        vm.prank(CAROL);
        vault.distribute();
        vm.warp(block.timestamp + 600);
        vault.claimFor(ALICE);
        assertApproxEqAbs(reward.balanceOf(ALICE), 1_000e6, 1);
        _fund(1_000e6);
        vault.distribute();
        vm.warp(block.timestamp + 600);
        vault.claimFor(ALICE);
        assertApproxEqAbs(reward.balanceOf(ALICE), 2_000e6, 1);
    }
}
