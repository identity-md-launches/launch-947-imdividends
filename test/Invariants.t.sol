// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {RewardMock} from "./helpers/Mocks.sol";
import {IMDIVIDENDS} from "../src/IMDIVIDENDS.sol";
import {DividendVault} from "../src/DividendVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract DividendHandler is Test {
    IMDIVIDENDS private immutable token;
    DividendVault private immutable vault;
    RewardMock private immutable reward;
    address[6] private actors;
    address private constant OUTSIDER = address(0xBAD);

    // Independent inputs/outputs, rather than copies of the vault's aggregate counters.
    uint256 public ghostFunding;
    uint256 public ghostDonations;
    uint256 public ghostPaid;
    mapping(address => uint256) public ghostPaidTo;
    mapping(address => uint256) public ghostLastClaim;
    uint256 public immutable initialClaimAt;
    uint16 public expectedFee = 700;
    uint32 public expectedDuration = 600;
    bool public expectedEnabled = true;

    constructor(IMDIVIDENDS token_, RewardMock reward_, address[6] memory actors_) {
        token = token_;
        vault = token_.dividendVault();
        reward = reward_;
        actors = actors_;
        initialClaimAt = block.timestamp + 600;
    }

    function acceptOwnership() external {
        token.acceptOwnership();
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function fund(uint256 amountSeed) external {
        if (!vault.distributionsEnabled()) return;
        uint256 amount = bound(amountSeed, 1, 1e18);
        reward.mint(address(this), amount);
        reward.approve(address(vault), amount);
        vault.fund(amount);
        ghostFunding += amount;
    }

    function donate(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e18);
        reward.mint(address(this), amount);
        reward.transfer(address(vault), amount);
        ghostDonations += amount;
    }

    function convert(uint256 amountSeed, uint256 rewardSeed, uint256 recipientSeed) external {
        if (!vault.distributionsEnabled()) return;
        uint256 fees = token.balanceOf(address(token));
        if (fees == 0) return;
        uint256 amount = bound(amountSeed, 1, fees);
        uint256 rewards = bound(rewardSeed, 1, 1e18);
        reward.mint(address(this), rewards);
        reward.approve(address(vault), rewards);
        token.convertFees(amount, rewards, actors[recipientSeed % 3]);
        ghostFunding += rewards;
    }

    function elapse(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 3_600));
    }

    function sync(uint256 accountSeed) external {
        uint256 index = accountSeed % (actors.length + 3);
        address account;
        if (index < actors.length) account = actors[index];
        else if (index == actors.length) account = address(token);
        else if (index == actors.length + 1) account = address(vault);
        // The remaining case exercises address(0).
        uint256 balance = token.balanceOf(account);
        uint256 earned = vault.earned(account);
        uint256 totalShares = vault.totalShares();
        vm.startPrank(OUTSIDER);
        token.syncShares(account);
        assertEq(vault.earned(account), earned, "sync changed previously earned rewards");
        token.syncShares(account);
        vm.stopPrank();
        assertEq(vault.earned(account), earned, "repeated sync changed rewards");
        assertEq(token.balanceOf(account), balance, "sync moved holder tokens");
        assertEq(vault.totalShares(), totalShares, "sync changed already current shares");
    }

    function distribute() external {
        if (
            vault.distributionsEnabled() && vault.totalShares() > 0 && vault.queuedRewards() > 0
                && block.timestamp >= vault.streamEnd()
        ) vault.distribute();
    }

    function claim() external {
        address[] memory accounts = new address[](3);
        uint256[3] memory amounts;
        uint256 expected;
        for (uint256 i; i < 3; ++i) {
            accounts[i] = actors[i];
            if (block.timestamp >= _nextClaimAt(accounts[i])) {
                amounts[i] = vault.earned(accounts[i]);
                expected += amounts[i];
            }
        }
        assertEq(vault.process(accounts), expected, "batch payout differs from claimable earnings");
        for (uint256 i; i < 3; ++i) {
            _recordClaim(accounts[i], amounts[i]);
        }
    }

    function claimOne(uint256 actorSeed, bool self) external {
        address account = actors[actorSeed % 3];
        uint256 next = _nextClaimAt(account);
        uint256 expected = vault.earned(account);
        uint256 beforePaid = vault.totalClaimed();
        if (block.timestamp < next) {
            vm.expectRevert(DividendVault.ClaimTooEarly.selector);
        } else if (expected == 0) {
            vm.expectRevert(DividendVault.NothingToClaim.selector);
        }
        uint256 actual;
        if (self) {
            vm.prank(account);
            actual = vault.claim();
        } else {
            vm.prank(OUTSIDER);
            actual = vault.claimFor(account);
        }
        if (block.timestamp >= next && expected > 0) {
            assertEq(actual, expected, "claim differs from preview");
            _recordClaim(account, expected);
        } else {
            assertEq(vault.totalClaimed(), beforePaid);
        }
    }

    function delegatedMove(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool infinite) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        token.approve(OUTSIDER, infinite ? type(uint256).max : amount);
        vm.prank(OUTSIDER);
        token.transferFrom(from, to, amount);
        assertEq(token.allowance(from, OUTSIDER), infinite ? type(uint256).max : 0);
    }

    function insufficientApproval(uint256 actorSeed, uint256 amountSeed) external {
        address from = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 1, token.totalSupply());
        uint256 balance = token.balanceOf(from);
        uint256 fees = token.balanceOf(address(token));
        vm.prank(from);
        token.approve(OUTSIDER, amount - 1);
        vm.prank(OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, OUTSIDER, amount - 1, amount)
        );
        token.transferFrom(from, OUTSIDER, amount);
        assertEq(token.allowance(from, OUTSIDER), amount - 1);
        assertEq(token.balanceOf(from), balance);
        assertEq(token.balanceOf(address(token)), fees);
    }

    function emptyEligibleBalances() external {
        for (uint256 i; i < 3; ++i) {
            uint256 balance = token.balanceOf(actors[i]);
            vm.prank(actors[i]);
            token.transfer(actors[3], balance);
        }
        assertEq(vault.totalShares(), 0);
    }

    function sendToInfrastructure(uint256 actorSeed, uint256 amountSeed, bool toVault) external {
        address from = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        address recipient = toVault ? address(vault) : address(token);
        uint256 beforeBalance = token.balanceOf(recipient);
        vm.prank(from);
        token.transfer(recipient, amount);
        assertEq(token.balanceOf(recipient), beforeBalance + amount);
        assertEq(vault.shares(recipient), 0);
    }

    function unauthorizedAdministration(uint16 rate, uint32 duration, bool enabled) external {
        vm.startPrank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OUTSIDER));
        token.setFeeBps(rate);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OUTSIDER));
        token.configureVault(duration, enabled);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OUTSIDER));
        token.convertFees(1, 1, OUTSIDER);
        vm.expectRevert(DividendVault.OnlyToken.selector);
        vault.configure(duration, enabled);
        vm.expectRevert(DividendVault.OnlyToken.selector);
        vault.setShares(OUTSIDER, 1);
        vm.expectRevert(DividendVault.OnlyToken.selector);
        vault.fundFrom(actors[0], 1);
        vm.stopPrank();
    }

    function configure(uint16 rateSeed, uint32 durationSeed, bool enabled) external {
        expectedFee = uint16(bound(rateSeed, 0, 1_000));
        expectedDuration = uint32(bound(durationSeed, 600, 86_400));
        expectedEnabled = enabled;
        uint256 end = vault.streamEnd();
        token.setFeeBps(expectedFee);
        token.configureVault(expectedDuration, enabled);
        assertEq(vault.streamEnd(), end, "configuration changed active stream");
    }

    function _nextClaimAt(address account) private view returns (uint256) {
        uint256 next = ghostLastClaim[account] + 600;
        return next > initialClaimAt ? next : initialClaimAt;
    }

    function _recordClaim(address account, uint256 amount) private {
        if (amount == 0) return;
        assertGe(block.timestamp, _nextClaimAt(account), "paid before cooldown");
        ghostPaid += amount;
        ghostPaidTo[account] += amount;
        ghostLastClaim[account] = block.timestamp;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract DividendInvariantTest is Fixture {
    DividendHandler private handler;
    address[6] private actors;

    function setUp() public override {
        super.setUp();
        actors = [ALICE, BOB, CAROL, address(factory), MANAGER, DISTRIBUTOR];
        _give(ALICE, 1_000_000 ether);
        _give(BOB, 1_000_000 ether);
        _give(CAROL, 1_000_000 ether);
        handler = new DividendHandler(token, reward, actors);
        token.transferOwnership(address(handler));
        handler.acceptOwnership();
        // Start with funded liabilities so even short random sequences exercise live accounting.
        handler.fund(600e6);
        handler.distribute();
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.move.selector;
        selectors[1] = handler.fund.selector;
        selectors[2] = handler.convert.selector;
        selectors[3] = handler.elapse.selector;
        selectors[4] = handler.distribute.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.configure.selector;
        selectors[7] = handler.donate.selector;
        selectors[8] = handler.claimOne.selector;
        selectors[9] = handler.delegatedMove.selector;
        selectors[10] = handler.insufficientApproval.selector;
        selectors[11] = handler.emptyEligibleBalances.selector;
        selectors[12] = handler.sendToInfrastructure.selector;
        selectors[13] = handler.unauthorizedAdministration.selector;
        selectors[14] = handler.sync.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantSupplyConservationAndExactShares() public view {
        uint256 balances = token.balanceOf(address(token)) + token.balanceOf(address(vault));
        uint256 eligible;
        for (uint256 i; i < actors.length; ++i) {
            balances += token.balanceOf(actors[i]);
            if (i < 3) {
                assertEq(vault.shares(actors[i]), token.balanceOf(actors[i]));
                eligible += token.balanceOf(actors[i]);
            } else {
                assertEq(vault.shares(actors[i]), 0);
            }
        }
        assertEq(balances, 1_000_000_000 ether);
        assertEq(token.totalSupply(), balances);
        assertEq(vault.totalShares(), eligible);
        assertEq(vault.shares(address(token)), 0);
        assertEq(vault.shares(address(vault)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariantRewardsAreSolventAndNeverCreated() public view {
        uint256 paid;
        uint256 earned;
        for (uint256 i; i < 3; ++i) {
            paid += reward.balanceOf(actors[i]);
            earned += vault.earned(actors[i]);
        }
        uint256 balance = reward.balanceOf(address(vault));
        assertEq(vault.totalClaimed(), paid);
        assertEq(balance + paid, handler.ghostFunding() + handler.ghostDonations());
        assertEq(vault.totalFunded(), handler.ghostFunding());
        assertEq(paid, handler.ghostPaid());
        assertLe(earned, balance);
        assertLe(earned + paid, handler.ghostFunding(), "unfunded donations became liabilities");
        assertLe(vault.totalClaimed(), vault.totalAllocated());
        assertEq(
            vault.totalAllocated() + vault.queuedRewards() + vault.streamAmount() - vault.streamEmitted(),
            vault.totalFunded()
        );
    }

    function invariantClaimHistoryAndOwnerControlsMatchIndependentModel() public view {
        for (uint256 i; i < 3; ++i) {
            address account = actors[i];
            assertEq(reward.balanceOf(account), handler.ghostPaidTo(account));
            assertEq(vault.lastClaim(account), handler.ghostLastClaim(account));
            uint256 next = handler.ghostLastClaim(account) + 600;
            if (next < handler.initialClaimAt()) next = handler.initialClaimAt();
            assertEq(vault.nextClaimAt(account), next);
            assertLe(vault.paidIndex(account), vault.rewardPerShare());
            assertLt(vault.fractionalReward(account), vault.SCALE());
        }
        assertEq(token.owner(), address(handler));
        assertEq(token.feeBps(), handler.expectedFee());
        assertEq(vault.distributionDuration(), handler.expectedDuration());
        assertEq(vault.distributionsEnabled(), handler.expectedEnabled());
    }

    function afterInvariant() public {
        // Settle all current liabilities even if new distributions were disabled.
        uint256 ready = vault.streamEnd();
        if (ready < block.timestamp + 600) ready = block.timestamp + 600;
        vm.warp(ready);
        handler.claim();
        for (uint256 i; i < 3; ++i) {
            assertEq(vault.earned(actors[i]), 0, "mature claim could not be fully paid");
        }
        invariantSupplyConservationAndExactShares();
        invariantRewardsAreSolventAndNeverCreated();
        invariantClaimHistoryAndOwnerControlsMatchIndependentModel();
    }
}
