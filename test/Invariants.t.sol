// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {RewardMock} from "./helpers/Mocks.sol";
import {IMDIVIDENDS} from "../src/IMDIVIDENDS.sol";
import {DividendVault} from "../src/DividendVault.sol";

contract DividendHandler is Test {
    IMDIVIDENDS private immutable token;
    DividendVault private immutable vault;
    RewardMock private immutable reward;
    address[6] private actors;

    constructor(IMDIVIDENDS token_, RewardMock reward_, address[6] memory actors_) {
        token = token_;
        vault = token_.dividendVault();
        reward = reward_;
        actors = actors_;
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
        uint256 amount = bound(amountSeed, 1, 1e18);
        reward.mint(address(this), amount);
        reward.approve(address(vault), amount);
        vault.fund(amount);
    }

    function convert(uint256 amountSeed, uint256 rewardSeed, uint256 recipientSeed) external {
        uint256 fees = token.balanceOf(address(token));
        if (fees == 0) return;
        uint256 amount = bound(amountSeed, 1, fees);
        uint256 rewards = bound(rewardSeed, 1, 1e18);
        reward.mint(address(this), rewards);
        reward.approve(address(vault), rewards);
        token.convertFees(amount, rewards, actors[recipientSeed % 3]);
    }

    function elapse(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 3_600));
    }

    function distribute() external {
        if (
            vault.distributionsEnabled() && vault.totalShares() > 0 && vault.queuedRewards() > 0
                && block.timestamp >= vault.streamEnd()
        ) vault.distribute();
    }

    function claim() external {
        address[] memory accounts = new address[](3);
        for (uint256 i; i < 3; ++i) {
            accounts[i] = actors[i];
        }
        vault.process(accounts);
    }

    function configure(uint16 rateSeed, uint32 durationSeed, bool enabled) external {
        token.setFeeBps(uint16(bound(rateSeed, 0, 1_000)));
        token.configureVault(uint32(bound(durationSeed, 600, 86_400)), enabled);
    }
}

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
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.move.selector;
        selectors[1] = handler.fund.selector;
        selectors[2] = handler.convert.selector;
        selectors[3] = handler.elapse.selector;
        selectors[4] = handler.distribute.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.configure.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantSupplyConservationAndExactShares() public view {
        uint256 balances = token.balanceOf(address(token));
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
        assertEq(balance + paid, vault.totalFunded());
        assertLe(earned, balance);
        assertLe(vault.totalClaimed(), vault.totalAllocated());
        assertEq(
            vault.totalAllocated() + vault.queuedRewards() + vault.streamAmount() - vault.streamEmitted(),
            vault.totalFunded()
        );
    }
}
