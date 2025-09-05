// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/* -----------------------------
   External interfaces
------------------------------ */

interface IVotingEscrow {
    struct LockedBalance {
        int128 amount;
        uint256 end;
        bool isPermanent;
    }
    function increaseAmount(uint256 tokenId, uint256 value) external;
    function increaseUnlockTime(uint256 tokenId, uint256 _lockDuration) external;
    function merge(uint256 from, uint256 to) external;
    function locked(uint256 tokenId) external view returns (LockedBalance memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);
}

interface IiAEROToken { function mint(address to, uint256 amount) external; }

interface ILIQToken {
    function mint(address to, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function MAX_SUPPLY() external view returns (uint256);
}

/* -----------------------------
            Contract
------------------------------ */

contract PermalockVault_V5 is ReentrancyGuard, Ownable, Pausable, IERC721Receiver {
    using SafeERC20 for IERC20;
    using Address for address;

    // Immutable addresses
    address public immutable AERO;
    address public immutable veAERO;
    address public immutable iAERO;
    address public immutable LIQ;
    address public immutable treasury;

    // Constants
    uint256 public constant PROTOCOL_FEE_BPS = 500;    // 5%
    uint256 public constant BPS_BASE = 10_000;
    uint256 public constant MAX_LOCK_DURATION = 4 * 365 days;
    uint256 public constant WEEK = 7 days;
    uint256 public constant MIN_DEPOSIT = 1e18;
    uint256 public constant MAX_SINGLE_LOCK = 10_000_000 * 1e18;
    uint256 public constant TREASURY_LIQ_BPS = 2_000; // 20% of user LIQ mints go to treasury

    // Emissions halving: every 5,000,000 LIQ minted
    uint256 public constant HALVING_STEP = 5_000_000 * 1e18;

    // Emissions state
    uint256 public baseEmissionRate = 1e18; // 1 LIQ per 1 iAERO initially
    uint256 public totalLIQMinted;

    // Accounting
    uint256 public totalAEROLocked;
    uint256 public totalIAEROMinted;

    // NFT management
    uint256 public primaryNFT;
    uint256[] public additionalNFTs;
    mapping(uint256 => bool) public isManaged;
    mapping(uint256 => uint256) public nftLockedAmount;
    uint256 public lastRebaseTime;

    // Auth
    mapping(address => bool) public authorized;
    mapping(address => bool) public authorizedTargets;
    address public votingManager;
    address public rewardsCollector;
    address public keeper;

    // Options
    bool public emergencyPause;

    // Guarded ERC721 intake
    address private _expectedNftSender;
    uint256 private _expectedNftId;
    bool private _expectingNft;

    // ------- Rescue (break-glass) -------
    uint256 public constant RESCUE_DELAY = 48 hours;
    address public rescueSafe;

    struct RescuePlan {
        address to;
        uint64 eta;
        bool active;
    }
    mapping(uint256 => RescuePlan) public rescuePlan;

    // --------- Function selector gating for veAERO calls ---------
    bytes4 private constant SEL_INCREASE_AMOUNT     = bytes4(keccak256("increaseAmount(uint256,uint256)"));
    bytes4 private constant SEL_INCREASE_UNLOCKTIME = bytes4(keccak256("increaseUnlockTime(uint256,uint256)"));
    bytes4 private constant SEL_MERGE               = bytes4(keccak256("merge(uint256,uint256)"));
    // ERC721 transfers (must be blocked via executeNFTAction)
    bytes4 private constant SEL_ERC721_TRANSFERFROM = 0x23b872dd; // transferFrom(address,address,uint256)
    bytes4 private constant SEL_ERC721_SAFE_3       = 0x42842e0e; // safeTransferFrom(address,address,uint256)
    bytes4 private constant SEL_ERC721_SAFE_4       = 0xb88d4fde; // safeTransferFrom(address,address,uint256,bytes)

    // Events
    event DepositedAERO(address indexed user, uint256 aeroAmount, uint256 iAeroToUser, uint256 iAeroToTreasury, uint256 liqMinted);
    event DepositedVeNFT(address indexed user, uint256 indexed tokenId, uint256 aeroAmount, uint256 iAeroToUser, uint256 iAeroToTreasury, uint256 liqMinted);
    event NFTIncreased(uint256 indexed tokenId, uint256 amount);
    event NFTsMerged(uint256 indexed fromId, uint256 indexed toId);
    event NFTRebased(uint256 indexed tokenId, uint256 newUnlockTime);
    event HalvingReached(uint256 halvingIndex, uint256 totalMinted);
    event EmissionRateUpdated(uint256 newRate);
    event MaintenancePerformed(bool merged, bool rebased);
    event EmergencyPauseSet(bool paused);
    event AuthorizedSet(address indexed account, bool authorized);
    event AuthorizedTargetSet(address indexed target, bool authorized);
    event KeeperSet(address indexed keeper);
    event VotingManagerSet(address indexed manager);
    event RewardsCollectorSet(address indexed collector);
    event LIQMinted(address indexed user, uint256 toUser, uint256 toTreasury);
    event UnexpectedERC721Received(address indexed token, address indexed operator, address indexed from, uint256 tokenId);
    event StrandedVeNFTRescued(uint256 indexed tokenId, address indexed to);
    event RewardSwept(address indexed token, address indexed to, uint256 amount, address indexed caller);
    event RewardsSweepCompleted(address indexed to, uint256 tokenCount, address indexed caller);

    // Rescue events
    event RescueSafeSet(address indexed safe);
    event ManagedRescueProposed(uint256 indexed tokenId, address indexed to, uint64 eta, string reason);
    event ManagedRescueCancelled(uint256 indexed tokenId);
    event ManagedRescueExecuted(uint256 indexed tokenId, address indexed to);

    // Modifiers
    modifier onlyAuthorized() {
        require(authorized[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    modifier onlyKeeperOrOwner() {
        require(msg.sender == keeper || msg.sender == owner(), "Not keeper or owner");
        _;
    }
    modifier notEmergencyPaused() {
        require(!emergencyPause, "Emergency pause active");
        _;
    }

    constructor(
        address _iAERO,
        address _LIQ,
        address _AERO,
        address _veAERO,
        address _treasury
    ) Ownable(msg.sender) {
        require(_iAERO != address(0), "Invalid iAERO");
        require(_LIQ != address(0), "Invalid LIQ");
        require(_AERO != address(0), "Invalid AERO");
        require(_veAERO != address(0), "Invalid veAERO");
        require(_treasury != address(0), "Invalid treasury");

        // enforce 18-decimal tokens to match economic constants
        require(IERC20Metadata(_AERO).decimals() == 18, "AERO must be 18d");
        require(IERC20Metadata(_iAERO).decimals() == 18, "iAERO must be 18d");
        require(IERC20Metadata(_LIQ).decimals() == 18, "LIQ must be 18d");

        iAERO = _iAERO;
        LIQ = _LIQ;
        AERO = _AERO;
        veAERO = _veAERO;
        treasury = _treasury;

        // Allow executeNFTAction -> veAERO calls (merge, extend, increase) BUT gated by selector allowlist.
        authorizedTargets[_veAERO] = true;
    }

    /* ------------ Preview helpers ------------ */

    function previewDeposit(uint256 aeroAmount)
        external
        view
        returns (uint256 iAeroToUser, uint256 iAeroToTreasury, uint256 liqToUser)
    {
        require(aeroAmount >= MIN_DEPOSIT && aeroAmount <= MAX_SINGLE_LOCK, "Invalid amount");
        iAeroToTreasury = (aeroAmount * PROTOCOL_FEE_BPS) / BPS_BASE;
        iAeroToUser = aeroAmount - iAeroToTreasury;
        liqToUser = calculateLIQAmount(iAeroToUser);
    }

    function previewDepositVeNFT(uint256 tokenId)
        external
        view
        returns (uint256 iAeroToUser, uint256 iAeroToTreasury, uint256 liqToUser, uint256 lockedAmount)
    {
        IVotingEscrow.LockedBalance memory lb = IVotingEscrow(veAERO).locked(tokenId);
        require(lb.amount > 0, "No locked balance");

        lockedAmount     = uint256(uint128(lb.amount));
        iAeroToTreasury  = (lockedAmount * PROTOCOL_FEE_BPS) / BPS_BASE;
        iAeroToUser      = lockedAmount - iAeroToTreasury;
        liqToUser        = calculateLIQAmount(iAeroToUser);
    }

    function MAXTIME() external pure returns (uint256) { return MAX_LOCK_DURATION; }

    /* ------------ Deposits ------------ */

    /// @notice Deposit AERO to increase the *existing* primary veNFT (no auto-create).
    function deposit(uint256 amount) external nonReentrant whenNotPaused notEmergencyPaused {
        require(amount >= MIN_DEPOSIT, "Below minimum");
        require(amount <= MAX_SINGLE_LOCK, "Exceeds maximum");
        require(primaryNFT != 0, "No primary NFT");
        require(_isNFTValid(primaryNFT), "Primary NFT invalid");

        IERC20(AERO).safeTransferFrom(msg.sender, address(this), amount);

        // Increase existing lock only
        IERC20(AERO).forceApprove(veAERO, amount);
        IVotingEscrow(veAERO).increaseAmount(primaryNFT, amount);
        IERC20(AERO).forceApprove(veAERO, 0);
        nftLockedAmount[primaryNFT] += amount;
        emit NFTIncreased(primaryNFT, amount);

        // Optional auto-merge (no extend here)
        if (additionalNFTs.length > 0) { _mergeAllNFTs(); }

        // Mint iAERO & LIQ
        uint256 iAeroToTreasury = (amount * PROTOCOL_FEE_BPS) / BPS_BASE;
        uint256 iAeroToUser = amount - iAeroToTreasury;

        totalAEROLocked += amount;
        totalIAEROMinted += amount;

        IiAEROToken(iAERO).mint(msg.sender, iAeroToUser);
        IiAEROToken(iAERO).mint(treasury, iAeroToTreasury);
        

        uint256 liqToUser = calculateLIQAmount(iAeroToUser);
        if (liqToUser > 0) {
            _mintLIQWithCapSplit(msg.sender, liqToUser);
        }

        emit DepositedAERO(msg.sender, amount, iAeroToUser, iAeroToTreasury, liqToUser);
    }

    /// @notice Deposit a user’s veAERO NFT to be managed by the vault (no auto-extend).
    function depositVeNFT(uint256 tokenId) external nonReentrant whenNotPaused notEmergencyPaused {
        require(!isManaged[tokenId], "NFT already managed");
        require(IVotingEscrow(veAERO).ownerOf(tokenId) == msg.sender, "Not NFT owner");

        IVotingEscrow.LockedBalance memory lb = IVotingEscrow(veAERO).locked(tokenId);
        require(lb.amount > 0, "No locked balance");
        uint256 lockedAmount = uint256(uint128(lb.amount));
        require(lockedAmount >= MIN_DEPOSIT, "Below minimum");
        require(lb.isPermanent || lb.end > block.timestamp, "NFT expired");

        // Guard intake to prevent stranded transfers
        _expectedNftSender = msg.sender;
        _expectedNftId = tokenId;
        _expectingNft = true;

        IVotingEscrow(veAERO).safeTransferFrom(msg.sender, address(this), tokenId);

        // Clear guard (safety)
        if (_expectingNft) {
            _expectingNft = false;
            _expectedNftSender = address(0);
            _expectedNftId = 0;
        }

        // Mint iAERO & LIQ
        uint256 iAeroToTreasury = (lockedAmount * PROTOCOL_FEE_BPS) / BPS_BASE;
        uint256 iAeroToUser = lockedAmount - iAeroToTreasury;

        totalAEROLocked += lockedAmount;
        totalIAEROMinted += lockedAmount;

        IiAEROToken(iAERO).mint(msg.sender, iAeroToUser);
        IiAEROToken(iAERO).mint(treasury, iAeroToTreasury);

        uint256 liqToUser = calculateLIQAmount(iAeroToUser);
        if (liqToUser > 0) {
            _mintLIQWithCapSplit(msg.sender, liqToUser);
        }

        // Track management
        isManaged[tokenId] = true;
        nftLockedAmount[tokenId] = lockedAmount;

        // Choose primary if empty/invalid; do NOT extend here.
        if (primaryNFT == 0 || !_isNFTValid(primaryNFT)) {
            primaryNFT = tokenId;
            lastRebaseTime = block.timestamp;
        } else {
            additionalNFTs.push(tokenId);
        }

        // Optional: merge (no extend)
        if (additionalNFTs.length > 0) _mergeAllNFTs();

        emit DepositedVeNFT(msg.sender, tokenId, lockedAmount, iAeroToUser, iAeroToTreasury, liqToUser);
    }

    /* ------------ Maintenance ------------ */

    function performMaintenance() external onlyKeeperOrOwner nonReentrant {
        bool merged = false;
        bool rebased = false;

        if (additionalNFTs.length > 0) { _mergeAllNFTs(); merged = true; }
        if (primaryNFT != 0 && _needsRebase()) { _rebasePrimaryNFT(); rebased = true; }

        emit MaintenancePerformed(merged, rebased);
    }

    /* ------------ NFT actions for managers (STRICT) ------------ */

    function _selector(bytes calldata data) private pure returns (bytes4 sel) {
        assembly { sel := calldataload(data.offset) }
    }

    function executeNFTAction(
        uint256 tokenId,
        address target,
        bytes calldata data
    ) external onlyAuthorized nonReentrant returns (bytes memory) {
        require(isManaged[tokenId], "NFT not managed");
        require(authorizedTargets[target], "Target not authorized");
        require(target != address(0) && target.code.length > 0, "Invalid target");

        // If target is veAERO, only allow merge/increaseAmount/increaseUnlockTime; block transfers.
        if (target == veAERO) {
            bytes4 s = _selector(data);
            require(
                s == SEL_INCREASE_AMOUNT ||
                s == SEL_INCREASE_UNLOCKTIME ||
                s == SEL_MERGE,
                "veAERO call not allowed"
            );
            require(
                s != SEL_ERC721_TRANSFERFROM &&
                s != SEL_ERC721_SAFE_3 &&
                s != SEL_ERC721_SAFE_4,
                "veAERO transfer blocked"
            );
        }
        return target.functionCall(data);
    }

    /* ------------ Sweep / Rescue ------------ */

    function sweepERC20(address[] calldata tokens, address to)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        require(to != address(0), "Invalid recipient");
        
        bool isOwner = (msg.sender == owner());
        bool isCollector = (msg.sender == rewardsCollector);
        require(isOwner || isCollector, "Not authorized");
        
        // If the rewardsCollector is calling, force destination to itself
        if (isCollector) {
            require(to == msg.sender, "Collector must sweep to self");
        }
        
        amounts = new uint256[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; ) {
            address t = tokens[i];
            if (t != address(0) && t != iAERO && t != LIQ) {
                // Owner cannot sweep AERO (safety), but collector can (for rewards)
                if (isCollector || t != AERO) {
                    uint256 bal = IERC20(t).balanceOf(address(this));
                    if (bal > 0) {
                        IERC20(t).safeTransfer(to, bal);
                        amounts[i] = bal;
                    }
                }
            }
            unchecked { ++i; }
        }
    }

    function sweepETH(address to) external nonReentrant returns (uint256 amount) {
        require(to != address(0), "Invalid recipient");
        
        bool isOwner = (msg.sender == owner());
        bool isCollector = (msg.sender == rewardsCollector);
        require(isOwner || isCollector, "Not authorized");
        
        if (isCollector) {
            require(to == msg.sender, "Collector must sweep to self");
        }
        
        amount = address(this).balance;
        if (amount > 0) {
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETH transfer failed");
        }
    }


    /// @notice Rescue a stranded veAERO NFT currently owned by the vault but not managed.
    function rescueVeNFT(uint256 tokenId, address to) external onlyOwner nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(IVotingEscrow(veAERO).ownerOf(tokenId) == address(this), "Not owned by vault");
        require(!isManaged[tokenId] && nftLockedAmount[tokenId] == 0, "Managed NFT");
        IVotingEscrow(veAERO).safeTransferFrom(address(this), to, tokenId);
        emit StrandedVeNFTRescued(tokenId, to);
    }

    /// @notice Rescue a non-veAERO ERC721 sent by mistake.
    function rescueERC721(address token, uint256 tokenId, address to) external onlyOwner nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(token != veAERO, "Use rescueVeNFT");
        IERC721(token).safeTransferFrom(address(this), to, tokenId);
    }

    /* ------------ Managed Rescue (break-glass, time-locked) ------------ */

    function setRescueSafe(address _safe) external onlyOwner {
        require(_safe != address(0), "Invalid rescueSafe");
        rescueSafe = _safe;
        emit RescueSafeSet(_safe);
    }

    /// @dev Must be paused + in emergency to propose a rescue.
    function proposeManagedRescue(uint256 tokenId, string calldata reason)
        external
        onlyOwner
    {
        require(paused(), "Pause required");
        require(emergencyPause, "Emergency required");
        require(rescueSafe != address(0), "RescueSafe not set");
        require(isManaged[tokenId], "Not managed");
        require(nftLockedAmount[tokenId] > 0, "Empty lock");

        uint64 eta = uint64(block.timestamp + RESCUE_DELAY);
        rescuePlan[tokenId] = RescuePlan({ to: rescueSafe, eta: eta, active: true });
        emit ManagedRescueProposed(tokenId, rescueSafe, eta, reason);
    }

    function cancelManagedRescue(uint256 tokenId) external onlyOwner {
        require(rescuePlan[tokenId].active, "No plan");
        delete rescuePlan[tokenId];
        emit ManagedRescueCancelled(tokenId);
    }

    function executeManagedRescue(uint256 tokenId)
        external
        onlyOwner
        nonReentrant
    {
        RescuePlan memory p = rescuePlan[tokenId];
        require(p.active, "No plan");
        require(block.timestamp >= p.eta, "Too early");
        require(paused(), "Pause required");
        require(emergencyPause, "Emergency required");
        require(isManaged[tokenId], "Not managed");
        require(IVotingEscrow(veAERO).ownerOf(tokenId) == address(this), "Not owned");

        // Transfer out to the predeclared safe
        IVotingEscrow(veAERO).safeTransferFrom(address(this), p.to, tokenId);

        // Clean up accounting/bookkeeping
        isManaged[tokenId] = false;
        nftLockedAmount[tokenId] = 0;
        if (primaryNFT == tokenId) {
            primaryNFT = 0; // allow a later promotion in _mergeAllNFTs
        }
        // remove from additionalNFTs list if present
        uint256 len = additionalNFTs.length;
        for (uint256 i = 0; i < len; ) {
            if (additionalNFTs[i] == tokenId) {
                additionalNFTs[i] = additionalNFTs[len - 1];
                additionalNFTs.pop();
                break;
            }
            unchecked { ++i; }
        }

        delete rescuePlan[tokenId];
        emit ManagedRescueExecuted(tokenId, p.to);
    }

    /* ------------ LIQ emissions ------------ */

    function calculateLIQAmount(uint256 iAeroAmount) public view returns (uint256) {
        uint256 halvings = totalLIQMinted / HALVING_STEP;
        if (halvings > 100) halvings = 100; 
        uint256 currentRate = baseEmissionRate >> halvings;
        return (iAeroAmount * currentRate) / 1e18;
    }


    function getCurrentEmissionRate() external view returns (uint256) {
        uint256 halvings = totalLIQMinted / HALVING_STEP;
        if (halvings > 100) halvings = 100; // Add this for consistency
        return baseEmissionRate >> halvings;
    }

    /* ------------ Admin ------------ */

    function setKeeper(address _keeper) external onlyOwner {
        require(_keeper != address(0), "Invalid keeper");
        keeper = _keeper; emit KeeperSet(_keeper);
    }

    function setAuthorized(address account, bool authorized_) external onlyOwner {
        authorized[account] = authorized_;
        emit AuthorizedSet(account, authorized_);
    }

    function setAuthorizedTarget(address target, bool authorized_) external onlyOwner {
        authorizedTargets[target] = authorized_;
        emit AuthorizedTargetSet(target, authorized_);
    }

    function setVotingManager(address _votingManager) external onlyOwner {
        require(_votingManager != address(0), "Invalid voting manager");
        votingManager = _votingManager; authorized[_votingManager] = true; emit VotingManagerSet(_votingManager);
    }

    function setRewardsCollector(address _rewardsCollector) external onlyOwner {
        require(_rewardsCollector != address(0), "Invalid rewards collector");
        rewardsCollector = _rewardsCollector; authorized[_rewardsCollector] = true; emit RewardsCollectorSet(_rewardsCollector);
    }

    /// @notice Can only be set before any LIQ is minted (same rule as before).
    function setBaseEmissionRate(uint256 _rate) external onlyOwner {
        require(totalLIQMinted == 0, "LIQ already minted");
        require(_rate > 0 && _rate <= 100 * 1e18, "Invalid rate");
        baseEmissionRate = _rate; emit EmissionRateUpdated(_rate);
    }

    function setEmergencyPause(bool _paused) external onlyOwner {
        emergencyPause = _paused; emit EmergencyPauseSet(_paused);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /* ------------ Views ------------ */

    function vaultStatus() 
        external 
        view 
        returns (
            uint256 totalUserDeposits,
            uint256 totalProtocolOwned,
            uint256 actualFeesCollected,
            uint256 virtualFeesOwed,
            uint256 primaryNFTId,
            uint256 primaryNFTBalance,
            uint256 primaryNFTVotingPower,
            uint256 primaryNFTUnlockTime,
            uint256 additionalNFTCount,
            bool needsRebase_,
            bool needsMerge_
        ) 
    {
        totalUserDeposits  = totalAEROLocked;
        totalProtocolOwned = (totalIAEROMinted * PROTOCOL_FEE_BPS) / BPS_BASE;
        actualFeesCollected = totalProtocolOwned;
        virtualFeesOwed    = 0;

        primaryNFTId       = primaryNFT;
        additionalNFTCount = additionalNFTs.length;
        needsMerge_        = additionalNFTCount > 0;
        needsRebase_       = _needsRebase();

        if (primaryNFTId != 0 && _isNFTValid(primaryNFTId)) {
            primaryNFTBalance = nftLockedAmount[primaryNFTId];
            // unlock time
            try IVotingEscrow(veAERO).locked(primaryNFTId) returns (IVotingEscrow.LockedBalance memory lb) {
                primaryNFTUnlockTime = lb.end;
            } catch {}
            // voting power
            try IVotingEscrow(veAERO).balanceOfNFT(primaryNFTId) returns (uint256 power) {
                primaryNFTVotingPower = power;
            } catch {}
        }
    }

    function getManagedNFTs() external view returns (uint256[] memory) {
        uint256 validCount = 0;
        if (primaryNFT != 0 && _isNFTValid(primaryNFT)) validCount++;
        for (uint256 i = 0; i < additionalNFTs.length; i++) {
            if (additionalNFTs[i] != 0 && isManaged[additionalNFTs[i]]) validCount++;
        }

        uint256[] memory result = new uint256[](validCount);
        uint256 idx = 0;
        if (primaryNFT != 0 && _isNFTValid(primaryNFT)) result[idx++] = primaryNFT;
        for (uint256 i = 0; i < additionalNFTs.length; i++) {
            if (additionalNFTs[i] != 0 && isManaged[additionalNFTs[i]]) result[idx++] = additionalNFTs[i];
        }
        return result;
    }

    function getNFTInfo(uint256 tokenId) external view returns (
        bool managed,
        uint256 lockedAmount,
        uint256 votingPower,
        uint256 unlockTime,
        bool isPrimary,
        bool isPermanent
    ) {
        managed = isManaged[tokenId];
        lockedAmount = nftLockedAmount[tokenId];
        isPrimary = (tokenId == primaryNFT);

        if (managed && lockedAmount > 0) {
            try IVotingEscrow(veAERO).locked(tokenId) returns (IVotingEscrow.LockedBalance memory lb) {
                unlockTime = lb.end;
                isPermanent = lb.isPermanent;
            } catch {}
            try IVotingEscrow(veAERO).balanceOfNFT(tokenId) returns (uint256 power) {
                votingPower = power;
            } catch {}
        }
    }

    function getTotalValueLocked() external view returns (uint256) { return totalAEROLocked; }
    function getProtocolShareBPS() external pure returns (uint256) { return PROTOCOL_FEE_BPS; }
    function getProtocolEffectiveShare() external pure returns (uint256) { return PROTOCOL_FEE_BPS; }

    /* ------------ Internal helpers ------------ */
    function _mintLIQWithCapSplit(address user, uint256 liqToUser) private {
        uint256 remaining = ILIQToken(LIQ).MAX_SUPPLY() - ILIQToken(LIQ).totalSupply();
        require(remaining > 0, "LIQ cap reached");

        uint256 denom = BPS_BASE + TREASURY_LIQ_BPS;
        uint256 maxUserMint = (remaining * BPS_BASE) / denom;
        if (liqToUser > maxUserMint) { liqToUser = maxUserMint; }
        if (liqToUser == 0) return;

        ILIQToken(LIQ).mint(user, liqToUser);

        uint256 liqToTreasury = (liqToUser * TREASURY_LIQ_BPS) / BPS_BASE;
        if (liqToTreasury > 0) {
            ILIQToken(LIQ).mint(treasury, liqToTreasury);
        }
        _updateLIQSupply(liqToUser + liqToTreasury);
        emit LIQMinted(user, liqToUser, liqToTreasury);
    }

    /// Merge all additional managed NFTs into the current primary (no extend here).
    function _mergeAllNFTs() private {
        uint256 MAX_MERGES = 10;
        uint256 mergeCount = 0;
        
        // If no valid primary, try to promote a valid additional. Do NOT extend.
        if (primaryNFT == 0 || !_isNFTValid(primaryNFT)) {
            uint256 len0 = additionalNFTs.length;
            for (uint256 j = 0; j < len0; ) {
                uint256 cand = additionalNFTs[j];
                if (cand != 0 && isManaged[cand] && _isNFTValid(cand)) {
                    primaryNFT = cand;
                    lastRebaseTime = block.timestamp;
                    additionalNFTs[j] = additionalNFTs[len0 - 1];
                    additionalNFTs.pop();
                    break;
                }
                unchecked { ++j; }
            }
            if (primaryNFT == 0 || !_isNFTValid(primaryNFT)) return;
        }

        uint256 i = 0;
        while (i < additionalNFTs.length && mergeCount < MAX_MERGES) {
            uint256 fromId = additionalNFTs[i];
            if (!isManaged[fromId] || nftLockedAmount[fromId] == 0) {
                additionalNFTs[i] = additionalNFTs[additionalNFTs.length - 1];
                additionalNFTs.pop();
                continue;
            }
            try IVotingEscrow(veAERO).merge(fromId, primaryNFT) {
                uint256 amt = nftLockedAmount[fromId];
                nftLockedAmount[primaryNFT] += amt;
                nftLockedAmount[fromId] = 0;
                isManaged[fromId] = false;
                emit NFTsMerged(fromId, primaryNFT);
                additionalNFTs[i] = additionalNFTs[additionalNFTs.length - 1];
                additionalNFTs.pop();
                mergeCount++; // INCREMENT HERE (inside the successful try block)
            } catch { 
                unchecked { ++i; } 
            }
        }
    }

    function _needsRebase() private view returns (bool) {
        if (primaryNFT == 0) return false;
        try IVotingEscrow(veAERO).locked(primaryNFT) returns (IVotingEscrow.LockedBalance memory lb) {
            if (lb.isPermanent) return false;
            uint256 timeLeft = lb.end > block.timestamp ? lb.end - block.timestamp : 0;
            return timeLeft < MAX_LOCK_DURATION - (12 weeks);
        } catch { return false; }
    }

    /// Only maintenance extends to max
    function _extendToMax(uint256 tokenId) private returns (bool) {
        try IVotingEscrow(veAERO).locked(tokenId) returns (IVotingEscrow.LockedBalance memory lb) {
            if (lb.isPermanent) return false;
            uint256 targetEnd = ((block.timestamp + MAX_LOCK_DURATION) / WEEK) * WEEK;
            if (lb.end < targetEnd) {
                uint256 extension = targetEnd - lb.end;
                IVotingEscrow(veAERO).increaseUnlockTime(tokenId, extension);
                emit NFTRebased(tokenId, targetEnd);
                return true;
            }
        } catch {}
        return false;
    }

    function _rebasePrimaryNFT() private {
        if (primaryNFT == 0 || !_isNFTValid(primaryNFT)) return;
        if (_extendToMax(primaryNFT)) {
            lastRebaseTime = block.timestamp;
        }
    }

    function _isNFTValid(uint256 tokenId) private view returns (bool) {
        if (tokenId == 0) return false;
        try IVotingEscrow(veAERO).ownerOf(tokenId) returns (address owner_) {
            if (owner_ != address(this)) return false;
            try IVotingEscrow(veAERO).locked(tokenId) returns (IVotingEscrow.LockedBalance memory lb) {
                if (!lb.isPermanent && lb.end <= block.timestamp) return false;
                return uint256(uint128(lb.amount)) > 0;
            } catch { return false; }
        } catch { return false; }
    }

    function _updateLIQSupply(uint256 amount) private {
        uint256 prev = totalLIQMinted;
        totalLIQMinted = prev + amount;
        uint256 prevH = prev / HALVING_STEP;
        uint256 newH  = totalLIQMinted / HALVING_STEP;
        if (newH > prevH) {
            emit HalvingReached(newH, totalLIQMinted);
        }
    }

    /* ------------ Receive / ERC721 ------------ */

    receive() external payable {}

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external override returns (bytes4)
    {
        // Only accept veAERO NFTs
        if (msg.sender != veAERO) {
            emit UnexpectedERC721Received(msg.sender, operator, from, tokenId);
            revert("ERC721 not allowed");
        }
        // Only accept when depositVeNFT has set the guard
        if (!_expectingNft || _expectedNftId != tokenId || _expectedNftSender != from) {
            emit UnexpectedERC721Received(msg.sender, operator, from, tokenId);
            revert("Direct veNFT transfer not allowed");
        }
        // Clear guard inside callback
        _expectingNft = false;
        _expectedNftSender = address(0);
        _expectedNftId = 0;
        return IERC721Receiver.onERC721Received.selector;
    }
}
