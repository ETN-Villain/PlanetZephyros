// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
██████╗  ██████╗ ██╗  ████████╗     ██╗ █████╗ ██████╗ ███████╗
██╔══██╗██╔═══██╗██║  ╚══██╔══╝     ██║██╔══██╗██╔══██╗██╔════╝
██████╔╝██║   ██║██║     ██║        ██║███████║██████╔╝███████╗
██╔══██╗██║   ██║██║     ██║   ██   ██║██╔══██║██╔══██╗╚════██║
██████╔╝╚██████╔╝███████╗██║   ╚█████╔╝██║  ██║██║  ██║███████║
╚═════╝  ╚═════╝ ╚══════╝╚═╝    ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝

   ███████╗██████╗ ██╗███╗   ██╗    ██╗    ██╗██╗  ██╗███████╗███████╗██╗     
   ██╔════╝██╔══██╗██║████╗  ██║    ██║    ██║██║  ██║██╔════╝██╔════╝██║     
   ███████╗██████╔╝██║██╔██╗ ██║    ██║ █╗ ██║███████║█████╗  █████╗  ██║     
   ╚════██║██╔═══╝ ██║██║╚██╗██║    ██║███╗██║██╔══██║██╔══╝  ██╔══╝  ██║     
   ███████║██║     ██║██║ ╚████║    ╚███╔███╔╝██║  ██║███████╗███████╗███████╗
   ╚══════╝╚═╝     ╚═╝╚═╝  ╚═══╝     ╚══╝╚══╝ ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝
*/
/*
    BOLT Jar Spin Wheel Reward Vault

    Flow:
    1. Owner deposits CLUB tokens into this contract.
    2. Owner whitelists one or more NFT contracts.
    3. Frontend/backend checks NFT balances off-chain.
    4. Authorized operator calls rewardWinner(wallet, amount) to send CLUB.
    5. Owner can withdraw unused CLUB at any time.

    Notes:
    - This contract does NOT enforce "1 spin per day per NFT" on-chain.
    - That rule is enforced by your backend/UI.
    - The contract is intentionally simple and centralized around trusted operators.
*/

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC721Like {
    function balanceOf(address owner) external view returns (uint256);
}

abstract contract Ownable {
    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

contract CLUBSpinVault is Ownable {
    error ZeroAddress();
    error NotOperator();
    error NFTNotWhitelisted();
    error InsufficientClubBalance();
    error TransferFailed();

    IERC20 public immutable clubToken;

    // Authorized backend wallets that can send rewards
    mapping(address => bool) public operators;

    // NFT whitelist
    mapping(address => bool) public whitelistedNFTs;
    address[] public whitelistedNFTList;

    event OperatorUpdated(address indexed operator, bool allowed);
    event NFTWhitelisted(address indexed nft, bool allowed);
    event RewardPaid(address indexed operator, address indexed winner, uint256 amount);
    event ClubWithdrawn(address indexed to, uint256 amount);

    modifier onlyOperator() {
        if (!operators[msg.sender] && msg.sender != owner()) revert NotOperator();
        _;
    }

    constructor(address initialOwner, address clubTokenAddress) Ownable(initialOwner) {
        if (clubTokenAddress == address(0)) revert ZeroAddress();
        clubToken = IERC20(clubTokenAddress);
    }

    // -----------------------------
    // Admin
    // -----------------------------

    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    function setWhitelistedNFT(address nft, bool allowed) external onlyOwner {
        if (nft == address(0)) revert ZeroAddress();

        bool already = whitelistedNFTs[nft];
        whitelistedNFTs[nft] = allowed;

        // Only push once when first whitelisted
        if (allowed && !already) {
            whitelistedNFTList.push(nft);
        }

        emit NFTWhitelisted(nft, allowed);
    }

    // -----------------------------
    // Reward payout
    // -----------------------------

    /**
     * @notice Sends CLUB reward to a winner.
     * @dev Backend/UI decides winner amount off-chain.
     */
    function rewardWinner(address winner, uint256 amount) external onlyOperator {
        if (winner == address(0)) revert ZeroAddress();
        if (clubToken.balanceOf(address(this)) < amount) revert InsufficientClubBalance();

        bool ok = clubToken.transfer(winner, amount);
        if (!ok) revert TransferFailed();

        emit RewardPaid(msg.sender, winner, amount);
    }

    /**
     * @notice Batch payout helper for multiple winners.
     */
    function rewardWinners(address[] calldata winners, uint256[] calldata amounts) external onlyOperator {
        uint256 length = winners.length;
        require(length == amounts.length, "Length mismatch");

        for (uint256 i = 0; i < length; i++) {
            address winner = winners[i];
            uint256 amount = amounts[i];

            if (winner == address(0)) revert ZeroAddress();
            if (clubToken.balanceOf(address(this)) < amount) revert InsufficientClubBalance();

            bool ok = clubToken.transfer(winner, amount);
            if (!ok) revert TransferFailed();

            emit RewardPaid(msg.sender, winner, amount);
        }
    }

    /**
     * @notice Owner emergency/fallback withdraw of CLUB tokens.
     */
    function withdrawClub(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (clubToken.balanceOf(address(this)) < amount) revert InsufficientClubBalance();

        bool ok = clubToken.transfer(to, amount);
        if (!ok) revert TransferFailed();

        emit ClubWithdrawn(to, amount);
    }

    /**
     * @notice Withdraw full CLUB balance to owner.
     */
    function withdrawAllClub() external onlyOwner {
        uint256 bal = clubToken.balanceOf(address(this));
        if (bal == 0) revert InsufficientClubBalance();

        bool ok = clubToken.transfer(owner(), bal);
        if (!ok) revert TransferFailed();

        emit ClubWithdrawn(owner(), bal);
    }

    // -----------------------------
    // View helpers for UI/backend
    // -----------------------------

    /**
     * @notice Returns true if wallet holds at least 1 token from a specific whitelisted NFT collection.
     */
    function holdsWhitelistedNFT(address wallet, address nft) external view returns (bool) {
        if (!whitelistedNFTs[nft]) revert NFTNotWhitelisted();
        return IERC721Like(nft).balanceOf(wallet) > 0;
    }

    /**
     * @notice Returns how many tokens from a specific whitelisted NFT collection a wallet holds.
     */
    function balanceOfWhitelistedNFT(address wallet, address nft) external view returns (uint256) {
        if (!whitelistedNFTs[nft]) revert NFTNotWhitelisted();
        return IERC721Like(nft).balanceOf(wallet);
    }

    /**
     * @notice Returns total NFTs held across all currently-whitelisted collections.
     * @dev Useful if you whitelist multiple Jar collections.
     */
    function totalWhitelistedNFTBalance(address wallet) external view returns (uint256 total) {
        uint256 length = whitelistedNFTList.length;

        for (uint256 i = 0; i < length; i++) {
            address nft = whitelistedNFTList[i];
            if (whitelistedNFTs[nft]) {
                total += IERC721Like(nft).balanceOf(wallet);
            }
        }
    }

    /**
     * @notice Returns current CLUB balance held by this vault.
     */
    function clubBalance() external view returns (uint256) {
        return clubToken.balanceOf(address(this));
    }

    /**
     * @notice Returns the current whitelist array.
     */
    function getWhitelistedNFTs() external view returns (address[] memory) {
        return whitelistedNFTList;
    }
}