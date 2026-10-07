// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IMDIVIDENDS} from "../src/IMDIVIDENDS.sol";
import {RewardMock} from "./helpers/Mocks.sol";

/// @dev Test-only settlement actor. Real PoolManager unlock, liquidity, swap and settlement paths.
contract PoolActor is IUnlockCallback {
    IPoolManager private immutable manager;
    mapping(uint64 => address) public distributorOf;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function deploy(address owner, address rewards) external returns (IMDIVIDENDS) {
        return new IMDIVIDENDS(address(this), address(manager), 42, owner, rewards);
    }

    function setDistributor(address account) external {
        distributorOf[42] = account;
    }

    function move(IMDIVIDENDS token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }

    function seed(PoolKey memory key, int24 lower, int24 upper) external {
        manager.unlock(abi.encode(true, key, abi.encode(ModifyLiquidityParams(lower, upper, 1e21, bytes32(0)))));
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount) external {
        uint160 limit = zeroForOne ? 4_295_128_740 : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
        manager.unlock(abi.encode(false, key, abi.encode(SwapParams(zeroForOne, amount, limit))));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (bool seed_, PoolKey memory key, bytes memory params) = abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta delta;
        if (seed_) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
        } else {
            delta = manager.swap(key, abi.decode(params, (SwapParams)), "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        } else if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount));
                manager.settle();
            }
        }
    }
}

contract PoolIntegrationTest is Test {
    address private constant DISTRIBUTOR = address(0xD157);
    address private constant CLAIMANT = address(0xC1A1);

    function testNativePairSingleSidedSeedBuyAndSell() public {
        _exercise(address(0));
    }

    function testErc20PairCurrencyZeroSingleSidedSeedBuyAndSell() public {
        RewardMock implementation = new RewardMock(18);
        address pair = address(0x1000);
        vm.etch(pair, address(implementation).code);
        _exercise(pair);
    }

    function testErc20PairCurrencyOneSingleSidedSeedBuyAndSell() public {
        RewardMock implementation = new RewardMock(18);
        address pair = address(type(uint160).max - 1);
        vm.etch(pair, address(implementation).code);
        _exercise(pair);
    }

    function _exercise(address pair) private {
        PoolManager manager = new PoolManager(address(this));
        PoolActor factory = new PoolActor(manager);
        PoolActor trader = new PoolActor(manager);
        // For native pools, rewards must still be an ERC-20 (e.g. wrapped native currency).
        address rewards = pair == address(0) ? address(new RewardMock(18)) : pair;
        IMDIVIDENDS token = factory.deploy(address(this), rewards);
        assertEq(token.balanceOf(address(factory)), token.totalSupply());
        factory.setDistributor(DISTRIBUTOR);
        uint256 swarm = token.totalSupply() / 10;
        factory.move(token, DISTRIBUTOR, swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        token.transfer(CLAIMANT, swarm);
        assertEq(token.balanceOf(CLAIMANT), swarm);

        bool tokenIsZero = address(token) < pair;
        PoolKey memory key = PoolKey(
            Currency.wrap(tokenIsZero ? address(token) : pair),
            Currency.wrap(tokenIsZero ? pair : address(token)),
            3_000,
            60,
            IHooks(address(0))
        );
        manager.initialize(key, uint160(1 << 96));
        uint256 before = token.balanceOf(address(factory));
        factory.seed(key, tokenIsZero ? int24(0) : int24(-600), tokenIsZero ? int24(600) : int24(0));
        uint256 spent = before - token.balanceOf(address(factory));
        assertGt(spent, 0);
        assertEq(token.balanceOf(address(manager)), spent);
        assertLe(spent, token.totalSupply() / 10);

        if (pair == address(0)) vm.deal(address(trader), 10 ether);
        else RewardMock(pair).mint(address(trader), 10 ether);
        trader.swap(key, !tokenIsZero, -0.01 ether);
        uint256 bought = token.balanceOf(address(trader));
        assertGt(bought, 0);
        uint256 gross = spent - token.balanceOf(address(manager));
        uint256 fee = gross * token.feeBps() / 10_000;
        assertGt(fee, 0);
        assertEq(bought, gross - fee);
        assertEq(token.balanceOf(address(token)), fee);
        trader.swap(key, tokenIsZero, -int256(bought));
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(address(token)), fee);
        assertEq(token.balanceOf(address(manager)), spent - fee);
        assertEq(token.dividendVault().shares(address(manager)), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
