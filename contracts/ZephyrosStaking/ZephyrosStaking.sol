// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC721/IERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC721/IERC721Receiver.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/ReentrancyGuard.sol";

interface ICoreToken is IERC20 {
    function burn(uint256 amount) external;
}

contract CoreAscensionV2 is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;
    using SafeERC20 for ICoreToken;

    ICoreToken public immutable core;

    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_CORE_STAKE = 10_000 ether;
    uint256 public constant MIN_STAKE_TIME = 60 days;

    uint256 private constant ELECTRONEUM_BLOCK_TIME_SECONDS = 5;
    uint256 public constant BLOCKS_PER_YEAR_ESTIMATE = 6_307_200;

    uint256 private constant EARLY_REWARD_SLASH_BPS = 5_000; // 50%
    uint256 private constant EARLY_STAKE_PENALTY_BPS = 1_500; // 15%

    uint256 private constant PENALTY_TO_POOL_NUM = 2;
    uint256 private constant PENALTY_TO_POOL_DEN = 3;

    uint256 public constant MAX_NFTS_PER_USER = 4;

    uint256 private constant BOOST_1_NFT = 10_000;
    uint256 private constant BOOST_2_NFT = 11_000;
    uint256 private constant BOOST_3_NFT = 12_000;
    uint256 private constant BOOST_4_NFT = 13_000;

    uint256 private constant ACC_PRECISION = 1e24;

    enum EligibilityMode {
        AllTokensAllowed,
        OnlyApprovedTokenIds
    }

    struct CollectionConfig {
        bool whitelisted;
        EligibilityMode mode;
    }

    struct StakedNFT {
        address collection;
        uint256 tokenId;
    }

    struct UserInfo {
        uint256 coreStaked;
        uint256 rewardWeight;
        uint256 rewardDebt;
        uint256 unclaimedRewards;
        uint256 entryTime;
        StakedNFT[] nfts;
    }

    // ==================== ADMIN WHITELIST ====================
    mapping(address => bool) public isAdmin;

    // ==================== STATE VARIABLES ====================
    mapping(address => CollectionConfig) public collections;
    mapping(address => mapping(uint256 => bool)) public approvedTokenId;
    mapping(bytes32 => bool) public whitelistedBackgroundHash;

    mapping(address => UserInfo) private users;
    mapping(address => mapping(uint256 => address)) public nftStaker;

    uint256 public totalCoreStaked;
    uint256 public totalRewardWeight;

    uint256 public accRewardPerWeight;
    uint256 public lastRewardBlock;
    uint256 public rewardPerBlock;
    uint256 public endBlock;

    uint256 public queuedRewards;
    uint256 public totalRewardsFunded;
    uint256 public totalRewardsPaid;
    uint256 public totalRewardsSlashedToPool;
    uint256 public totalCorePenaltyToPool;
    uint256 public totalCoreBurned;

    // Events
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event CollectionConfigured(address indexed collection, bool whitelisted, EligibilityMode mode);
    event TokenEligibilitySet(address indexed collection, uint256 indexed tokenId, bool eligible);
    event BackgroundWhitelistSet(string background, bool allowed);
    event RewardsFunded(address indexed funder, uint256 amount, uint256 queuedRewardsUsed, uint256 durationBlocks, uint256 rewardPerBlock, uint256 endBlock);
    event PenaltyAddedToRewards(uint256 amount, bool queued);
    event NFTStaked(address indexed user, address indexed collection, uint256 indexed tokenId);
    event NFTWithdrawn(address indexed user, address indexed collection, uint256 indexed tokenId);
    event CoreStaked(address indexed user, uint256 amount);
    event CoreWithdrawn(address indexed user, uint256 requestedAmount, uint256 returnedAmount, uint256 penaltyToPool, uint256 penaltyBurned);
    event RewardPaid(address indexed user, uint256 paidAmount, uint256 slashedAmount);
    event Exited(address indexed user);

    constructor(address coreToken) Ownable(msg.sender) {
        require(coreToken != address(0), "CORE0");
        core = ICoreToken(coreToken);
        lastRewardBlock = block.number;
        isAdmin[msg.sender] = true; // Owner is admin by default
    }

    // =============================================================
    // Admin Management
    // =============================================================

    modifier onlyAdmin() {
        require(isAdmin[msg.sender] || msg.sender == owner(), "Not admin");
        _;
    }

    function addAdmin(address newAdmin) external onlyOwner {
        require(newAdmin != address(0), "ZERO");
        require(!isAdmin[newAdmin], "ALREADY_ADMIN");
        isAdmin[newAdmin] = true;
        emit AdminAdded(newAdmin);
    }

    function removeAdmin(address admin) external onlyOwner {
        require(isAdmin[admin], "NOT_ADMIN");
        isAdmin[admin] = false;
        emit AdminRemoved(admin);
    }

    // =============================================================
    // Admin Functions
    // =============================================================

    function configureCollection(
        address collection,
        bool whitelisted,
        EligibilityMode mode
    ) external onlyAdmin {
        require(collection != address(0), "COL0");
        collections[collection] = CollectionConfig({whitelisted: whitelisted, mode: mode});
        emit CollectionConfigured(collection, whitelisted, mode);
    }

    function setApprovedTokenId(address collection, uint256 tokenId, bool eligible) external onlyAdmin {
        require(collection != address(0), "COL0");
        approvedTokenId[collection][tokenId] = eligible;
        emit TokenEligibilitySet(collection, tokenId, eligible);
    }

    function batchSetApprovedTokenIds(
        address collection,
        uint256[] calldata tokenIds,
        bool eligible
    ) external onlyAdmin {
        require(collection != address(0), "COL0");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            approvedTokenId[collection][tokenIds[i]] = eligible;
            emit TokenEligibilitySet(collection, tokenIds[i], eligible);
        }
    }

    function setWhitelistedBackground(string calldata background, bool allowed) external onlyAdmin {
        bytes32 hash = keccak256(bytes(background));
        whitelistedBackgroundHash[hash] = allowed;
        emit BackgroundWhitelistSet(background, allowed);
    }

    function fundRewards(uint256 amount, uint256 durationBlocks) external onlyAdmin nonReentrant updateReward(address(0)) {
        require(amount > 0 || queuedRewards > 0, "NOREW");
        require(durationBlocks > 0, "DUR0");

        if (amount > 0) {
            core.safeTransferFrom(msg.sender, address(this), amount);
            totalRewardsFunded += amount;
        }

        uint256 remainingRewards = 0;
        if (block.number < endBlock) {
            remainingRewards = (endBlock - block.number) * rewardPerBlock;
        }

        uint256 rewardsToSchedule = amount + queuedRewards + remainingRewards;
        require(rewardsToSchedule > 0, "NOSCH");

        rewardPerBlock = rewardsToSchedule / durationBlocks;
        require(rewardPerBlock > 0, "RPB0");

        queuedRewards = 0;
        lastRewardBlock = block.number;
        endBlock = block.number + durationBlocks;

        emit RewardsFunded(msg.sender, amount, queuedRewards, durationBlocks, rewardPerBlock, endBlock);
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyAdmin {
        require(token != address(core), "CORE");
        require(to != address(0), "TO0");
        IERC20(token).safeTransfer(to, amount);
    }

    function rescueUnstakedNFT(address collection, uint256 tokenId, address to) external onlyAdmin nonReentrant {
        require(collection != address(0), "COL0");
        require(to != address(0), "TO0");
        require(nftStaker[collection][tokenId] == address(0), "STAKED");
        IERC721(collection).safeTransferFrom(address(this), to, tokenId);
    }

    // =============================================================
    // User Functions
    // =============================================================

    function stakeNFT(address collection, uint256 tokenId) external nonReentrant updateReward(msg.sender) {
        require(isNFTEligible(collection, tokenId), "BADNFT");

        UserInfo storage user = users[msg.sender];
        require(user.nfts.length < MAX_NFTS_PER_USER, "MAXNFT");
        require(nftStaker[collection][tokenId] == address(0), "DUPNFT");

        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);

        nftStaker[collection][tokenId] = msg.sender;
        user.nfts.push(StakedNFT({collection: collection, tokenId: tokenId}));

        _refreshUserWeight(msg.sender);

        emit NFTStaked(msg.sender, collection, tokenId);
    }

    function stakeCore(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "AMT0");

        UserInfo storage user = users[msg.sender];
        require(user.nfts.length >= 1, "NFTREQ");
        require(user.coreStaked + amount <= MAX_CORE_STAKE, "MAXCORE");

        user.entryTime = block.timestamp;

        user.coreStaked += amount;
        totalCoreStaked += amount;

        core.safeTransferFrom(msg.sender, address(this), amount);

        _refreshUserWeight(msg.sender);

        emit CoreStaked(msg.sender, amount);
    }

    function claim() external nonReentrant updateReward(msg.sender) {
        _claim(msg.sender);
    }

    function withdrawCore(uint256 amount) external nonReentrant updateReward(msg.sender) {
        UserInfo storage user = users[msg.sender];
        require(amount > 0, "AMT0");
        require(amount <= user.coreStaked, "STAKE");
        require(user.nfts.length >= 1, "NFTREQ");

        _claim(msg.sender);

        user.coreStaked -= amount;
        totalCoreStaked -= amount;

        uint256 returnedAmount = amount;
        uint256 penaltyToPool = 0;
        uint256 penaltyBurned = 0;

        if (_isEarly(user.entryTime)) {
            uint256 totalPenalty = (amount * EARLY_STAKE_PENALTY_BPS) / BPS;
            penaltyToPool = (totalPenalty * PENALTY_TO_POOL_NUM) / PENALTY_TO_POOL_DEN;
            penaltyBurned = totalPenalty - penaltyToPool;
            returnedAmount = amount - totalPenalty;

            totalCorePenaltyToPool += penaltyToPool;
            totalCoreBurned += penaltyBurned;

            if (penaltyToPool > 0) _addPenaltyToRewards(penaltyToPool);
            if (penaltyBurned > 0) core.burn(penaltyBurned);
        }

        if (user.coreStaked == 0) user.entryTime = 0;

        _refreshUserWeight(msg.sender);
        core.safeTransfer(msg.sender, returnedAmount);

        emit CoreWithdrawn(msg.sender, amount, returnedAmount, penaltyToPool, penaltyBurned);
    }

    function withdrawNFT(address collection, uint256 tokenId) external nonReentrant updateReward(msg.sender) {
        UserInfo storage user = users[msg.sender];
        require(nftStaker[collection][tokenId] == msg.sender, "NOTNFT");

        if (user.coreStaked > 0) {
            require(user.nfts.length > 1, "KEEPNFT");
        }

        _removeUserNFT(user, collection, tokenId);
        nftStaker[collection][tokenId] = address(0);

        _refreshUserWeight(msg.sender);

        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);

        emit NFTWithdrawn(msg.sender, collection, tokenId);
    }

    function exit() external nonReentrant updateReward(msg.sender) {
        UserInfo storage user = users[msg.sender];
        require(user.coreStaked > 0 || user.nfts.length > 0, "NOPOS");

        _claim(msg.sender);

        uint256 amount = user.coreStaked;
        uint256 returnedAmount = amount;
        uint256 penaltyToPool = 0;
        uint256 penaltyBurned = 0;

        if (amount > 0) {
            user.coreStaked = 0;
            totalCoreStaked -= amount;

            if (_isEarly(user.entryTime)) {
                uint256 totalPenalty = (amount * EARLY_STAKE_PENALTY_BPS) / BPS;
                penaltyToPool = (totalPenalty * PENALTY_TO_POOL_NUM) / PENALTY_TO_POOL_DEN;
                penaltyBurned = totalPenalty - penaltyToPool;
                returnedAmount = amount - totalPenalty;

                totalCorePenaltyToPool += penaltyToPool;
                totalCoreBurned += penaltyBurned;

                if (penaltyToPool > 0) _addPenaltyToRewards(penaltyToPool);
                if (penaltyBurned > 0) core.burn(penaltyBurned);
            }
        }

        uint256 nftCount = user.nfts.length;
        StakedNFT[] memory nftList = new StakedNFT[](nftCount);
        for (uint256 i = 0; i < nftCount; i++) {
            nftList[i] = user.nfts[i];
            nftStaker[nftList[i].collection][nftList[i].tokenId] = address(0);
        }

        delete user.nfts;
        user.entryTime = 0;

        _refreshUserWeight(msg.sender);

        if (returnedAmount > 0) core.safeTransfer(msg.sender, returnedAmount);

        for (uint256 i = 0; i < nftList.length; i++) {
            IERC721(nftList[i].collection).safeTransferFrom(address(this), msg.sender, nftList[i].tokenId);
            emit NFTWithdrawn(msg.sender, nftList[i].collection, nftList[i].tokenId);
        }

        emit CoreWithdrawn(msg.sender, amount, returnedAmount, penaltyToPool, penaltyBurned);
        emit Exited(msg.sender);
    }

    // =============================================================
    // Views
    // =============================================================

    function isNFTEligible(address collection, uint256 tokenId) public view returns (bool) {
        CollectionConfig memory config = collections[collection];
        if (!config.whitelisted) return false;
        if (config.mode == EligibilityMode.AllTokensAllowed) return true;
        return approvedTokenId[collection][tokenId];
    }

    function getUser(address account) external view returns (
        uint256 coreStaked,
        uint256 nftCount,
        uint256 rewardWeight,
        uint256 entryTime,
        uint256 pendingRewards,
        bool currentlyEarly,
        uint256 boostBps
    ) {
        UserInfo storage user = users[account];
        coreStaked = user.coreStaked;
        nftCount = user.nfts.length;
        rewardWeight = user.rewardWeight;
        entryTime = user.entryTime;
        pendingRewards = earned(account);
        currentlyEarly = _isEarly(entryTime);
        boostBps = _boostForNFTCount(nftCount);
    }

    function earned(address account) public view returns (uint256) {
        UserInfo storage user = users[account];
        uint256 currentAcc = _currentAccRewardPerWeight();
        uint256 accumulated = (user.rewardWeight * currentAcc) / ACC_PRECISION;
        return user.unclaimedRewards + accumulated - user.rewardDebt;
    }

    function isBackgroundWhitelisted(string calldata background) external view returns (bool) {
        return whitelistedBackgroundHash[keccak256(bytes(background))];
    }

    function lastRewardBlockApplicable() public view returns (uint256) {
        return block.number < endBlock ? block.number : endBlock;
    }

    // =============================================================
    // Internal Functions
    // =============================================================

    modifier updateReward(address account) {
        accRewardPerWeight = _currentAccRewardPerWeight();
        lastRewardBlock = lastRewardBlockApplicable();

        if (account != address(0)) {
            UserInfo storage user = users[account];
            uint256 accumulated = (user.rewardWeight * accRewardPerWeight) / ACC_PRECISION;
            user.unclaimedRewards += accumulated - user.rewardDebt;
            user.rewardDebt = (user.rewardWeight * accRewardPerWeight) / ACC_PRECISION;
        }
        _;
    }

    function _currentAccRewardPerWeight() internal view returns (uint256) {
        if (totalRewardWeight == 0) return accRewardPerWeight;

        uint256 applicableBlock = lastRewardBlockApplicable();
        if (applicableBlock <= lastRewardBlock) return accRewardPerWeight;

        uint256 blocksElapsed = applicableBlock - lastRewardBlock;
        uint256 reward = blocksElapsed * rewardPerBlock;

        return accRewardPerWeight + ((reward * ACC_PRECISION) / totalRewardWeight);
    }

    function _claim(address account) internal {
        UserInfo storage user = users[account];
        uint256 reward = user.unclaimedRewards;
        if (reward == 0) return;

        user.unclaimedRewards = 0;

        uint256 slashAmount = 0;
        uint256 payAmount = reward;

        if (_isEarly(user.entryTime)) {
            slashAmount = (reward * EARLY_REWARD_SLASH_BPS) / BPS;
            payAmount = reward - slashAmount;

            if (slashAmount > 0) {
                totalRewardsSlashedToPool += slashAmount;
                _addPenaltyToRewards(slashAmount);
            }
        }

        if (payAmount > 0) {
            totalRewardsPaid += payAmount;
            core.safeTransfer(account, payAmount);
        }

        user.rewardDebt = (user.rewardWeight * accRewardPerWeight) / ACC_PRECISION;

        emit RewardPaid(account, payAmount, slashAmount);
    }

    function _refreshUserWeight(address account) internal {
        UserInfo storage user = users[account];
        uint256 oldWeight = user.rewardWeight;
        uint256 newWeight = 0;

        if (user.coreStaked > 0 && user.nfts.length >= 1) {
            newWeight = (user.coreStaked * _boostForNFTCount(user.nfts.length)) / BPS;
        }

        if (newWeight > oldWeight) {
            totalRewardWeight += newWeight - oldWeight;
        } else if (oldWeight > newWeight) {
            totalRewardWeight -= oldWeight - newWeight;
        }

        user.rewardWeight = newWeight;
        user.rewardDebt = (newWeight * accRewardPerWeight) / ACC_PRECISION;
    }

    function _addPenaltyToRewards(uint256 amount) internal {
        if (amount == 0) return;

        if (block.number >= endBlock || rewardPerBlock == 0) {
            queuedRewards += amount;
            emit PenaltyAddedToRewards(amount, true);
            return;
        }

        uint256 remainingBlocks = endBlock - block.number;
        if (remainingBlocks == 0) {
            queuedRewards += amount;
            emit PenaltyAddedToRewards(amount, true);
            return;
        }

        uint256 remainingRewards = remainingBlocks * rewardPerBlock;
        rewardPerBlock = (remainingRewards + amount) / remainingBlocks;

        emit PenaltyAddedToRewards(amount, false);
    }

    function _boostForNFTCount(uint256 nftCount) internal pure returns (uint256) {
        if (nftCount == 1) return BOOST_1_NFT;
        if (nftCount == 2) return BOOST_2_NFT;
        if (nftCount == 3) return BOOST_3_NFT;
        if (nftCount == 4) return BOOST_4_NFT;
        return 0;
    }

    function _isEarly(uint256 entryTime) internal view returns (bool) {
        return entryTime != 0 && block.timestamp < entryTime + MIN_STAKE_TIME;
    }

    function _removeUserNFT(UserInfo storage user, address collection, uint256 tokenId) internal {
        uint256 length = user.nfts.length;
        for (uint256 i = 0; i < length; i++) {
            if (user.nfts[i].collection == collection && user.nfts[i].tokenId == tokenId) {
                user.nfts[i] = user.nfts[length - 1];
                user.nfts.pop();
                return;
            }
        }
        revert("NO_NFT");
    }

    function onERC721Received(
        address, address, uint256, bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}