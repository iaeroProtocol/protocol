// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LIQStakingDistributor (V2)
/// @notice Stake LIQ to earn protocol revenue share and multi-token rewards (ERC20 + ETH).
/// @dev  - OZ v5 compatible; uses mulDiv accounting to avoid overflow.
///       - ETH rewards supported (token=address(0)) with push->pull fallback via per-user credits.
///       - Pausable, stake caps, max reward-token limit, FOT-safe funding via balance-delta.
///       - Lock model: each new stake extends user's lock to now+LOCK_PERIOD (documented).
contract LIQStakingDistributor is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ========= Errors =========
    error ZeroAddress();
    error InvalidAmount();
    error NotEnoughStaked();
    error BadETHValue();
    error IndexOutOfBounds();
    error UnauthorizedRewardNotifier();
    error MaxRewardTokensReached();
    error InsufficientCredit();

    // ========= Constants / Immutables =========

    /// @notice LIQ token being staked
    address public immutable LIQ;

    /// @notice Accumulator precision
    uint256 public constant PRECISION = 1e18;

    /// @notice Mandatory stake lock period
    uint256 public constant LOCK_PERIOD = 7 days;

    // ========= Staking storage =========

    /// @notice Total LIQ staked
    uint256 public totalLIQStaked;

    /// @notice User -> staked LIQ
    mapping(address => uint256) public balanceOf;

    /// @notice User -> earliest time they may unstake
    mapping(address => uint256) public unlockTime;

    /// @notice Authorized accounts that may notify rewards (vault/treasury/owner/harvester etc.)
    mapping(address => bool) public rewardNotifiers;

    /// @notice Optional stake caps
    uint256 public maxStakePerUser = type(uint256).max;
    uint256 public maxTotalStaked  = type(uint256).max;

    // ========= Rewards storage =========

    /// @dev Ordered list of reward tokens (address(0) = ETH)
    address[] private _rewardTokens;

    /// @dev Max number of reward tokens (owner-tunable)
    uint256 public maxRewardTokens = 50;

    /// @dev Fast existence check for reward token list
    mapping(address => bool) public tokenExists;

    /// @dev Token -> global accRewardPerShare
    mapping(address => uint256) public accRewardPerShare;

    /// @dev Token -> queued rewards when no stakers
    mapping(address => uint256) public queuedRewards;

    /// @dev User -> Token -> reward debt (acc at last sync for the user)
    mapping(address => mapping(address => uint256)) public rewardDebt;

    /// @dev Per-user "credits" for push->pull fallback (used mainly for ETH)
    mapping(address => mapping(address => uint256)) public credit; // user => token => amount

    // ========= Events =========
    event LIQStaked(address indexed user, uint256 amount, uint256 unlockTime);
    event LIQUnstaked(address indexed user, uint256 amount);
    event RewardNotified(address indexed token, uint256 amount, uint256 distributedPerShare);
    event QueuedRewardsDistributed(address indexed token, uint256 amount);
    event RewardClaimed(address indexed user, address indexed token, uint256 amount);
    event CreditAccrued(address indexed user, address indexed token, uint256 amount);
    event CreditWithdrawn(address indexed user, address indexed token, uint256 amount, address indexed to);
    event RewardNotifierSet(address indexed notifier, bool authorized);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardTokenAdded(address indexed token);
    event RewardTokenRetired(address indexed token);
    event StakeCapsSet(uint256 perUser, uint256 total);
    event MaxRewardTokensSet(uint256 maxRewardTokens);

    // ========= Constructor =========

    /// @param _LIQ LIQ token address
    /// @param _vault PermalockVault (authorized notifier)
    /// @param _treasury Treasury (authorized notifier)
    constructor(address _LIQ, address _vault, address _treasury) Ownable(msg.sender) {
        if (_LIQ == address(0) || _vault == address(0) || _treasury == address(0)) revert ZeroAddress();
        LIQ = _LIQ;
        rewardNotifiers[_vault] = true;
        rewardNotifiers[_treasury] = true;
        rewardNotifiers[msg.sender] = true; // owner initial notifier
    }

    // ========= Admin =========

    /// @notice Authorize/deauthorize a reward notifier
    function setRewardNotifier(address notifier, bool authorized) external onlyOwner {
        if (notifier == address(0)) revert ZeroAddress();
        rewardNotifiers[notifier] = authorized;
        emit RewardNotifierSet(notifier, authorized);
    }

    /// @notice Set per-user and global stake caps
    function setStakeCaps(uint256 perUser, uint256 total_) external onlyOwner {
        // (No particular bounds; ops policy defines safe values)
        maxStakePerUser = perUser == 0 ? type(uint256).max : perUser;
        maxTotalStaked  = total_  == 0 ? type(uint256).max : total_;
        emit StakeCapsSet(maxStakePerUser, maxTotalStaked);
    }

    /// @notice Set the maximum number of reward tokens
    function setMaxRewardTokens(uint256 newMax) external onlyOwner {
        require(newMax > 0 && newMax <= 1000, "bad max");
        maxRewardTokens = newMax;
        emit MaxRewardTokensSet(newMax);
    }

    /// @notice Pause / Unpause critical flows (stake/unstake/claims/notify)
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Retire a reward token from enumeration (users can still claim it individually)
    /// @dev Requires no queued rewards to avoid trapping undistributed amounts
    function retireRewardToken(address token) external onlyOwner {
        if (!tokenExists[token]) revert IndexOutOfBounds();
        require(queuedRewards[token] == 0, "queued>0");
        uint256 n = _rewardTokens.length;
        for (uint256 i = 0; i < n; i++) {
            if (_rewardTokens[i] == token) {
                _rewardTokens[i] = _rewardTokens[n - 1];
                _rewardTokens.pop();
                tokenExists[token] = false;
                emit RewardTokenRetired(token);
                break;
            }
        }
    }

    /// @notice Recover arbitrary ERC20 tokens (not LIQ). Use with care.
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != LIQ, "Cannot recover LIQ");
        IERC20(token).safeTransfer(to, amount);
    }

    // ========= Views =========

    /// @notice Return all reward token addresses (address(0) = ETH)
    function getRewardTokens() external view returns (address[] memory) {
        return _rewardTokens;
    }

    /// @notice Reward tokens array length
    function rewardTokensLength() external view returns (uint256) {
        return _rewardTokens.length;
    }

    /// @notice Reward token at index
    function rewardTokens(uint256 index) external view returns (address) {
        if (index >= _rewardTokens.length) revert IndexOutOfBounds();
        return _rewardTokens[index];
    }

    /// @notice Pending rewards for user across all tokens (includes any credit)
    function getPendingRewards(address account)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        uint256 len = _rewardTokens.length;
        tokens = new address[](len);
        amounts = new uint256[](len);

        uint256 staked = balanceOf[account];
        for (uint256 i = 0; i < len; i++) {
            address t = _rewardTokens[i];
            tokens[i] = t;
            uint256 c = credit[account][t];
            if (staked == 0) {
                amounts[i] = c;
            } else {
                uint256 acc = accRewardPerShare[t];
                uint256 debt = rewardDebt[account][t];
                uint256 pending = (acc > debt) ? Math.mulDiv(staked, acc - debt, PRECISION) : 0;
                amounts[i] = pending + c;
            }
        }
    }

    /// @notice Read per-user credit for a token (address(0) = ETH)
    function creditOf(address user, address token) external view returns (uint256) {
        return credit[user][token];
    }

    // ========= Staking =========

    /// @notice Stake LIQ with a 7-day lock
    /// @dev Flush queued rewards BEFORE changing balances so new stake doesn’t share past queued rewards
    ///      Lock model: any new stake extends user's lock to now+LOCK_PERIOD (does not shorten).
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();

        // Caps
        require(balanceOf[msg.sender] + amount <= maxStakePerUser, "user cap");
        require(totalLIQStaked + amount <= maxTotalStaked, "total cap");

        // If there are existing stakers, distribute any queued rewards to them first
        if (totalLIQStaked > 0) _flushQueuedRewards();

        // Pay any pending rewards to this user based on current acc values
        _harvest(msg.sender);

        // Pull LIQ and update balances
        IERC20(LIQ).safeTransferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        totalLIQStaked += amount;

        // Extend lock, never shorten
        uint256 newUnlock = block.timestamp + LOCK_PERIOD;
        if (newUnlock > unlockTime[msg.sender]) {
            unlockTime[msg.sender] = newUnlock;
        }

        // Snapshot user debts to the latest acc after potential flush
        _writeRewardDebts(msg.sender);

        emit LIQStaked(msg.sender, amount, unlockTime[msg.sender]);
    }

    /// @notice Unstake LIQ (must be unlocked)
    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (balanceOf[msg.sender] < amount) revert NotEnoughStaked();
        require(block.timestamp >= unlockTime[msg.sender], "Still locked");

        // Distribute queued rewards to current stakers (if any), so harvest reflects them
        if (totalLIQStaked > 0) _flushQueuedRewards();

        _harvest(msg.sender);

        balanceOf[msg.sender] -= amount;
        totalLIQStaked -= amount;

        // If fully exited, clear stale lock
        if (balanceOf[msg.sender] == 0) {
            unlockTime[msg.sender] = 0;
        }

        _writeRewardDebts(msg.sender);

        IERC20(LIQ).safeTransfer(msg.sender, amount);
        emit LIQUnstaked(msg.sender, amount);
    }

    /// @notice Emergency withdraw LIQ without claiming rewards (forfeits rewards)
    /// @dev Only allowed when the contract is paused (circuit breaker)
    function emergencyWithdraw() external nonReentrant whenPaused {
        uint256 amount = balanceOf[msg.sender];
        if (amount == 0) revert InvalidAmount();

        // Forfeit rewards by resetting debts; no harvest
        balanceOf[msg.sender] = 0;
        totalLIQStaked -= amount;

        // Clear stale lock on full exit
        unlockTime[msg.sender] = 0;

        _writeRewardDebts(msg.sender);

        IERC20(LIQ).safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, amount);
    }

    /// @notice Exit completely (claim rewards and unstake all, if unlocked)
    function exit() external nonReentrant whenNotPaused {
        require(block.timestamp >= unlockTime[msg.sender], "Still locked");

        if (totalLIQStaked > 0) _flushQueuedRewards();
        _harvest(msg.sender);

        uint256 amount = balanceOf[msg.sender];
        if (amount > 0) {
            balanceOf[msg.sender] = 0;
            totalLIQStaked -= amount;
            unlockTime[msg.sender] = 0; // clear stale lock
            IERC20(LIQ).safeTransfer(msg.sender, amount);
            emit LIQUnstaked(msg.sender, amount);
        }

        _writeRewardDebts(msg.sender);
    }

    // ========= Claims =========

    /// @notice Claim all pending rewards
    function claimRewards() external nonReentrant whenNotPaused {
        if (totalLIQStaked > 0) _flushQueuedRewards();
        _harvest(msg.sender);
        _writeRewardDebts(msg.sender);
    }

    /// @notice Claim multiple specific reward tokens in one transaction
    /// @param tokens Array of token addresses to claim
    function claimMany(address[] calldata tokens) external nonReentrant whenNotPaused {
        if (totalLIQStaked > 0) _flushQueuedRewards();
        
        uint256 len = tokens.length;
        require(len > 0 && len <= 50, "Invalid length");
        
        for (uint256 i = 0; i < len; i++) {
            _harvestOne(msg.sender, tokens[i]);
        }
    }

    /// @notice Claim a single reward token
    function claimReward(address token) external nonReentrant whenNotPaused {
        if (totalLIQStaked > 0) _flushQueuedRewards();
        _harvestOne(msg.sender, token);
        // _harvestOne updates the per-token rewardDebt
    }

    /// @notice Withdraw any accrued credit (push->pull fallback), to a chosen address.
    function withdrawCredit(address token, uint256 amount, address payable to) external nonReentrant whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        uint256 c = credit[msg.sender][token];
        if (amount == 0 || amount > c) revert InsufficientCredit();
        credit[msg.sender][token] = c - amount;

        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "ETH withdraw failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit CreditWithdrawn(msg.sender, token, amount, to);
    }

    // ========= Reward distribution =========

    /// @notice Notify new rewards for `token` (address(0) = ETH). Only notifiers may call.
    /// @dev Uses balance-delta for ERC20 to support fee-on-transfer / deflationary tokens.
    function notifyRewardAmount(address token, uint256 amount) external payable nonReentrant whenNotPaused {
        if (!rewardNotifiers[msg.sender]) revert UnauthorizedRewardNotifier();

        uint256 received;
        if (token == address(0)) {
            if (msg.value != amount) revert BadETHValue();
            received = amount;
        } else {
            if (amount == 0) revert InvalidAmount();
            IERC20 erc = IERC20(token);
            uint256 beforeBal = erc.balanceOf(address(this));
            erc.safeTransferFrom(msg.sender, address(this), amount);
            uint256 afterBal = erc.balanceOf(address(this));
            require(afterBal >= beforeBal, "bal regression");
            received = afterBal - beforeBal;
            require(received > 0, "no receive");
        }

        _addRewardTokenIfNeeded(token);

        if (totalLIQStaked == 0) {
            queuedRewards[token] += received;
            emit RewardNotified(token, received, 0);
            return;
        }

        uint256 inc = Math.mulDiv(received, PRECISION, totalLIQStaked);
        accRewardPerShare[token] += inc;
        emit RewardNotified(token, received, inc);
    }

    // ========= Internals =========

    function _harvest(address user) internal {
        uint256 staked = balanceOf[user];
        if (staked == 0) return;

        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            _harvestOne(user, _rewardTokens[i]);
        }
    }

    function _harvestOne(address user, address token) internal {
        uint256 staked = balanceOf[user];

        if (staked == 0) {
            rewardDebt[user][token] = accRewardPerShare[token];
            return;
        }

        uint256 acc = accRewardPerShare[token];
        uint256 debt = rewardDebt[user][token];
        if (acc > debt) {
            uint256 pending = Math.mulDiv(staked, acc - debt, PRECISION);
            if (pending > 0) {
                if (token == address(0)) {
                    (bool ok, ) = payable(user).call{value: pending}("");
                    if (!ok) {
                        // Fallback: accrue as credit for pull-based withdrawal
                        credit[user][address(0)] += pending;
                        emit CreditAccrued(user, address(0), pending);
                    } else {
                        emit RewardClaimed(user, token, pending);
                    }
                } else {
                    IERC20(token).safeTransfer(user, pending);
                    emit RewardClaimed(user, token, pending);
                }
            }
        }

        rewardDebt[user][token] = acc;
    }

    function _writeRewardDebts(address user) internal {
        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address t = _rewardTokens[i];
            rewardDebt[user][t] = accRewardPerShare[t];
        }
    }

    function _addRewardTokenIfNeeded(address token) internal {
        if (!tokenExists[token]) {
            require(_rewardTokens.length < maxRewardTokens, "reward tokens full");
            tokenExists[token] = true;
            _rewardTokens.push(token);
            emit RewardTokenAdded(token);
        }
    }

    /// @dev Distribute queued rewards to current stakers (no-op if totalLIQStaked==0)
    function _flushQueuedRewards() internal {
        if (totalLIQStaked == 0) return;

        uint256 len = _rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address t = _rewardTokens[i];
            uint256 q = queuedRewards[t];
            if (q == 0) continue;

            queuedRewards[t] = 0;
            uint256 inc = Math.mulDiv(q, PRECISION, totalLIQStaked);
            accRewardPerShare[t] += inc;

            emit RewardNotified(t, q, inc);
            emit QueuedRewardsDistributed(t, q);
        }
    }

    receive() external payable {}
}
