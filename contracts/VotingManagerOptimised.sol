// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/* ======================= External interfaces ======================= */

interface IVoter {
    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) external;
    function reset(uint256 tokenId) external;
    function gauges(address pool) external view returns (address);
    function isAlive(address gauge) external view returns (bool);
}

interface IVoterTime {
    function epochVoteStart(uint256 ts) external view returns (uint256);
    function epochVoteEnd(uint256 ts) external view returns (uint256);
}

interface IPermalockVault {
    function primaryNFT() external view returns (uint256);
    function executeNFTAction(uint256 tokenId, address target, bytes calldata data) external returns (bytes memory);
    function getNFTInfo(uint256 tokenId)
        external
        view
        returns (
            bool managed,
            uint256 lockedAmount,
            uint256 votingPower,
            uint256 unlockTime,
            bool isPrimary,
            bool isPermanent
        );
}

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/* ============================ Contract ============================ */

contract VotingManagerOptimised is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /* ------------------------------ Constants ------------------------------ */
    uint256 public constant BPS_BASE = 10_000;
    uint256 public constant WEEK = 7 days;
    uint256 public constant MAX_CLAIM_CHUNK = 50;

    /* -------------------------------- Errors -------------------------------- */
    error NotKeeper();
    error PoolNotActive();
    error TokenNotAllowed();
    error AmountZero();
    error BadEpochs();
    error NoPrimaryNFT();
    error NoVotingPower();
    error VoteAlreadyExecuted();
    error VoteInProgress();
    error NoOracle();
    error OracleStale();
    error OracleBadAnswer();
    error EpochNotExecuted();
    error PoolNotVotedInEpoch();
    error LenMismatch();
    error EpochMisaligned();
    error ForbiddenSweep();

    /* -------------------------------- Events -------------------------------- */
    event PoolAdded(address indexed pool, address gauge);
    event PoolRemoved(address indexed pool);

    event KeeperSet(address indexed who, bool status);

    event OracleConfigured(address indexed token, address indexed feed, uint48 maxStaleSec, bool enabled);
    event AllowedBribeTokenSet(address indexed token, bool allowed);

    event BribeDeposited(
        address indexed depositor,
        address indexed pool,
        address indexed token,
        uint256 amount,
        uint256 epochId
    );
    event BribePaid(address indexed pool, uint256 indexed epochId, address indexed token, uint256 amount);
    event BribeRefunded(address indexed depositor, address indexed pool, uint256 indexed epochId, address token, uint256 amount);

    event VotesExecuted(
        uint256 indexed epochId,
        uint256 indexed tokenId,
        address[] pools,
        uint256[] weightsBps,
        uint256 totalVotingPower
    );

    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed to);


    event BaseRevenueSet(address indexed pool, uint256 indexed epochId, uint256 usdAmount);
    event RefundGraceSet(uint256 seconds_);
    event BribesPruned(address indexed pool, uint256 indexed epochId, uint256 removed, uint256 remaining);

    /* ----------------------------- Immutables ------------------------------- */
    address public immutable vault;
    address public immutable voter;
    address public immutable treasury;

    /* -------------------------------- Roles --------------------------------- */
    mapping(address => bool) public keepers;

    /* ------------------------------ Oracles --------------------------------- */
    struct OracleConf {
        address feed;         // Chainlink (or adapter) aggregator
        uint48  maxStaleSec;  // max allowed staleness
        bool    enabled;
    }
    // token => oracle (token == address(0) means ETH/USD)
    mapping(address => OracleConf) public oracles;
    mapping(address => bool) public allowedBribeTokens; // optional allowlist

    /* ------------------------------ Strategy -------------------------------- */
    uint256 public minBribeUSDPerEpoch = 10e18;   // 10 USD (1e18)
    uint256 public bribeDiscountBPS    = 10000;    // 100%
    uint256 public maxPoolAllocationBPS = 7000;   // 70%
    uint256 public minVoteWeightBPS     = 5;      // 0.05%
    uint256 public refundGraceSeconds   = 1 days; // after epoch end

    /* -------------------------------- Pools --------------------------------- */
    struct PoolData {
        bool isActive;
        address gauge;
    }
    address[] public activePools;
    mapping(address => PoolData) public poolData;

    /* --------------------------- Bribes / Epochs ---------------------------- */

    // Per-epoch base revenue (USD 1e18), set by keeper for scoring
    mapping(address => mapping(uint256 => uint256)) public baseRevenueUSDByEpoch; // pool => epochId => USD (1e18)

    struct BribeSlice {
        address token;        // address(0) for ETH
        uint256 amount;       // raw token amount
        uint256 epochId;      // epoch start timestamp
        address depositor;
        bool    paid;         // transferred to treasury
        bool    refunded;     // refunded to depositor
    }

    // Pool + epoch => list of bribe slices (so we never scan other epochs)
    mapping(address => mapping(uint256 => BribeSlice[])) private bribesByPoolEpoch;

    // Aggregated for quicker scoring: pool + epochId => total USD at deposit time
    // Note: this is deposit-time USD, not "still unclaimed" USD.
    mapping(address => mapping(uint256 => uint256)) public poolEpochBribesUSD; // 1e18 USD

    // Per-epoch voting record
    struct EpochData {
        bool    executed;
        uint256 totalVotingPower;
        address[] pools;
        uint256[] weightsBps;
        uint256 timestamp;
    }
    mapping(uint256 => EpochData) public epochDataById;   // key = epochId
    mapping(uint256 => bool) private epochLock;           // per-epoch mutex

    /* -------------------------------- Modifiers ----------------------------- */
    modifier onlyKeeper() {
        if (!(keepers[msg.sender] || msg.sender == owner())) revert NotKeeper();
        _;
    }

    /* ---------------------------- Constructor ------------------------------- */
    constructor(address _vault, address _voter, address _treasury) Ownable(msg.sender) {
        require(_vault != address(0) && _voter != address(0) && _treasury != address(0), "bad addr");
        vault = _vault;
        voter = _voter;
        treasury = _treasury;

        // allow ETH as bribe token (requires ETH/USD oracle to be set)
        allowedBribeTokens[address(0)] = true;
    }

    /* ============================== Oracle utils ============================ */

    function setOracle(address token, address feed, uint48 maxStaleSec, bool enabled) external onlyOwner {
        oracles[token] = OracleConf({ feed: feed, maxStaleSec: maxStaleSec, enabled: enabled });
        emit OracleConfigured(token, feed, maxStaleSec, enabled);
    }

    function batchConfigureOracles(
        address[] calldata tokens,
        address[] calldata feeds,
        uint48[] calldata maxStaleSeconds,
        bool[] calldata enabled,
        bool alsoSetAllowed
    ) external onlyOwner {
        uint256 len = tokens.length;
        if (len != feeds.length || len != maxStaleSeconds.length || len != enabled.length) revert LenMismatch();

        for (uint256 i = 0; i < len; i++) {
            oracles[tokens[i]] = OracleConf({
                feed: feeds[i],
                maxStaleSec: maxStaleSeconds[i],
                enabled: enabled[i]
            });
            emit OracleConfigured(tokens[i], feeds[i], maxStaleSeconds[i], enabled[i]);

            if (alsoSetAllowed) {
                allowedBribeTokens[tokens[i]] = enabled[i];
                emit AllowedBribeTokenSet(tokens[i], enabled[i]);
            }
        }
    }

    function batchSetAllowedBribeTokens(address[] calldata tokens, bool[] calldata allowed) external onlyOwner {
        if (tokens.length != allowed.length) revert LenMismatch();
        for (uint256 i = 0; i < tokens.length; i++) {
            allowedBribeTokens[tokens[i]] = allowed[i];
            emit AllowedBribeTokenSet(tokens[i], allowed[i]);
        }
    }

    function setAllowedBribeToken(address token, bool allowed) external onlyOwner {
        allowedBribeTokens[token] = allowed;
        emit AllowedBribeTokenSet(token, allowed);
    }

    function getPriceUSD(address token) external view returns (uint256) {
        return _consultPrice1e18(token);
    }

    function _consultPrice1e18(address token) internal view returns (uint256 p) {
        OracleConf memory oc = oracles[token];
        if (!oc.enabled || oc.feed == address(0)) revert NoOracle();
        AggregatorV3Interface agg = AggregatorV3Interface(oc.feed);
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = agg.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert OracleBadAnswer();
        if (updatedAt == 0) revert OracleBadAnswer();
        if (oc.maxStaleSec > 0 && block.timestamp > updatedAt + oc.maxStaleSec) revert OracleStale();

        uint8 dec = agg.decimals();
        // normalize to 1e18 USD per token
        if (dec <= 18) {
            p = uint256(answer) * (10 ** (18 - dec));
        } else {
            p = uint256(answer) / (10 ** (dec - 18));
        }
    }

    function _tokenDecimals(address token) internal view returns (uint8 d) {
        if (token == address(0)) return 18;
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            d = dec;
        } catch {
            d = 18; // default if non-standard
        }
    }

    // Returns USD value (1e18) of `amount` of `token` using mulDiv to avoid overflow
    function _usdValue(address token, uint256 amount) internal view returns (uint256 usd) {
        uint256 px1e18 = _consultPrice1e18(token);        // USD(1e18) per 1 token
        uint256 scale  = 10 ** _tokenDecimals(token);     // token units per 1 token
        usd = Math.mulDiv(amount, px1e18, scale);         // amount * price / scale
    }

    // Debug/ops helper
    function getOracleMeta(address token)
        external
        view
        returns (address feed, uint48 maxStale, bool enabled, uint8 decimals_)
    {
        OracleConf memory oc = oracles[token];
        feed = oc.feed;
        maxStale = oc.maxStaleSec;
        enabled = oc.enabled;

        if (feed == address(0)) return (feed, maxStale, enabled, 0);
        try AggregatorV3Interface(feed).decimals() returns (uint8 d) {
            decimals_ = d;
        } catch {
            decimals_ = 0; // unknown
        }
    }

    function activePoolsSlice(uint256 start, uint256 max)
        external
        view
        returns (address[] memory slice)
    {
        uint256 n = activePools.length;
        if (start >= n) return new address[](0);
        if (max > 1000) max = 1000; // safety
        uint256 end = start + max;
        if (end < start) end = n;
        if (end > n) end = n;
        uint256 len = end - start;
        slice = new address[](len);
        for (uint256 i = 0; i < len; ) {
            slice[i] = activePools[start + i];
            unchecked { ++i; }
        }
    }



    /* =============================== Epoch math ============================= */

    // Aerodrome: epochVoteStart(t) = epochStart(t) + 1 hour
    function _epochStart(uint256 t) internal view returns (uint256) {
        return IVoterTime(voter).epochVoteStart(t) - 1 hours;
    }

    function currentEpochId() public view returns (uint256) {
        return _epochStart(block.timestamp);
    }

    function isEpochStart(uint256 ts) public view returns (bool) {
        return _epochStart(ts) == ts;
    }

    function inVotingWindow() public view returns (bool) {
        uint256 t = block.timestamp;
        uint256 start = IVoterTime(voter).epochVoteStart(t);
        uint256 end   = IVoterTime(voter).epochVoteEnd(t);
        return (t > start && t <= end);
    }

    /* =============================== Bribes I/O ============================= */

    function depositBribe(address pool, address token, uint256 amount, uint256 epochs)
        external
        nonReentrant
        whenNotPaused
    {
        if (!poolData[pool].isActive) revert PoolNotActive();
        if (!allowedBribeTokens[token]) revert TokenNotAllowed();
        if (token == address(0)) revert AmountZero(); // use depositETHBribe
        if (amount == 0) revert AmountZero();
        if (epochs == 0 || epochs > 8) revert BadEpochs();

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        require(received > 0, "no-receive");

        uint256 startEpoch = currentEpochId();
        // split the *received* amount
        uint256 per = received / epochs;
        uint256 rem = received - per * epochs;

        for (uint256 i = 0; i < epochs; i++) {
            uint256 sliceAmt = per + (i == 0 ? rem : 0);
            uint256 epochId = startEpoch + i * WEEK;
            uint256 sliceUSD = _usdValue(token, sliceAmt);
            require(sliceUSD >= minBribeUSDPerEpoch, "per-epoch too small");

            bribesByPoolEpoch[pool][epochId].push(BribeSlice({
                token: token,
                amount: sliceAmt,
                epochId: epochId,
                depositor: msg.sender,
                paid: false,
                refunded: false
            }));
            poolEpochBribesUSD[pool][epochId] += sliceUSD;

            emit BribeDeposited(msg.sender, pool, token, sliceAmt, epochId);
        }
    }


    function depositETHBribe(address pool, uint256 epochs)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (!poolData[pool].isActive) revert PoolNotActive();
        if (!allowedBribeTokens[address(0)]) revert TokenNotAllowed();
        if (msg.value == 0) revert AmountZero();
        if (epochs == 0 || epochs > 8) revert BadEpochs();

        _consultPrice1e18(address(0)); // validate oracle availability & freshness

        uint256 startEpoch = currentEpochId();
        uint256 per = msg.value / epochs;
        uint256 rem = msg.value - per * epochs;

        for (uint256 i = 0; i < epochs; i++) {
            uint256 sliceAmt = per + (i == 0 ? rem : 0);
            uint256 epochId = startEpoch + i * WEEK;
            uint256 sliceUSD = _usdValue(address(0), sliceAmt);
            require(sliceUSD >= minBribeUSDPerEpoch, "per-epoch too small");

            bribesByPoolEpoch[pool][epochId].push(BribeSlice({
                token: address(0),
                amount: sliceAmt,
                epochId: epochId,
                depositor: msg.sender,
                paid: false,
                refunded: false
            }));
            poolEpochBribesUSD[pool][epochId] += sliceUSD;

            emit BribeDeposited(msg.sender, pool, address(0), sliceAmt, epochId);
        }
    }

    /**
     * @notice Pay treasury all bribes for a pool and epoch that were “consumed” (i.e., pool was voted).
     * @dev    Use in small chunks (e.g., 5–10) to keep gas bounded.
     */
    function claimTreasuryBribes(address pool, uint256 epochId, uint256 start, uint256 maxCount) external nonReentrant {
        if (!epochDataById[epochId].executed) revert EpochNotExecuted();
        if (!_poolVotedInEpoch(pool, epochId)) revert PoolNotVotedInEpoch();

        BribeSlice[] storage arr = bribesByPoolEpoch[pool][epochId];
        uint256 n = arr.length;
        if (start >= n) return;

        if (maxCount > MAX_CLAIM_CHUNK) maxCount = MAX_CLAIM_CHUNK; // soft cap

        uint256 end = start + maxCount;
        if (end < start) end = n; // overflow fallback
        if (end > n) end = n;

        for (uint256 i = start; i < end; i++) {
            BribeSlice storage s = arr[i];
            if (s.paid || s.refunded) continue;
            s.paid = true;
            if (s.token == address(0)) {
                (bool ok, ) = payable(treasury).call{value: s.amount}("");
                require(ok, "ETH xfer fail");
            } else {
                IERC20(s.token).safeTransfer(treasury, s.amount);
            }
            emit BribePaid(pool, epochId, s.token, s.amount);
        }
    }

    function refundMyBribes(address pool, uint256 epochId, uint256 start, uint256 maxCount) external nonReentrant {
        bool executed = epochDataById[epochId].executed;
        bool poolVoted = executed && _poolVotedInEpoch(pool, epochId);

        require(block.timestamp >= epochId + WEEK + refundGraceSeconds, "grace");
        require(!executed || !poolVoted, "not refundable");

        BribeSlice[] storage arr = bribesByPoolEpoch[pool][epochId];
        uint256 n = arr.length;
        if (start >= n) return;

        if (maxCount > MAX_CLAIM_CHUNK) maxCount = MAX_CLAIM_CHUNK; // soft cap

        uint256 end = start + maxCount;
        if (end < start) end = n; // overflow fallback
        if (end > n) end = n;

        for (uint256 i = start; i < end; i++) {
            BribeSlice storage s = arr[i];
            if (s.depositor != msg.sender) continue;
            if (s.paid || s.refunded) continue;
            s.refunded = true;
            if (s.token == address(0)) {
                (bool ok, ) = payable(msg.sender).call{value: s.amount}("");
                require(ok, "ETH refund fail");
            } else {
                IERC20(s.token).safeTransfer(msg.sender, s.amount);
            }
            emit BribeRefunded(msg.sender, pool, epochId, s.token, s.amount);
        }
    }

    /**
    * @notice Compact paid/refunded slices for a given pool+epoch to limit storage growth.
    * @dev    Scans up to `maxScan` items. Uses swap-and-pop so it never removes unscanned entries.
    *         This reorders elements, which is fine as indices are not stable guarantees.
    */
    function pruneBribes(address pool, uint256 epochId, uint256 maxScan) external nonReentrant {
        BribeSlice[] storage arr = bribesByPoolEpoch[pool][epochId];
        uint256 before = arr.length;
        if (before == 0 || maxScan == 0) {
            emit BribesPruned(pool, epochId, 0, before);
            return;
        }

        uint256 i = 0;
        uint256 scanned = 0;
        uint256 removed = 0;

        while (i < arr.length && scanned < maxScan) {
            scanned++;
            BribeSlice storage s = arr[i];

            if (s.paid || s.refunded) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                removed++;
            } else {
                i++;
            }
        }

        emit BribesPruned(pool, epochId, removed, arr.length);
    }

    /* ============================ Voting (keeper) =========================== */

    function executeVotesWithWeights(address[] calldata pools_, uint256[] calldata weightsBps)
        external
        onlyKeeper
        nonReentrant
        whenNotPaused
    {
        require(pools_.length > 0 && pools_.length == weightsBps.length, "bad args");

        uint256 epochId = currentEpochId();
        if (epochDataById[epochId].executed) revert VoteAlreadyExecuted();

        uint256 sum;
        for (uint256 i = 0; i < weightsBps.length; i++) {
            require(weightsBps[i] == 0 || weightsBps[i] >= minVoteWeightBPS, "min");
            require(weightsBps[i] <= maxPoolAllocationBPS, "cap");
            sum += weightsBps[i];
        }
        require(sum == BPS_BASE, "sum != 100%");

        for (uint256 i = 0; i < pools_.length; i++) {
            require(poolData[pools_[i]].isActive, "inactive pool");
        }

        if (epochLock[epochId]) revert VoteInProgress();
        epochLock[epochId] = true;

        uint256 tokenId = IPermalockVault(vault).primaryNFT();
        if (tokenId == 0) { epochLock[epochId] = false; revert NoPrimaryNFT(); }

        (, , uint256 votingPower, , , ) = IPermalockVault(vault).getNFTInfo(tokenId);
        if (votingPower == 0) { epochLock[epochId] = false; revert NoVotingPower(); }

        // reset previous weights first
        bytes memory resetData = abi.encodeWithSelector(IVoter.reset.selector, tokenId);
        try IPermalockVault(vault).executeNFTAction(tokenId, voter, resetData) {
            // ok
        } catch {
            epochLock[epochId] = false;
            revert();
        }

        // then set new weights
        bytes memory voteData = abi.encodeWithSelector(IVoter.vote.selector, tokenId, pools_, weightsBps);
        try IPermalockVault(vault).executeNFTAction(tokenId, voter, voteData) {
            // ok
        } catch {
            epochLock[epochId] = false;
            revert();
        }

        epochDataById[epochId] = EpochData({
            executed: true,
            totalVotingPower: votingPower,
            pools: pools_,
            weightsBps: weightsBps,
            timestamp: block.timestamp
        });

        epochLock[epochId] = false;
        emit VotesExecuted(epochId, tokenId, pools_, weightsBps, votingPower);
    }

    function executeVotesAuto() external onlyKeeper nonReentrant whenNotPaused {
        uint256 epochId = currentEpochId();
        if (epochDataById[epochId].executed) revert VoteAlreadyExecuted();

        (address[] memory pools_, uint256[] memory weightsBps) = _calculateOptimalAllocation(epochId);
        require(pools_.length > 0, "no eligible pools");

        // --- STRICT SUM CHECK (must equal 10_000 bps) ---
        {
            uint256 s;
            for (uint256 i = 0; i < weightsBps.length; ++i) {
                s += weightsBps[i];
            }
            require(s == BPS_BASE, "auto sum != 100%");
        }
        // -----------------------------------------------

        if (epochLock[epochId]) revert VoteInProgress();
        epochLock[epochId] = true;

        uint256 tokenId = IPermalockVault(vault).primaryNFT();
        if (tokenId == 0) { epochLock[epochId] = false; revert NoPrimaryNFT(); }

        (, , uint256 votingPower, , , ) = IPermalockVault(vault).getNFTInfo(tokenId);
        if (votingPower == 0) { epochLock[epochId] = false; revert NoVotingPower(); }

        // reset previous weights first
        bytes memory resetData = abi.encodeWithSelector(IVoter.reset.selector, tokenId);
        try IPermalockVault(vault).executeNFTAction(tokenId, voter, resetData) {
            // ok
        } catch {
            epochLock[epochId] = false;
            revert();
        }

        // then set new weights
        bytes memory voteData = abi.encodeWithSelector(IVoter.vote.selector, tokenId, pools_, weightsBps);
        try IPermalockVault(vault).executeNFTAction(tokenId, voter, voteData) {
            // ok
        } catch {
            epochLock[epochId] = false;
            revert();
        }

        epochDataById[epochId] = EpochData({
            executed: true,
            totalVotingPower: votingPower,
            pools: pools_,
            weightsBps: weightsBps,
            timestamp: block.timestamp
        });

        epochLock[epochId] = false;
        emit VotesExecuted(epochId, tokenId, pools_, weightsBps, votingPower);
    }

    /* ======================= Allocation / scoring (view) ==================== */

    function _calculateOptimalAllocation(uint256 epochId)
        private
        view
        returns (address[] memory pools, uint256[] memory weightsBps)
    {
        uint256 nAll = activePools.length;
        require(nAll > 0, "no pools");

        // -------- Pass 1: count eligible & sum scores, track best-by-score
        uint256 k = 0;
        uint256 sumScores = 0;
        address bestPool = address(0);
        uint256 bestScore = 0;

        for (uint256 i = 0; i < nAll; ++i) {
            address p = activePools[i];
            if (!poolData[p].isActive) continue;

            uint256 score =
                ((poolEpochBribesUSD[p][epochId] * bribeDiscountBPS) / BPS_BASE) +
                (baseRevenueUSDByEpoch[p][epochId]);
            if (score == 0) continue;

            unchecked { ++k; }
            sumScores += score;
            if (score > bestScore) { bestScore = score; bestPool = p; }
        }
        require(k > 0 && sumScores > 0, "zero scores");

        // -------- Pass 2: materialize (poolsTmp, scores)
        address[] memory poolsTmp  = new address[](k);
        uint256[] memory scores    = new uint256[](k);
        uint256 idx = 0;
        for (uint256 i = 0; i < nAll; ++i) {
            address p = activePools[i];
            if (!poolData[p].isActive) continue;
            uint256 score =
                ((poolEpochBribesUSD[p][epochId] * bribeDiscountBPS) / BPS_BASE) +
                (baseRevenueUSDByEpoch[p][epochId]);
            if (score == 0) continue;
            poolsTmp[idx] = p;
            scores[idx]   = score;
            unchecked { ++idx; }
        }

        // -------- Base allocations (proportional, then min/cap)
        uint256[] memory alloc     = new uint256[](k);
        uint256[] memory remainder = new uint256[](k); // fractional remainder for largest-remainder method
        uint256 used = 0;
        uint256 bestIndex = 0;

        for (uint256 i = 0; i < k; ++i) {
            if (poolsTmp[i] == bestPool) bestIndex = i;

            // base proportional weight (floored)
            uint256 w = (scores[i] * BPS_BASE) / sumScores;

            // if non-zero but below min, drop to zero (only non-zero weights must satisfy min)
            if (w != 0 && w < minVoteWeightBPS) {
                alloc[i] = 0;
                remainder[i] = 0; // not eligible for remainder
                continue;
            }

            // cap
            if (w > maxPoolAllocationBPS) w = maxPoolAllocationBPS;

            alloc[i] = w;
            used += w;

            // store fractional remainder only if we still have capacity to grow
            // remainder is proportional to (scores[i] * BPS_BASE) % sumScores
            uint256 r = (scores[i] * BPS_BASE) % sumScores;
            remainder[i] = (w < maxPoolAllocationBPS) ? r : 0;
        }

        // -------- Largest-remainder distribution under cap (no 1-bp loops)
        if (used < BPS_BASE) {
            uint256 rem = BPS_BASE - used;

            // Build list of candidates that can still grow (alloc > 0; remainder > 0; alloc < cap)
            uint256 c = 0;
            for (uint256 i = 0; i < k; ++i) {
                if (alloc[i] > 0 && remainder[i] > 0 && alloc[i] < maxPoolAllocationBPS) c++;
            }

            if (c > 0) {
                uint256[] memory cand = new uint256[](c); // store indices
                uint256 t = 0;
                for (uint256 i = 0; i < k; ++i) {
                    if (alloc[i] > 0 && remainder[i] > 0 && alloc[i] < maxPoolAllocationBPS) {
                        cand[t++] = i;
                    }
                }

                // sort candidates by remainder desc (gas-cheap selection sort)
                for (uint256 i = 0; i + 1 < c; ++i) {
                    uint256 maxj = i;
                    uint256 maxv = remainder[cand[i]];
                    for (uint256 j = i + 1; j < c; ++j) {
                        uint256 v = remainder[cand[j]];
                        if (v > maxv) { maxv = v; maxj = j; }
                    }
                    if (maxj != i) { (cand[i], cand[maxj]) = (cand[maxj], cand[i]); }
                }

                // Greedily assign remainder to highest fractional remainders within capacity
                for (uint256 u = 0; u < c && rem > 0; ++u) {
                    uint256 ii = cand[u];
                    uint256 capLeft = maxPoolAllocationBPS - alloc[ii];
                    if (capLeft == 0) continue;
                    uint256 add = (rem < capLeft) ? rem : capLeft;
                    alloc[ii] += add;
                    rem -= add;
                }

                used = BPS_BASE - rem; // update used with what we placed
            }

            // If caps/min still prevent 100%, top up best pool to hit exactly 100% (may exceed cap by policy).
            if (used < BPS_BASE) {
                alloc[bestIndex] += (BPS_BASE - used);
                used = BPS_BASE;
            }
        }

        // -------- Final canonicalization to guarantee EXACT 100%
        // Sum may be < or (defensively) > 10_000 due to rounding/corner edits; repair it here.
        uint256 tot = 0;
        for (uint256 i = 0; i < k; ++i) tot += alloc[i];

        if (tot != BPS_BASE) {
            if (tot < BPS_BASE) {
                // top up best pool (policy allows surpassing cap here)
                alloc[bestIndex] += (BPS_BASE - tot);
                tot = BPS_BASE;
            } else {
                // Defensive only: scale down by 1-bp from largest allocations,
                // while keeping any non-zero allocation >= minVoteWeightBPS.
                uint256 excess = tot - BPS_BASE;

                // donors ordered by current alloc desc (simple selection)
                for (uint256 pass = 0; pass < k && excess > 0; ++pass) {
                    uint256 maxIdx = type(uint256).max;
                    uint256 maxVal = 0;
                    for (uint256 i = 0; i < k; ++i) {
                        uint256 cur = alloc[i];
                        if (cur > maxVal) { maxVal = cur; maxIdx = i; }
                    }
                    if (maxIdx == type(uint256).max || maxVal == 0) break;

                    // we can't reduce below minVoteWeightBPS if the pool remains non-zero
                    uint256 minBound = minVoteWeightBPS;
                    if (alloc[maxIdx] <= minBound) {
                        // try next best by blanking it for this pass
                        alloc[maxIdx] = 0; // temporarily zero so next loop picks the next donor
                        continue;
                    }

                    // calculate how much we can take while staying >= minBound
                    uint256 canTake = alloc[maxIdx] - minBound;
                    uint256 take = (canTake >= excess) ? excess : canTake;
                    alloc[maxIdx] -= take;
                    excess -= take;

                    // restore zeroed donors if any (no-op if not zeroed)
                    if (alloc[maxIdx] == 0) { /* leave it zero; it will be filtered later */ }
                }
                require(excess == 0, "auto: could not reduce to 100%");
            }
        }

        // -------- Compress non-zero allocations to return arrays
        uint256 m = 0;
        for (uint256 i = 0; i < k; ++i) if (alloc[i] > 0) m++;
        pools      = new address[](m);
        weightsBps = new uint256[](m);
        uint256 widx = 0;
        for (uint256 i = 0; i < k; ++i) {
            if (alloc[i] == 0) continue;
            pools[widx]      = poolsTmp[i];
            weightsBps[widx] = alloc[i];
            unchecked { ++widx; }
        }
    }


    /* ================================ Admin ================================= */

    function addPools(address[] calldata pools_) external onlyKeeper {
        for (uint256 i = 0; i < pools_.length; i++) {
            address pool = pools_[i];
            if (pool == address(0) || poolData[pool].isActive) continue;
            address gauge = IVoter(voter).gauges(pool);
            if (gauge == address(0)) continue;
            if (!IVoter(voter).isAlive(gauge)) continue;

            poolData[pool].isActive = true;
            poolData[pool].gauge = gauge;
            activePools.push(pool);
            emit PoolAdded(pool, gauge);
        }
    }

    function removePool(address pool) external onlyOwner {
        if (!poolData[pool].isActive) revert PoolNotActive();
        poolData[pool].isActive = false;
        uint256 L = activePools.length;
        for (uint256 i = 0; i < L; i++) {
            if (activePools[i] == pool) {
                activePools[i] = activePools[L - 1];
                activePools.pop();
                break;
            }
        }
        emit PoolRemoved(pool);
    }

    function setKeeper(address who, bool status) external onlyOwner {
        keepers[who] = status;
        emit KeeperSet(who, status);
    }

    function setParams(
        uint256 _minBribeUSDPerEpoch,
        uint256 _bribeDiscountBPS,
        uint256 _maxPoolAllocationBPS,
        uint256 _minVoteWeightBPS
    ) external onlyOwner {
        require(_bribeDiscountBPS <= BPS_BASE, "disc");
        require(_maxPoolAllocationBPS <= BPS_BASE, "cap");
        require(_minVoteWeightBPS > 0 && _minVoteWeightBPS <= BPS_BASE, "min");
        minBribeUSDPerEpoch  = _minBribeUSDPerEpoch;
        bribeDiscountBPS     = _bribeDiscountBPS;
        maxPoolAllocationBPS = _maxPoolAllocationBPS;
        minVoteWeightBPS     = _minVoteWeightBPS;
    }

    function setRefundGrace(uint256 seconds_) external onlyOwner {
        refundGraceSeconds = seconds_;
        emit RefundGraceSet(seconds_);
    }

    function setBaseRevenueForEpoch(address[] calldata pools_, uint256[] calldata epochIds, uint256[] calldata usdAmounts)
        external
        onlyKeeper
    {
        if (pools_.length != epochIds.length || pools_.length != usdAmounts.length) revert LenMismatch();
        for (uint256 i = 0; i < pools_.length; i++) {
            if (!poolData[pools_[i]].isActive) revert PoolNotActive();
            if (!isEpochStart(epochIds[i])) revert EpochMisaligned();
            baseRevenueUSDByEpoch[pools_[i]][epochIds[i]] = usdAmounts[i];
            emit BaseRevenueSet(pools_[i], epochIds[i], usdAmounts[i]);
        }
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // Emergency sweep – restricted so refundable bribes cannot be drained.
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        // Disallow sweeping ETH or any token that is allowed for bribes
        if (token == address(0) || allowedBribeTokens[token]) revert ForbiddenSweep();
        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdraw(token, amount, owner());
    }

    /* ================================= Views ================================ */

    function getActivePools() external view returns (address[] memory) { return activePools; }

    function getPoolInfo(address pool) external view returns (bool isActive, address gauge) {
        PoolData storage d = poolData[pool];
        return (d.isActive, d.gauge);
    }

    function getBribeCount(address pool, uint256 epochId) external view returns (uint256) {
        return bribesByPoolEpoch[pool][epochId].length;
    }

    function getBribes(address pool, uint256 epochId, uint256 start, uint256 maxCount)
        external
        view
        returns (BribeSlice[] memory out)
    {
        BribeSlice[] storage arr = bribesByPoolEpoch[pool][epochId];
        uint256 n = arr.length;
        if (start >= n) return new BribeSlice[](0);

        uint256 end = start + maxCount;
        if (end < start) end = n;
        if (end > n) end = n;

        uint256 len = end - start;
        out = new BribeSlice[](len);

        for (uint256 i = 0; i < len; ) {
            out[i] = arr[start + i];
            unchecked { ++i; }
        }
    }


    function getBribeAt(address pool, uint256 epochId, uint256 idx) external view returns (BribeSlice memory) {
        BribeSlice[] storage arr = bribesByPoolEpoch[pool][epochId];
        require(idx < arr.length, "oob");
        return arr[idx];
    }

    function nextUnpaidBribeIndex(address pool, uint256 epochId)
        external
        view
        returns (uint256 idx, bool found)
    {
        BribeSlice[] storage arr = bribesByPoolEpoch[pool][epochId];
        for (uint256 i = 0; i < arr.length; i++) {
            BribeSlice storage s = arr[i];
            if (!s.paid && !s.refunded) return (i, true);
        }
        return (arr.length, false);
    }

    function canRefund(address pool, uint256 epochId) public view returns (bool) {
        bool executed = epochDataById[epochId].executed;
        bool poolVoted = executed && _poolVotedInEpoch(pool, epochId);
        return block.timestamp >= epochId + WEEK + refundGraceSeconds && (!executed || !poolVoted);
    }

    function nextRefundableBribeIndex(address pool, uint256 epochId, address depositor)
        external
        view
        returns (uint256 idx, bool found)
    {
        if (!canRefund(pool, epochId)) return (0, false);
        BribeSlice[] storage arr = bribesByPoolEpoch[pool][epochId];
        for (uint256 i = 0; i < arr.length; i++) {
            BribeSlice storage s = arr[i];
            if (s.depositor == depositor && !s.paid && !s.refunded) return (i, true);
        }
        return (arr.length, false);
    }

    function previewClaimTotals(
        address pool,
        uint256 epochId,
        uint256 start,
        uint256 maxCount
    )
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        BribeSlice[] storage arr = bribesByPoolEpoch[pool][epochId];
        uint256 n = arr.length;

        // Early exit if epoch not executed, pool wasn't voted, or range is empty
        if (!epochDataById[epochId].executed || !_poolVotedInEpoch(pool, epochId) || start >= n) {
            return (new address[](0), new uint256[](0));
        }

        if (maxCount > MAX_CLAIM_CHUNK) maxCount = MAX_CLAIM_CHUNK; // soft cap

        // Compute (start, end) with overflow guard
        uint256 end = start + maxCount;
        if (end < start) end = n; // overflow fallback (very large maxCount)
        if (end > n) end = n;

        uint256 cap = end - start; // safe since end >= start
        tokens  = new address[](cap);
        amounts = new uint256[](cap);

        uint256 uniq = 0;
        for (uint256 i = start; i < end; i++) {
            BribeSlice storage s = arr[i];
            if (s.paid || s.refunded) continue;

            // Aggregate by token
            uint256 j = 0;
            for (; j < uniq; j++) {
                if (tokens[j] == s.token) {
                    amounts[j] += s.amount;
                    break;
                }
            }
            if (j == uniq) {
                tokens[uniq]  = s.token;
                amounts[uniq] = s.amount;
                unchecked { ++uniq; }
            }
        }

        // Shrink arrays to the number of unique tokens encountered
        assembly {
            mstore(tokens, uniq)
            mstore(amounts, uniq)
        }
    }

    function getOptimalAllocation() external view returns (address[] memory pools, uint256[] memory weightsBps) {
        return _calculateOptimalAllocation(currentEpochId());
    }

    function wasExecuted(uint256 epochId) external view returns (bool) { return epochDataById[epochId].executed; }

    function canExecuteVotes() external view returns (bool) {
        uint256 epochId = currentEpochId();
        return (!epochDataById[epochId].executed && !epochLock[epochId]);
    }

    function getDepositedBribesUSD(address pool, uint256 epochId) external view returns (uint256) {
        return poolEpochBribesUSD[pool][epochId];
    }

    /* ============================== Internals =============================== */

    function _poolVotedInEpoch(address pool, uint256 epochId) internal view returns (bool) {
        EpochData storage ed = epochDataById[epochId];
        if (!ed.executed) return false;
        for (uint256 i = 0; i < ed.pools.length; i++) {
            if (ed.pools[i] == pool) return true;
        }
        return false;
    }

    receive() external payable {}
}
