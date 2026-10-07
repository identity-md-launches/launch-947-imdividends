// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {IMDIVIDENDS} from "src/IMDIVIDENDS.sol";
import {DividendVault} from "src/DividendVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TokenAdversarialTest is Fixture {
    function testPinnedTaxRoundingBoundaries() public {
        _give(ALICE, 10_029);
        vm.startPrank(ALICE);
        token.transfer(BOB, 14);
        assertEq(token.balanceOf(address(token)), 0);
        token.transfer(BOB, 15);
        assertEq(token.balanceOf(address(token)), 1);
        token.transfer(BOB, 10_000);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 9_328);
        assertEq(token.balanceOf(address(token)), 701);
        assertEq(vault.totalShares(), 9_328);
    }

    function testEntireSupplyTransferAtDefaultTax() public {
        _give(ALICE, 1_000_000_000 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 1_000_000_000 ether);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 930_000_000 ether);
        assertEq(token.balanceOf(address(token)), 70_000_000 ether);
        assertEq(vault.totalShares(), 930_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function testRevertingTransferFromRollsBackAllowanceTaxAndAccrual() public {
        _give(ALICE, 100 ether);
        _start(600e6);
        vm.warp(block.timestamp + 300);
        vm.prank(ALICE);
        token.approve(CAROL, 101 ether);
        bytes32 beforeState = _state();
        // The fee debit itself fits, but the subsequent net debit does not.
        vm.prank(CAROL);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        token.transferFrom(ALICE, BOB, 101 ether);
        assertEq(token.allowance(ALICE, CAROL), 101 ether);
        assertEq(_state(), beforeState);
        vm.prank(CAROL);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.allowance(ALICE, CAROL), 1 ether);
        assertEq(token.balanceOf(BOB), 93 ether);
        assertApproxEqAbs(vault.earned(ALICE), 300e6, 1);
        assertEq(vault.earned(BOB), 0);
    }

    function testRevokedApprovalCannotSpendAndZeroReceiverPreservesApproval() public {
        _give(ALICE, 100 ether);
        vm.startPrank(ALICE);
        token.approve(CAROL, type(uint256).max);
        token.approve(CAROL, 0);
        vm.stopPrank();
        bytes32 beforeState = _state();
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, CAROL, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
        assertEq(_state(), beforeState);
        vm.prank(ALICE);
        token.approve(CAROL, 100 ether);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(ALICE, address(0), 100 ether);
        assertEq(token.allowance(ALICE, CAROL), 100 ether);
        assertEq(_state(), beforeState);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzEveryLaunchOperatorRequiresGrossApproval(uint256 amount, uint8 operatorSeed) public {
        amount = bound(amount, 1, token.totalSupply());
        address[3] memory operators = [address(factory), MANAGER, DISTRIBUTOR];
        address operator = operators[operatorSeed % 3];
        _give(ALICE, amount);
        vm.prank(ALICE);
        token.approve(operator, amount - 1);
        bytes32 beforeState = _state();
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, operator, amount - 1, amount)
        );
        token.transferFrom(ALICE, BOB, amount);
        assertEq(_state(), beforeState);
        assertEq(token.allowance(ALICE, operator), amount - 1);
        vm.prank(ALICE);
        token.approve(operator, amount);
        vm.prank(operator);
        token.transferFrom(ALICE, BOB, amount);
        // Factory/distributor launch operations stay exempt. The PoolManager cannot
        // waive the ordinary 7% tax by acting as a holder's approved operator.
        uint256 fee = operator == MANAGER ? amount * 700 / 10_000 : 0;
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), amount - fee);
        assertEq(token.allowance(ALICE, operator), 0);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(vault.shares(ALICE), 0);
        assertEq(vault.shares(BOB), amount - fee);
        assertEq(vault.totalShares(), amount - fee);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function testPendingOwnerReplacementCancellationAndRevocation() public {
        token.transferOwnership(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        token.configureVault(600, false);
        token.transferOwnership(BOB);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        token.acceptOwnership();
        token.transferOwnership(address(0));
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        token.acceptOwnership();
        token.transferOwnership(BOB);
        vm.prank(BOB);
        token.acceptOwnership();
        assertEq(token.pendingOwner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.configureVault(600, false);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.convertFees(1, 1, CAROL);
        vm.prank(BOB);
        token.configureVault(86_400, false);
        assertEq(vault.distributionDuration(), 86_400);
        assertFalse(vault.distributionsEnabled());
        // Even the current owner must use the token's controlled entry points.
        vm.prank(BOB);
        vm.expectRevert(DividendVault.OnlyToken.selector);
        vault.setShares(BOB, 1);
    }

    function testRenunciationClearsPendingOwnerAndPreservesPublicPayouts() public {
        _give(ALICE, 1);
        _start(600);
        token.transferOwnership(BOB);
        vm.expectRevert(IMDIVIDENDS.UnsafeRenunciation.selector);
        token.renounceOwnership();
        assertEq(token.owner(), address(this));
        assertEq(token.pendingOwner(), BOB);
        token.setFeeBps(0);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
        assertEq(token.pendingOwner(), address(0));
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        token.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.setFeeBps(0);
        vm.warp(block.timestamp + 600);
        vault.claimFor(ALICE);
        assertEq(reward.balanceOf(ALICE), 600);
        _start(1);
        vm.warp(block.timestamp + 600);
        vault.claimFor(ALICE);
        assertEq(reward.balanceOf(ALICE), 601);
    }

    function testAllInvalidConversionShapesLeaveAccountingUntouched() public {
        _collectFees();
        bytes32 beforeState = _state();
        uint256[5] memory amounts = [uint256(0), 7 ether + 1, 1, 1, 1];
        address[5] memory recipients = [CAROL, CAROL, address(0), address(token), address(vault)];
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectRevert(IMDIVIDENDS.InvalidConversion.selector);
            token.convertFees(amounts[i], 1, recipients[i]);
            assertEq(_state(), beforeState);
        }
        vm.expectRevert(IMDIVIDENDS.InvalidConversion.selector);
        token.convertFees(1, 0, CAROL);
        assertEq(_state(), beforeState);
    }

    function testConversionWithTaxedOrFailingRewardsRollsBackBothAssets() public {
        _collectFees();
        reward.mint(address(this), 100e6);
        reward.approve(address(vault), 100e6);
        bytes32 beforeState = _state();
        reward.setTax(true);
        vm.expectRevert(DividendVault.UnsupportedRewardToken.selector);
        token.convertFees(7 ether, 100e6, CAROL);
        assertEq(_state(), beforeState);
        assertEq(reward.balanceOf(address(this)), 100e6);
        assertEq(reward.allowance(address(this), address(vault)), 100e6);
        assertEq(reward.totalSupply(), 100e6);
        reward.setTax(false);
        reward.setFailure(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(reward)));
        token.convertFees(7 ether, 100e6, CAROL);
        assertEq(_state(), beforeState);
        reward.setFailure(false);
        token.convertFees(7 ether, 100e6, CAROL);
        assertEq(token.balanceOf(CAROL), 7 ether);
        assertEq(vault.shares(CAROL), 7 ether);
        assertEq(vault.queuedRewards(), 100e6);
        assertEq(reward.balanceOf(address(this)), 0);
    }

    function testMalformedRegistryResponsesDoNotExemptOrdinaryTransfers() public {
        _give(ALICE, 500 ether);
        bytes memory query = abi.encodeWithSignature("distributorOf(uint64)", uint64(42));
        bytes[4] memory replies = [bytes(""), new bytes(31), abi.encode(uint256(1) << 160), new bytes(64)];
        for (uint256 i; i < replies.length; ++i) {
            vm.mockCall(address(factory), query, replies[i]);
            assertEq(token.launchDistributor(), address(0));
            vm.prank(ALICE);
            token.transfer(BOB, 100 ether);
        }
        vm.mockCallRevert(address(factory), query, bytes("registry unavailable"));
        assertEq(token.launchDistributor(), address(0));
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        vm.clearMockedCalls();
        assertEq(token.balanceOf(BOB), 465 ether);
        assertEq(token.balanceOf(address(token)), 35 ether);
        assertEq(vault.shares(BOB), 465 ether);
        assertEq(token.launchDistributor(), DISTRIBUTOR);
    }

    function testConstructorRejectsRemainingInvalidAddresses() public {
        vm.expectRevert(IMDIVIDENDS.InvalidLaunchAddress.selector);
        new IMDIVIDENDS(address(factory), address(0), 42, address(this), address(reward));
        vm.expectRevert(IMDIVIDENDS.InvalidLaunchAddress.selector);
        new IMDIVIDENDS(address(factory), address(factory), 42, address(this), address(reward));
        vm.expectRevert(DividendVault.InvalidRewardToken.selector);
        new IMDIVIDENDS(address(factory), MANAGER, 42, address(this), ALICE);
        vm.expectRevert(DividendVault.InvalidRewardToken.selector);
        new DividendVault(address(this));
    }

    function _collectFees() private {
        _give(ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
    }

    function _state() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.balanceOf(CAROL),
                token.balanceOf(address(token)),
                vault.totalShares(),
                vault.shares(ALICE),
                vault.shares(BOB),
                vault.rewardPerShare(),
                vault.totalAllocated(),
                vault.totalFunded(),
                vault.queuedRewards(),
                vault.streamEmitted(),
                vault.earned(ALICE),
                reward.balanceOf(address(vault))
            )
        );
    }
}
