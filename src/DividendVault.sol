// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Streams funded pool-token dividends to holders, with a ten-minute payout cooldown.
/// @dev The immutable DIVIDENDS token updates shares after every balance change. No holder loop
/// is needed to accrue rewards. Only the token can configure this vault on its owner's behalf.
contract DividendVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SCALE = 1 << 128;
    uint256 public constant MAX_FUNDING = type(uint128).max;
    uint256 public constant CLAIM_INTERVAL = 10 minutes;
    uint256 public constant MAX_BATCH = 50;

    address public immutable token;
    IERC20 public immutable rewardToken;
    uint256 public immutable firstClaimAt;
    uint32 public distributionDuration = 10 minutes;
    bool public distributionsEnabled = true;

    uint256 public totalShares;
    uint256 public rewardPerShare;
    uint256 public queuedRewards;
    uint256 public totalFunded;
    uint256 public totalAllocated;
    uint256 public totalClaimed;
    uint256 public streamStart;
    uint256 public streamEnd;
    uint256 public streamAmount;
    uint256 public streamEmitted;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public paidIndex;
    mapping(address => uint256) public accrued;
    mapping(address => uint256) public fractionalReward;
    mapping(address => uint256) public lastClaim;

    error OnlyToken();
    error InvalidRewardToken();
    error InvalidAmount();
    error UnsupportedRewardToken();
    error InvalidDuration();
    error DistributionsDisabled();
    error StreamActive();
    error NoEligibleShares();
    error ClaimTooEarly();
    error NothingToClaim();
    error InvalidBatch();

    event Funded(address indexed payer, uint256 amount);
    event DistributionStarted(uint256 amount, uint256 start, uint256 end);
    event Claimed(address indexed account, uint256 amount);
    event VaultConfigured(uint32 duration, bool enabled);

    modifier onlyToken() {
        if (msg.sender != token) revert OnlyToken();
        _;
    }

    constructor(address rewardToken_) {
        if (rewardToken_ == msg.sender || rewardToken_.code.length == 0) revert InvalidRewardToken();
        token = msg.sender;
        rewardToken = IERC20(rewardToken_);
        firstClaimAt = block.timestamp + CLAIM_INTERVAL;
    }

    /// @notice Donate reward-token base units to the next distribution period.
    /// @dev Donations never reset an active stream or the payout clock.
    function fund(uint256 amount) external nonReentrant {
        _fund(msg.sender, amount);
    }

    /// @dev Used by the token's owner-funded, atomic fee conversion.
    function fundFrom(address payer, uint256 amount) external onlyToken nonReentrant {
        _fund(payer, amount);
    }

    function _fund(address payer, uint256 amount) private {
        if (amount == 0 || amount > MAX_FUNDING - totalFunded) revert InvalidAmount();
        uint256 beforeBalance = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(payer, address(this), amount);
        if (rewardToken.balanceOf(address(this)) != beforeBalance + amount) revert UnsupportedRewardToken();
        totalFunded += amount;
        queuedRewards += amount;
        emit Funded(payer, amount);
    }

    /// @notice Anyone can begin the next funded period once the previous one has finished.
    /// @dev Streaming, instead of an instantaneous balance snapshot, prevents flash-loan capture.
    function distribute() external nonReentrant {
        if (!distributionsEnabled) revert DistributionsDisabled();
        if (block.timestamp < streamEnd) revert StreamActive();
        _checkpoint();
        if (totalShares == 0) revert NoEligibleShares();
        uint256 amount = queuedRewards;
        if (amount == 0) revert InvalidAmount();
        queuedRewards = 0;
        streamAmount = amount;
        streamEmitted = 0;
        streamStart = block.timestamp;
        streamEnd = block.timestamp + distributionDuration;
        emit DistributionStarted(amount, streamStart, streamEnd);
    }

    /// @notice Configure future periods; an existing stream and earned claims remain intact.
    function configure(uint32 duration, bool enabled) external onlyToken {
        if (duration < 10 minutes || duration > 1 days) revert InvalidDuration();
        distributionDuration = duration;
        distributionsEnabled = enabled;
        emit VaultConfigured(duration, enabled);
    }

    /// @dev Accrue with the OLD balance before replacing it. Never calls the reward token.
    function setShares(address account, uint256 balance) external onlyToken nonReentrant {
        _checkpoint();
        _accrue(account);
        totalShares = totalShares - shares[account] + balance;
        shares[account] = balance;
    }

    function claim() external nonReentrant returns (uint256) {
        _checkpoint();
        return _claim(msg.sender, true);
    }

    /// @notice A keeper may pay any holder, always to that holder's own address.
    function claimFor(address account) external nonReentrant returns (uint256) {
        _checkpoint();
        return _claim(account, true);
    }

    /// @notice Bounded keeper payouts; ineligible/duplicate accounts are skipped.
    /// @dev A reward-token transfer failure reverts this batch. Retry other accounts separately.
    function process(address[] calldata accounts) external nonReentrant returns (uint256 paid) {
        if (accounts.length == 0 || accounts.length > MAX_BATCH) revert InvalidBatch();
        _checkpoint();
        for (uint256 i; i < accounts.length; ++i) {
            paid += _claim(accounts[i], false);
        }
    }

    /// @notice Earned base units, including accrual not yet checkpointed; cooldown still applies.
    function earned(address account) external view returns (uint256) {
        uint256 index = rewardPerShare;
        uint256 pending = _emittedNow() - streamEmitted;
        if (totalShares != 0) index += Math.mulDiv(pending, SCALE, totalShares);
        (uint256 whole,) = _rewardAt(account, index);
        return accrued[account] + whole;
    }

    function nextClaimAt(address account) public view returns (uint256) {
        return Math.max(firstClaimAt, lastClaim[account] + CLAIM_INTERVAL);
    }

    function _checkpoint() private {
        uint256 emitted = _emittedNow();
        uint256 amount = emitted - streamEmitted;
        streamEmitted = emitted;
        if (amount == 0) return;
        if (totalShares == 0) {
            // No holder receives rewards for time during which every balance was excluded.
            queuedRewards += amount;
        } else {
            rewardPerShare += Math.mulDiv(amount, SCALE, totalShares);
            totalAllocated += amount;
        }
    }

    function _emittedNow() private view returns (uint256) {
        if (streamEnd == 0) return 0;
        uint256 elapsed = Math.min(block.timestamp, streamEnd) - streamStart;
        return Math.mulDiv(streamAmount, elapsed, streamEnd - streamStart);
    }

    function _rewardAt(address account, uint256 index) private view returns (uint256 whole, uint256 fraction) {
        uint256 delta = index - paidIndex[account];
        whole = Math.mulDiv(shares[account], delta, SCALE);
        fraction = mulmod(shares[account], delta, SCALE) + fractionalReward[account];
        whole += fraction / SCALE;
        fraction %= SCALE;
    }

    function _accrue(address account) private {
        (uint256 whole, uint256 fraction) = _rewardAt(account, rewardPerShare);
        accrued[account] += whole;
        fractionalReward[account] = fraction;
        paidIndex[account] = rewardPerShare;
    }

    function _claim(address account, bool strict) private returns (uint256 amount) {
        if (block.timestamp < nextClaimAt(account)) {
            if (strict) revert ClaimTooEarly();
            return 0;
        }
        _accrue(account);
        amount = accrued[account];
        if (amount == 0) {
            if (strict) revert NothingToClaim();
            return 0;
        }
        accrued[account] = 0;
        lastClaim[account] = block.timestamp;
        totalClaimed += amount;
        uint256 beforeVault = rewardToken.balanceOf(address(this));
        uint256 beforeRecipient = rewardToken.balanceOf(account);
        rewardToken.safeTransfer(account, amount);
        if (
            rewardToken.balanceOf(address(this)) != beforeVault - amount
                || rewardToken.balanceOf(account) != beforeRecipient + amount
        ) revert UnsupportedRewardToken();
        emit Claimed(account, amount);
    }
}
