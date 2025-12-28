// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./CoreClashRarityLookupTable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CCTest3 is CoreClashRarityLookupTable {
    using SafeERC20 for IERC20;
    // =============================================================
    //                           STORAGE
    // =============================================================

    struct Game {
        address player1;
        address player2;
        address stakeToken;
        uint256 stakeAmount;
        string tokenURI1; // masked team metadata (P1)
        string tokenURI2; // masked team metadata (P2)
        uint256 createdAt;
        bool settled;
    }

    Game[] internal games;

    mapping(address => bool) public allowedERC20;

    uint256 public minStake;
    address public teamWallet;
    uint256 public platformFee; // basis points (200 = 2%)

    // =============================================================
    //                           EVENTS
    // =============================================================

    event GameCreated(uint256 indexed gameId, address indexed player1);
    event GameJoined(uint256 indexed gameId, address indexed player2);
    event GameSettled(
        uint256 indexed gameId,
        address winner,
        uint256 payout,
        uint256 fee
    );

    event MinStakeUpdated(uint256 newMinStake);
    event PlatformFeeUpdated(uint256 newFee);
    event TeamWalletUpdated(address newWallet);
    event AllowedERC20Updated(address token, bool allowed);

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor() CoreClashRarityLookupTable() {}

    // =============================================================
    //                          GETTERS
    // =============================================================

    function getGamesCount() external view returns (uint256) {
        return games.length;
    }

    function getGame(uint256 gameId)
        external
        view
        returns (
            address player1,
            address player2,
            address stakeToken,
            uint256 stakeAmount,
            string memory tokenURI1,
            string memory tokenURI2,
            bool settled,
            uint256 createdAt
        )
    {
        Game storage g = games[gameId];
        return (
            g.player1,
            g.player2,
            g.stakeToken,
            g.stakeAmount,
            g.tokenURI1,
            g.tokenURI2,
            g.settled,
            g.createdAt
        );
    }

    // =============================================================
    //                      ADMIN FUNCTIONS
    // =============================================================

    function setMinStake(uint256 _minStake) external onlyOwner {
        minStake = _minStake;
        emit MinStakeUpdated(_minStake);
    }

    function setPlatformFee(uint256 _platformFee) external onlyOwner {
        require(_platformFee <= 1000, "Fee too high"); // max 10%
        platformFee = _platformFee;
        emit PlatformFeeUpdated(_platformFee);
    }

    function setTeamWallet(address _teamWallet) external onlyOwner {
        require(_teamWallet != address(0), "Zero address");
        teamWallet = _teamWallet;
        emit TeamWalletUpdated(_teamWallet);
    }

    function setAllowedERC20(address token, bool allowed) external onlyOwner {
        allowedERC20[token] = allowed;
        emit AllowedERC20Updated(token, allowed);
    }

    // =============================================================
    //                      GAME FUNCTIONS
    // =============================================================

    /**
     * @notice Player 1 creates a game (team masked)
     */
    function createGame(
        address stakeToken,
        uint256 stakeAmount,
        string calldata tokenURI
    ) external {
        require(stakeAmount >= minStake, "Stake too low");
        require(allowedERC20[stakeToken], "ERC20 not allowed");

        IERC20(stakeToken).safeTransferFrom(
            msg.sender,
            address(this),
            stakeAmount
        );

        games.push(
            Game({
                player1: msg.sender,
                player2: address(0),
                stakeToken: stakeToken,
                stakeAmount: stakeAmount,
                tokenURI1: tokenURI,
                tokenURI2: "",
                createdAt: block.timestamp,
                settled: false
            })
        );

        emit GameCreated(games.length - 1, msg.sender);
    }

    /**
     * @notice Player 2 joins an existing game
     */
    function joinGame(
        uint256 gameId,
        string calldata tokenURI
    ) external {
        Game storage g = games[gameId];

        require(g.player1 != address(0), "Game not found");
        require(g.player2 == address(0), "Game already joined");
        //require(msg.sender != g.player1, "Cannot join own game"); commented out for testing

        IERC20(g.stakeToken).safeTransferFrom(
            msg.sender,
            address(this),
            g.stakeAmount
        );

        g.player2 = msg.sender;
        g.tokenURI2 = tokenURI;

        emit GameJoined(gameId, msg.sender);
    }

    /**
     * @notice Admin settles game (winner logic external/off-chain for now)
     */
    function settleGame(
        uint256 gameId,
        address winner
    ) external onlyOwner {
        Game storage g = games[gameId];

        require(!g.settled, "Already settled");
        require(
            winner == g.player1 || winner == g.player2,
            "Invalid winner"
        );

        g.settled = true;

        uint256 totalPot = g.stakeAmount * 2;
        uint256 fee = (totalPot * platformFee) / 10_000;
        uint256 payout = totalPot - fee;

        if (fee > 0 && teamWallet != address(0)) {
            IERC20(g.stakeToken).transfer(teamWallet, fee);
        }

        IERC20(g.stakeToken).safeTransfer(winner, payout);

        emit GameSettled(gameId, winner, payout, fee);
    }
}