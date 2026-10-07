// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DividendVault} from "./DividendVault.sol";

/// @notice Fixed-supply DIVIDENDS token, with a 7% ordinary-transfer tax and pool-token rewards.
contract IMDIVIDENDS is ERC20, Ownable2Step, ReentrancyGuard {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint16 public constant MAX_FEE_BPS = 1_000;
    uint16 public feeBps = 700;

    address public immutable factory;
    address public immutable poolManager;
    uint64 public immutable launchNumber;
    DividendVault public immutable dividendVault;

    error InvalidLaunchAddress();
    error FeeTooHigh();
    error InvalidConversion();
    error UnsafeRenunciation();

    event FeeChanged(uint16 feeBps);
    event FeesConverted(address indexed payer, address indexed recipient, uint256 tokens, uint256 rewards);

    /// @param initialOwner The requester, independently of the factory receiving the minted supply.
    /// @param rewardToken The immutable, non-rebasing ERC-20 pool/paired token used for dividends.
    constructor(address factory_, address poolManager_, uint64 launchNumber_, address initialOwner, address rewardToken)
        ERC20("IMDIVIDENDS", "DIVIDENDS")
        Ownable(initialOwner)
    {
        if (factory_ == address(0) || poolManager_ == address(0) || factory_ == poolManager_) {
            revert InvalidLaunchAddress();
        }
        factory = factory_;
        poolManager = poolManager_;
        launchNumber = launchNumber_;
        dividendVault = new DividendVault(rewardToken);
        // The only mint in this contract. The entire supply belongs to the constructor caller.
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeChanged(newFeeBps);
    }

    function configureVault(uint32 duration, bool enabled) external onlyOwner {
        dividendVault.configure(duration, enabled);
    }

    /// @notice Renounce only after retiring the tax and keeping public reward distribution available.
    function renounceOwnership() public override onlyOwner {
        if (feeBps != 0 || balanceOf(address(this)) != 0 || !dividendVault.distributionsEnabled()) {
            revert UnsafeRenunciation();
        }
        super.renounceOwnership();
    }

    /// @notice Atomically buy collected fees with owner-supplied reward tokens.
    /// @dev Owner approves the vault for rewardAmount first. Pricing is an explicit owner trust
    /// assumption; this avoids an unconfigured router or manipulable spot-price oracle.
    function convertFees(uint256 tokenAmount, uint256 rewardAmount, address recipient) external onlyOwner nonReentrant {
        if (
            tokenAmount == 0 || rewardAmount == 0 || tokenAmount > balanceOf(address(this)) || recipient == address(0)
                || recipient == address(this) || recipient == address(dividendVault)
        ) revert InvalidConversion();
        dividendVault.fundFrom(msg.sender, rewardAmount);
        _transfer(address(this), recipient, tokenAmount);
        emit FeesConverted(msg.sender, recipient, tokenAmount, rewardAmount);
    }

    /// @notice Runtime lookup because the distributor's address depends on the deployed token.
    /// @dev A missing registry (e.g. standalone deployment) returns zero, without blocking transfers.
    function launchDistributor() public view returns (address distributor) {
        (bool success, bytes memory result) =
            factory.staticcall{gas: 30_000}(abi.encodeWithSignature("distributorOf(uint64)", launchNumber));
        if (success && result.length == 32) {
            uint256 value = abi.decode(result, (uint256));
            if (value <= type(uint160).max) distributor = address(uint160(value));
        }
    }

    function isDividendExcluded(address account) external view returns (bool) {
        return _excluded(account, launchDistributor());
    }

    /// @notice Refresh eligibility after registry registration without requiring a holder transfer.
    /// @dev Checkpoints past rewards; cannot undo accrual before registration/synchronization.
    function syncShares(address account) external {
        dividendVault.setShares(account, _excluded(account, launchDistributor()) ? 0 : balanceOf(account));
    }

    function _excluded(address account, address distributor) private view returns (bool) {
        return account == address(0) || account == address(this) || account == address(dividendVault)
            || account == factory || account == poolManager || account == distributor;
    }

    function _update(address from, address to, uint256 amount) internal override {
        address distributor = launchDistributor();
        // Settlement deposits must arrive whole. Tax PoolManager outflows, including buys and
        // claim redemptions, so a permissionless settle/take relay cannot bypass the transfer tax.
        bool exempt = (from != poolManager && _excluded(from, distributor)) || _excluded(to, distributor)
            || msg.sender == factory || (distributor != address(0) && msg.sender == distributor);
        uint256 fee = (exempt || from == to) ? 0 : (amount * feeBps) / 10_000;
        if (fee != 0) super._update(from, address(this), fee);
        super._update(from, to, amount - fee);

        // Only internal vault accounting runs on transfers; failed reward payouts cannot freeze ERC-20 transfers.
        // Registration may have happened after the distributor received its allocation.
        if (distributor != address(0) && dividendVault.shares(distributor) != 0) {
            dividendVault.setShares(distributor, 0);
        }
        dividendVault.setShares(from, _excluded(from, distributor) ? 0 : balanceOf(from));
        if (from != to) dividendVault.setShares(to, _excluded(to, distributor) ? 0 : balanceOf(to));
    }
}
