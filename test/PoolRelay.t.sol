// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IMDIVIDENDS} from "../src/IMDIVIDENDS.sol";
import {FactoryMock, RewardMock} from "./helpers/Mocks.sol";

/// @dev Unprivileged test helper exercising flash accounting without a pool or swap.
contract PoolRelay is IUnlockCallback {
    IPoolManager private immutable manager;
    IERC20 private immutable token;

    constructor(IPoolManager manager_, IERC20 token_) {
        manager = manager_;
        token = token_;
    }

    function send(address to, uint256 amount, bool claims) external {
        manager.unlock(abi.encode(msg.sender, to, amount, claims, false));
    }

    function redeem(uint256 amount) external {
        manager.unlock(abi.encode(msg.sender, msg.sender, amount, false, true));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address from, address to, uint256 amount, bool claims, bool redemption) =
            abi.decode(data, (address, address, uint256, bool, bool));
        Currency currency = Currency.wrap(address(token));
        uint256 id = uint160(address(token));
        if (redemption) {
            manager.burn(from, id, amount);
        } else {
            manager.sync(currency);
            require(token.transferFrom(from, address(manager), amount));
            require(manager.settle() == amount);
        }
        if (claims) manager.mint(to, id, amount);
        else manager.take(currency, to, amount);
        return "";
    }
}

contract PoolRelayTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    PoolManager private manager;
    IMDIVIDENDS private token;
    PoolRelay private relay;

    function setUp() public {
        manager = new PoolManager(address(this));
        FactoryMock factory = new FactoryMock();
        token = factory.deploy(address(manager), address(this), address(new RewardMock(18)));
        relay = new PoolRelay(manager, IERC20(address(token)));
        factory.move(token, ALICE, 1_000 ether);
    }

    function testFuzzSettleTakeCollectsSameFeeAsAnOrdinaryTransfer(uint256 amount, uint16 feeBps) public {
        amount = bound(amount, 1, 1_000 ether);
        feeBps = uint16(bound(feeBps, 0, token.MAX_FEE_BPS()));
        token.setFeeBps(feeBps);
        vm.startPrank(ALICE);
        token.approve(address(relay), amount);
        relay.send(BOB, amount, false);
        vm.stopPrank();
        uint256 fee = amount * feeBps / 10_000;
        assertEq(token.balanceOf(ALICE), 1_000 ether - amount);
        assertEq(token.balanceOf(BOB), amount - fee);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.allowance(ALICE, address(relay)), 0);
        assertEq(token.dividendVault().shares(address(manager)), 0);
        assertEq(token.dividendVault().shares(BOB), amount - fee);
        assertEq(token.dividendVault().totalShares(), 1_000 ether - fee);
    }

    function testErc6909ClaimsAreTaxedWhenBurnedAndTaken() public {
        uint256 amount = 1_000 ether;
        uint256 id = uint160(address(token));
        vm.startPrank(ALICE);
        token.approve(address(relay), amount);
        relay.send(BOB, amount, true);
        vm.stopPrank();
        assertEq(manager.balanceOf(BOB, id), amount);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(manager)), amount);
        assertEq(token.dividendVault().totalShares(), 0);
        vm.startPrank(BOB);
        vm.expectRevert();
        relay.redeem(amount);
        assertEq(manager.balanceOf(BOB, id), amount);
        manager.setOperator(address(relay), true);
        relay.redeem(amount);
        vm.stopPrank();
        assertEq(manager.balanceOf(BOB, id), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(BOB), 930 ether);
        assertEq(token.balanceOf(address(token)), 70 ether);
        assertEq(token.dividendVault().shares(address(manager)), 0);
        assertEq(token.dividendVault().shares(BOB), 930 ether);
    }

    function testRelayCannotMoveTokensWithoutAllowance() public {
        vm.prank(ALICE);
        vm.expectRevert();
        relay.send(BOB, 1_000 ether, false);
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}
