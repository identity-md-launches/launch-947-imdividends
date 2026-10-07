// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {NoReturnReward} from "./helpers/Mocks.sol";
import {IMDIVIDENDS} from "../src/IMDIVIDENDS.sol";
import {DividendVault} from "../src/DividendVault.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract DividendVaultTest is Fixture {
    function testProportionalPayoutAtTenMinutesInSixDecimalPoolTokens() public {
        _give(ALICE, 100 ether);
        _give(BOB, 300 ether);
        _start(400e6);
        uint256 start = block.timestamp;
        vm.warp(start + 599);
        vm.expectRevert(DividendVault.ClaimTooEarly.selector);
        vault.claimFor(ALICE);
        vm.warp(start + 600);
        vm.prank(CAROL);
        vault.claimFor(ALICE);
        vm.prank(BOB);
        vault.claim();
        assertApproxEqAbs(reward.balanceOf(ALICE), 100e6, 1);
        assertApproxEqAbs(reward.balanceOf(BOB), 300e6, 1);
        assertEq(reward.balanceOf(CAROL), 0);
        assertLe(vault.totalClaimed(), vault.totalFunded());
        assertEq(reward.balanceOf(address(vault)) + vault.totalClaimed(), vault.totalFunded());
        vm.expectRevert(DividendVault.ClaimTooEarly.selector);
        vault.claimFor(ALICE);
        vm.warp(start + 1_200);
        vm.expectRevert(DividendVault.NothingToClaim.selector);
        vault.claimFor(ALICE);
    }

    function testTransferPreservesEarnedRewardsAndNewHolderOnlyEarnsFutureRewards() public {
        token.setFeeBps(0);
        _give(ALICE, 100 ether);
        _start(600e6);
        vm.warp(block.timestamp + 300);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        assertApproxEqAbs(vault.earned(ALICE), 300e6, 1);
        assertEq(vault.earned(BOB), 0);
        vm.warp(block.timestamp + 300);
        vault.claimFor(ALICE);
        vault.claimFor(BOB);
        assertApproxEqAbs(reward.balanceOf(ALICE), 300e6, 1);
        assertApproxEqAbs(reward.balanceOf(BOB), 300e6, 1);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testFlashBalanceCannotCaptureRewards() public {
        token.setFeeBps(0);
        _give(ALICE, 1 ether);
        _start(600e6);
        vm.warp(block.timestamp + 599);
        _give(BOB, 100_000_000 ether);
        assertEq(vault.earned(BOB), 0);
        vm.prank(BOB);
        token.transfer(address(factory), 100_000_000 ether);
        vm.warp(block.timestamp + 1);
        assertEq(vault.earned(BOB), 0);
        vault.claimFor(ALICE);
        assertApproxEqAbs(reward.balanceOf(ALICE), 600e6, 1);
    }

    function testNoEligibleSharesCannotStartAndLaterEmptyTimeIsRequeued() public {
        _fund(600e6);
        vm.expectRevert(DividendVault.NoEligibleShares.selector);
        vault.distribute();
        _give(ALICE, 100 ether);
        vault.distribute();
        vm.warp(block.timestamp + 200);
        vm.prank(ALICE);
        token.transfer(address(factory), 100 ether);
        vm.warp(block.timestamp + 200);
        _give(BOB, 100 ether);
        assertEq(vault.queuedRewards(), 200e6);
        vm.warp(block.timestamp + 200);
        vault.claimFor(ALICE);
        vault.claimFor(BOB);
        assertApproxEqAbs(reward.balanceOf(ALICE), 200e6, 1);
        assertApproxEqAbs(reward.balanceOf(BOB), 200e6, 1);
        vault.distribute();
        assertEq(vault.streamAmount(), 200e6);
        vm.warp(block.timestamp + 600);
        vault.claimFor(BOB);
        assertApproxEqAbs(reward.balanceOf(BOB), 400e6, 1);
    }

    function testDonationsQueueWithoutDelayingCurrentStreamAndPeriodsRepeat() public {
        _give(ALICE, 1 ether);
        _start(600e6);
        uint256 finish = vault.streamEnd();
        vm.warp(block.timestamp + 300);
        _fund(300e6);
        assertEq(vault.streamEnd(), finish);
        vm.expectRevert(DividendVault.StreamActive.selector);
        vault.distribute();
        vm.warp(finish);
        vault.distribute();
        assertEq(vault.streamAmount(), 300e6);
        vault.claimFor(ALICE);
        assertApproxEqAbs(reward.balanceOf(ALICE), 600e6, 1);
        vm.warp(finish + 600);
        vault.claimFor(ALICE);
        assertApproxEqAbs(reward.balanceOf(ALICE), 900e6, 1);
        vm.expectRevert(DividendVault.InvalidAmount.selector);
        vault.distribute();
    }

    function testPausedFutureDistributionsDoNotStopActiveStreamClaimsOrTransfers() public {
        _give(ALICE, 100 ether);
        _start(600e6);
        uint256 finish = vault.streamEnd();
        token.configureVault(1 hours, false);
        assertEq(vault.streamEnd(), finish);
        vm.warp(finish);
        vault.claimFor(ALICE);
        assertApproxEqAbs(reward.balanceOf(ALICE), 600e6, 1);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 93 ether);
        vm.expectRevert(DividendVault.DistributionsDisabled.selector);
        vault.distribute();
        token.configureVault(1 hours, true);
        _fund(1e6);
        vault.distribute();
        assertEq(vault.streamEnd() - vault.streamStart(), 1 hours);
    }

    function testBoundedBatchSkipsDuplicatesAndCannotRedirectPayouts() public {
        _give(ALICE, 1 ether);
        _give(BOB, 1 ether);
        _start(100e6);
        address[] memory accounts = new address[](4);
        accounts[0] = ALICE;
        accounts[1] = ALICE;
        accounts[2] = BOB;
        accounts[3] = CAROL;
        assertEq(vault.process(accounts), 0);
        vm.warp(block.timestamp + 600);
        vm.prank(CAROL);
        uint256 paid = vault.process(accounts);
        assertApproxEqAbs(paid, 100e6, 2);
        assertEq(reward.balanceOf(CAROL), 0);
        assertApproxEqAbs(reward.balanceOf(ALICE), 50e6, 1);
        assertApproxEqAbs(reward.balanceOf(BOB), 50e6, 1);
        vm.expectRevert(DividendVault.InvalidBatch.selector);
        vault.process(new address[](0));
        vm.expectRevert(DividendVault.InvalidBatch.selector);
        vault.process(new address[](51));
    }

    function testPayoutFailurePreservesClaimAndDoesNotFreezeToken() public {
        _give(ALICE, 100 ether);
        _start(600e6);
        vm.warp(block.timestamp + 600);
        reward.setFailure(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(reward)));
        vault.claimFor(ALICE);
        assertEq(vault.totalClaimed(), 0);
        assertEq(vault.lastClaim(ALICE), 0);
        assertApproxEqAbs(vault.earned(ALICE), 600e6, 1);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        reward.setFailure(false);
        vault.claimFor(ALICE);
        assertApproxEqAbs(reward.balanceOf(ALICE), 600e6, 1);
    }

    function testOneBlockedRecipientDoesNotPreventIndividualClaims() public {
        _give(ALICE, 1 ether);
        _give(BOB, 1 ether);
        _start(100e6);
        vm.warp(block.timestamp + 600);
        reward.setBlocked(ALICE);
        address[] memory accounts = new address[](2);
        accounts[0] = BOB;
        accounts[1] = ALICE;
        vm.expectRevert();
        vault.process(accounts);
        assertEq(reward.balanceOf(BOB), 0);
        vault.claimFor(BOB);
        assertApproxEqAbs(reward.balanceOf(BOB), 50e6, 1);
        assertApproxEqAbs(vault.earned(ALICE), 50e6, 1);
    }

    function testReentrancyDuringPayoutCannotDoubleClaim() public {
        _give(ALICE, 1 ether);
        _start(100e6);
        vm.warp(block.timestamp + 600);
        reward.setCallback(address(vault), abi.encodeCall(vault.claimFor, (ALICE)));
        vault.claimFor(ALICE);
        assertFalse(reward.callbackSucceeded());
        assertApproxEqAbs(reward.balanceOf(ALICE), 100e6, 1);
        assertLe(vault.totalClaimed(), vault.totalFunded());
    }

    function testReentrancyDuringFundingCannotStartAnUnfundedStream() public {
        _give(ALICE, 1 ether);
        reward.setCallback(address(vault), abi.encodeCall(vault.distribute, ()));
        _fund(100e6);
        assertFalse(reward.callbackSucceeded());
        assertEq(vault.streamEnd(), 0);
        assertEq(vault.queuedRewards(), 100e6);
    }

    function testRejectsTaxedRewardsOnFundingAndOnPayout() public {
        _give(ALICE, 1 ether);
        reward.setTax(true);
        vm.expectRevert(DividendVault.UnsupportedRewardToken.selector);
        this.fundExternal(100e6);
        assertEq(vault.totalFunded(), 0);
        reward.setTax(false);
        _start(100e6);
        vm.warp(block.timestamp + 600);
        reward.setTax(true);
        vm.expectRevert(DividendVault.UnsupportedRewardToken.selector);
        vault.claimFor(ALICE);
        assertEq(vault.totalClaimed(), 0);
        assertEq(reward.balanceOf(address(vault)), 100e6);
    }

    function fundExternal(uint256 amount) external {
        _fund(amount);
    }

    function testInvalidFundingAndDuration() public {
        vm.expectRevert(DividendVault.InvalidAmount.selector);
        vault.fund(0);
        vm.expectRevert(DividendVault.InvalidAmount.selector);
        vault.fund(uint256(type(uint128).max) + 1);
        vm.expectRevert(DividendVault.InvalidDuration.selector);
        token.configureVault(599, true);
        vm.expectRevert(DividendVault.InvalidDuration.selector);
        token.configureVault(86_401, true);
        vm.expectRevert();
        vault.fund(1);
        assertEq(vault.totalFunded(), 0);
    }

    function testDirectRewardDonationsAreNotDoubleCounted() public {
        _give(ALICE, 1 ether);
        reward.mint(address(vault), 10e6);
        _start(100e6);
        assertEq(vault.totalFunded(), 100e6);
        vm.warp(block.timestamp + 600);
        vault.claimFor(ALICE);
        assertApproxEqAbs(reward.balanceOf(ALICE), 100e6, 1);
        assertGe(reward.balanceOf(address(vault)), 10e6);
    }

    function testSupportsNoReturnRewardTokensAndTinyAmounts() public {
        NoReturnReward other = new NoReturnReward();
        IMDIVIDENDS otherToken = factory.deploy(MANAGER, address(this), address(other));
        DividendVault otherVault = otherToken.dividendVault();
        factory.move(otherToken, ALICE, 1);
        other.mint(address(this), 1);
        other.approve(address(otherVault), 1);
        otherVault.fund(1);
        otherVault.distribute();
        vm.warp(block.timestamp + 600);
        otherVault.claimFor(ALICE);
        assertEq(other.balanceOf(ALICE), 1);
    }

    function testFractionalRewardsSurviveRepeatedBalanceCheckpoints() public {
        _give(ALICE, 3);
        _start(2);
        vm.warp(block.timestamp + 300);
        vm.prank(ALICE);
        token.transfer(ALICE, 0);
        assertEq(vault.earned(ALICE), 0);
        vm.warp(block.timestamp + 300);
        vault.claimFor(ALICE);
        assertEq(reward.balanceOf(ALICE), 1);
        // Account fractions carry into future distributions instead of being lost at each checkpoint.
        assertGt(vault.fractionalReward(ALICE), 0);
    }

    function testMaximumFundingDoesNotOverflowOrFreezeLaterBalanceChanges() public {
        _give(ALICE, 1);
        _start(vault.MAX_FUNDING());
        vm.warp(block.timestamp + 600);
        vault.claimFor(ALICE);
        assertEq(reward.balanceOf(ALICE), vault.MAX_FUNDING());
        _give(BOB, 100_000_000 ether);
        vm.prank(BOB);
        token.transfer(ALICE, 50_000_000 ether);
        assertEq(vault.earned(BOB), 0);
        assertEq(vault.earned(ALICE), 0);
        vm.expectRevert(DividendVault.InvalidAmount.selector);
        vault.fund(1);
    }

    function testFuzzChangingBalancesCannotClaimMoreThanFunded(uint128 funding, uint256 amount, uint256 elapsed)
        public
    {
        funding = uint128(bound(funding, 10, 1e30));
        amount = bound(amount, 1, token.totalSupply());
        elapsed = bound(elapsed, 0, 600);
        _give(ALICE, amount);
        _start(funding);
        uint256 finish = vault.streamEnd();
        vm.warp(block.timestamp + elapsed);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        vm.warp(finish);
        address[] memory accounts = new address[](2);
        accounts[0] = ALICE;
        accounts[1] = BOB;
        vault.process(accounts);
        uint256 paid = reward.balanceOf(ALICE) + reward.balanceOf(BOB);
        assertLe(paid, funding);
        assertEq(reward.balanceOf(address(vault)) + paid, funding);
        assertEq(vault.totalClaimed(), paid);
        assertApproxEqAbs(paid, funding, 2);
    }
}
