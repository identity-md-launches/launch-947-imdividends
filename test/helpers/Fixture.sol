// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDIVIDENDS} from "../../src/IMDIVIDENDS.sol";
import {DividendVault} from "../../src/DividendVault.sol";
import {FactoryMock, RewardMock} from "./Mocks.sol";

abstract contract Fixture is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant MANAGER = address(0xCAFE);
    address internal constant DISTRIBUTOR = address(0xD157);

    FactoryMock internal factory;
    RewardMock internal reward;
    IMDIVIDENDS internal token;
    DividendVault internal vault;

    function setUp() public virtual {
        vm.warp(1_000_000);
        reward = new RewardMock(6);
        factory = new FactoryMock();
        token = factory.deploy(MANAGER, address(this), address(reward));
        vault = token.dividendVault();
        factory.setDistributor(DISTRIBUTOR);
    }

    function _give(address account, uint256 amount) internal {
        factory.move(token, account, amount);
    }

    function _fund(uint256 amount) internal {
        reward.mint(address(this), amount);
        reward.approve(address(vault), amount);
        vault.fund(amount);
    }

    function _start(uint256 amount) internal {
        _fund(amount);
        vault.distribute();
    }
}
