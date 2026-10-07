// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {IMDIVIDENDS} from "../src/IMDIVIDENDS.sol";
import {DividendVault} from "../src/DividendVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract IMDIVIDENDSTest is Fixture {
    function testMetadataAndWholeSupplyMintedToDeployer() public view {
        assertEq(token.name(), "IMDIVIDENDS");
        assertEq(token.symbol(), "DIVIDENDS");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(factory)), token.totalSupply());
        assertEq(token.owner(), address(this));
        assertEq(token.feeBps(), 700);
        assertEq(vault.totalShares(), 0);
        assertEq(vault.token(), address(token));
        assertEq(address(vault.rewardToken()), address(reward));
    }

    function testOrdinaryTransferTaxAndShares() public {
        _give(ALICE, 1_000 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(ALICE), 900 ether);
        assertEq(token.balanceOf(BOB), 93 ether);
        assertEq(token.balanceOf(address(token)), 7 ether);
        assertEq(vault.shares(ALICE), 900 ether);
        assertEq(vault.shares(BOB), 93 ether);
        assertEq(vault.totalShares(), 993 ether);
        assertEq(vault.shares(address(token)), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function testTransferFromSpendsGrossAllowanceAndInfiniteAllowance() public {
        _give(ALICE, 1_000 ether);
        vm.prank(ALICE);
        token.approve(CAROL, 100 ether);
        vm.prank(CAROL);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.allowance(ALICE, CAROL), 0);
        assertEq(token.balanceOf(BOB), 93 ether);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, CAROL, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
        vm.prank(ALICE);
        token.approve(CAROL, type(uint256).max);
        vm.prank(CAROL);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.allowance(ALICE, CAROL), type(uint256).max);
    }

    function testLaunchAllocationsClaimsAndPoolFlowsAreExact() public {
        uint256 swarm = token.totalSupply() / 10;
        _give(DISTRIBUTOR, swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(vault.shares(DISTRIBUTOR), 0);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, swarm);
        assertEq(token.balanceOf(ALICE), swarm);
        _give(MANAGER, 1_000 ether);
        vm.prank(MANAGER);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 100 ether);
        vm.prank(BOB);
        token.approve(CAROL, 100 ether);
        vm.prank(CAROL);
        token.transferFrom(BOB, MANAGER, 100 ether);
        assertEq(token.balanceOf(MANAGER), 1_000 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(vault.shares(MANAGER), 0);
    }

    function testExemptOperatorsStillNeedApproval() public {
        _give(ALICE, 100 ether);
        vm.prank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, MANAGER, 0, 100 ether));
        token.transferFrom(ALICE, BOB, 100 ether);
        vm.prank(ALICE);
        token.approve(MANAGER, 100 ether);
        vm.prank(MANAGER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 100 ether);
    }

    function testOwnerControlsFeesAndVaultButCannotSetConfiscatoryFee() public {
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        token.setFeeBps(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        token.configureVault(600, false);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        token.convertFees(1, 1, ALICE);
        vm.expectRevert(DividendVault.OnlyToken.selector);
        vault.configure(600, false);
        vm.expectRevert(DividendVault.OnlyToken.selector);
        vault.setShares(ALICE, 1);
        vm.expectRevert(DividendVault.OnlyToken.selector);
        vault.fundFrom(BOB, 1);
        vm.stopPrank();
        vm.expectRevert(IMDIVIDENDS.FeeTooHigh.selector);
        token.setFeeBps(1_001);
        token.setFeeBps(1_000);
        _give(ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 90 ether);
        token.setFeeBps(0);
        vm.prank(BOB);
        token.transfer(ALICE, 90 ether);
        assertEq(token.balanceOf(ALICE), 90 ether);
        token.configureVault(1 hours, false);
        assertEq(vault.distributionDuration(), 1 hours);
        assertFalse(vault.distributionsEnabled());
    }

    function testTwoStepOwnerTransfer() public {
        token.transferOwnership(ALICE);
        assertEq(token.owner(), address(this));
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        token.acceptOwnership();
        vm.prank(ALICE);
        token.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.setFeeBps(1);
        vm.prank(ALICE);
        token.setFeeBps(1);
        assertEq(token.owner(), ALICE);
    }

    function testAtomicFeeConversionFundsRewardsAndTransfersWholeFees() public {
        _give(ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        reward.mint(address(this), 70e6);
        reward.approve(address(vault), 70e6);
        token.convertFees(7 ether, 70e6, CAROL);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(CAROL), 7 ether);
        assertEq(vault.queuedRewards(), 70e6);
        assertEq(reward.balanceOf(address(vault)), 70e6);
        assertEq(reward.allowance(address(this), address(vault)), 0);
        assertEq(vault.totalShares(), 100 ether);
    }

    function testConversionFailureCannotReleaseFees() public {
        _give(ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        vm.expectRevert();
        token.convertFees(7 ether, 70e6, CAROL);
        assertEq(token.balanceOf(address(token)), 7 ether);
        assertEq(token.balanceOf(CAROL), 0);
        assertEq(vault.totalFunded(), 0);
        vm.expectRevert(IMDIVIDENDS.InvalidConversion.selector);
        token.convertFees(8 ether, 1, CAROL);
        vm.expectRevert(IMDIVIDENDS.InvalidConversion.selector);
        token.convertFees(1, 0, CAROL);
        vm.expectRevert(IMDIVIDENDS.InvalidConversion.selector);
        token.convertFees(1, 1, address(0));
    }

    function testSelfZeroAndDustTransfers() public {
        _give(ALICE, 100);
        vm.startPrank(ALICE);
        token.transfer(ALICE, 100);
        token.transfer(BOB, 0);
        token.transfer(BOB, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 99);
        assertEq(token.balanceOf(BOB), 1);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(vault.totalShares(), 100);
    }

    function testInsufficientBalanceAndZeroRecipientRevertAtomically() public {
        _give(ALICE, 100 ether);
        vm.startPrank(ALICE);
        vm.expectRevert();
        token.transfer(BOB, 101 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(vault.totalShares(), 100 ether);
    }

    function testNoMintFreezeSeizeOrAllowanceBypass() public {
        _give(ALICE, 100 ether);
        string[6] memory signatures = [
            "mint(address,uint256)",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, 100 ether));
            assertFalse(ok);
        }
        vm.expectRevert();
        token.transferFrom(ALICE, address(this), 1);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        assertGt(token.balanceOf(BOB), 0);
    }

    function testInvalidConstructorParametersAndStandaloneDeployment() public {
        vm.expectRevert(IMDIVIDENDS.InvalidLaunchAddress.selector);
        new IMDIVIDENDS(address(0), MANAGER, 42, address(this), address(reward));
        vm.expectRevert(DividendVault.InvalidRewardToken.selector);
        new IMDIVIDENDS(address(factory), MANAGER, 42, address(this), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new IMDIVIDENDS(address(factory), MANAGER, 42, address(0), address(reward));
        IMDIVIDENDS standalone = new IMDIVIDENDS(address(this), MANAGER, 1, address(this), address(reward));
        assertEq(standalone.balanceOf(address(this)), standalone.totalSupply());
        assertEq(standalone.launchDistributor(), address(0));
        standalone.transfer(ALICE, 100 ether);
        assertEq(standalone.balanceOf(ALICE), 100 ether);
    }

    function testRuntimeHasNoProhibitedOpcodesAndFitsSizeLimit() public view {
        _checkRuntime(address(token));
        _checkRuntime(address(vault));
    }

    function _checkRuntime(address target) private view {
        bytes memory code = target.code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
            }
        }
    }

    function testFuzzTaxConservesSupplyAndTracksBalances(uint256 amount, uint16 rate) public {
        amount = bound(amount, 0, token.totalSupply());
        rate = uint16(bound(rate, 0, token.MAX_FEE_BPS()));
        token.setFeeBps(rate);
        _give(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        uint256 fee = amount * rate / 10_000;
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(token.balanceOf(BOB), amount - fee);
        assertEq(vault.totalShares(), amount - fee);
        assertEq(token.balanceOf(address(factory)) + token.balanceOf(BOB) + fee, token.totalSupply());
    }
}
