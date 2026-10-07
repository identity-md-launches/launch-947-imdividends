// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMDIVIDENDS} from "../../src/IMDIVIDENDS.sol";

contract FactoryMock {
    mapping(uint64 => address) public distributorOf;

    function deploy(address manager, address owner, address rewards) external returns (IMDIVIDENDS) {
        return new IMDIVIDENDS(address(this), manager, 42, owner, rewards);
    }

    function setDistributor(address distributor) external {
        distributorOf[42] = distributor;
    }

    function move(IMDIVIDENDS token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

contract RewardMock is ERC20 {
    uint8 private immutable precision;
    bool public fail;
    bool public taxed;
    address public blocked;
    address public callback;
    bytes public callbackData;
    bool public callbackSucceeded;

    constructor(uint8 decimals_) ERC20("Pool token", "POOL") {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailure(bool value) external {
        fail = value;
    }

    function setTax(bool value) external {
        taxed = value;
    }

    function setBlocked(address account) external {
        blocked = account;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (fail || to == blocked) return false;
        if (callback != address(0)) (callbackSucceeded,) = callback.call(callbackData);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (fail) return false;
        if (callback != address(0)) (callbackSucceeded,) = callback.call(callbackData);
        return super.transferFrom(from, to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (taxed && from != address(0)) {
            uint256 fee = amount / 100;
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}

/// @dev Deliberately lacks boolean return values, like some deployed ERC-20 tokens.
contract NoReturnReward {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
