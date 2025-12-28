// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./CoreClashRarityLookupTable.sol";

contract CoreClashGame is CoreClashRarityLookupTable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant REVEAL_WINDOW = 5 days;

    bytes32 public constant COMMIT_TYPEHASH =
        keccak256("Commit(uint256 gameId,bytes32 commit)");

    bytes32 public DOMAIN_SEPARATOR;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    struct Game {
        address player1;
        address player2;

        address stakeToken;
        uint256 stakeAmount;

        bytes32 player1Commit;
        bytes32 player2Commit;

        bool player1Revealed;
        bool player2Revealed;

        uint256 createdAt;
        uint256 joinTimestamp;
        uint256 revealDeadline;

        bool settled;
    }

    Game[] public games;

    mapping(address => bool) public allowedERC20;
    mapping(uint256 => address) public backendWinner; // winner resolved off-chain

    address public teamWallet;
    uint256 public platformFee; // basis points

    function gamesLength() external view returns (uint256) {
        return games.length;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event GameCreated(uint256 indexed gameId, address indexed player1);
    event GameJoined(uint256 indexed gameId, address indexed player2);

    event CommitSubmitted(uint256 indexed gameId, address indexed player);
    event Revealed(uint256 indexed gameId, address indexed player);

    event WinnerPosted(uint256 indexed gameId, address winner);
    event GameSettled(uint256 indexed gameId, address winner);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("CoreClash")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN CONFIG
    //////////////////////////////////////////////////////////////*/

    function _checkOwnership(
        address sender,
        address[3] calldata nftContracts,
        uint256[3] calldata nftIds
    ) internal view {
        for (uint256 i = 0; i < 3; i++) {
            require(
                IERC721(nftContracts[i]).ownerOf(nftIds[i]) == sender,
                "Not NFT owner"
            );
        }
    }

    function setAllowedERC20(address token, bool allowed) external onlyOwner {
        allowedERC20[token] = allowed;
    }

    function setPlatformFee(uint256 feeBps) external onlyOwner {
        require(feeBps <= 1000, "Fee too high");
        platformFee = feeBps;
    }

    function setTeamWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "Zero address");
        teamWallet = wallet;
    }

    function _computeCommit(
        uint256 salt,
        address[3] calldata nftContracts,
        uint256[3] calldata nftIds,
        string[3] calldata backgrounds
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                salt,
                nftContracts[0],
                nftContracts[1],
                nftContracts[2],
                nftIds[0],
                nftIds[1],
                nftIds[2],
                backgrounds[0],
                backgrounds[1],
                backgrounds[2]
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                           GAME CREATION
    //////////////////////////////////////////////////////////////*/

    function createGame(
        address stakeToken,
        uint256 stakeAmount,
        bytes32 commit
    ) external {
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
                player1Commit: commit,
                player2Commit: bytes32(0),
                player1Revealed: false,
                player2Revealed: false,
                createdAt: block.timestamp,
                joinTimestamp: 0,
                revealDeadline: 0,
                settled: false
            })
        );

        emit GameCreated(games.length - 1, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                           GAME JOIN
    //////////////////////////////////////////////////////////////*/

    function joinGame(
        uint256 gameId,
        bytes32 commit
    ) external {
        Game storage g = games[gameId];

        require(g.player2 == address(0), "Already joined");

        IERC20(g.stakeToken).safeTransferFrom(
            msg.sender,
            address(this),
            g.stakeAmount
        );

        g.player2 = msg.sender;
        g.player2Commit = commit;

        g.joinTimestamp = block.timestamp;
        g.revealDeadline = block.timestamp + REVEAL_WINDOW;

        emit GameJoined(gameId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                         COMMIT (EIP-712)
    //////////////////////////////////////////////////////////////*/

    function submitCommit(
        uint256 gameId,
        bytes32 commit,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        Game storage g = games[gameId];

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(COMMIT_TYPEHASH, gameId, commit))
            )
        );

        address signer = ecrecover(digest, v, r, s);
        require(signer == msg.sender, "Bad signature");

        if (msg.sender == g.player1) {
            g.player1Commit = commit;
        } else if (msg.sender == g.player2) {
            g.player2Commit = commit;
        } else {
            revert("Not player");
        }

        emit CommitSubmitted(gameId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                             REVEAL
    //////////////////////////////////////////////////////////////*/

function reveal(
    uint256 gameId,
    uint256 salt,
    address[3] calldata nftContracts,
    uint256[3] calldata nftIds,
    string[3] calldata backgrounds
) external {
    Game storage g = games[gameId];
    require(!g.settled, "Settled");

    _validateRarity(backgrounds);
    _checkOwnership(msg.sender, nftContracts, nftIds);

    bytes32 computed = _computeCommit(
        salt,
        nftContracts,
        nftIds,
        backgrounds
    );
    
        if (msg.sender == g.player1) {
        require(!g.player1Revealed, "Already");
        require(computed == g.player1Commit, "Bad reveal");
        g.player1Revealed = true;
    } else if (msg.sender == g.player2) {
        require(!g.player2Revealed, "Already");
        require(computed == g.player2Commit, "Bad reveal");
        g.player2Revealed = true;
    } else {
        revert("Not player");
    }

    emit Revealed(gameId, msg.sender);
}

    /*//////////////////////////////////////////////////////////////
                       BACKEND POSTS WINNER
    //////////////////////////////////////////////////////////////*/

    function postWinner(uint256 gameId, address winner) external onlyOwner {
        Game storage g = games[gameId];
        require(!g.settled, "Settled");
        require(
            winner == g.player1 ||
                winner == g.player2 ||
                winner == address(0),
            "Invalid"
        );

        backendWinner[gameId] = winner;
        emit WinnerPosted(gameId, winner);
    }

    /*//////////////////////////////////////////////////////////////
                             SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function settleGame(uint256 gameId) external {
        Game storage g = games[gameId];
        require(!g.settled, "Settled");

        // Timeout handling
        if (block.timestamp > g.revealDeadline) {
            if (g.player1Revealed && !g.player2Revealed) {
                _payout(gameId, g.player1);
                return;
            }
            if (g.player2Revealed && !g.player1Revealed) {
                _payout(gameId, g.player2);
                return;
            }
            if (!g.player1Revealed && !g.player2Revealed) {
                _refund(gameId);
                return;
            }
        }

        require(
            g.player1Revealed && g.player2Revealed,
            "Reveal pending"
        );

        _payout(gameId, backendWinner[gameId]);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL PAYOUTS
    //////////////////////////////////////////////////////////////*/

    function _payout(uint256 gameId, address winner) internal {
        Game storage g = games[gameId];
        g.settled = true;

        uint256 pot = g.stakeAmount * 2;
        uint256 fee = (pot * platformFee) / 10_000;
        uint256 payout = pot - fee;

        if (fee > 0) {
            IERC20(g.stakeToken).safeTransfer(teamWallet, fee);
        }

        if (winner != address(0)) {
            IERC20(g.stakeToken).safeTransfer(winner, payout);
        } else {
            // tie
            IERC20(g.stakeToken).safeTransfer(g.player1, payout / 2);
            IERC20(g.stakeToken).safeTransfer(g.player2, payout - payout / 2);
        }

        emit GameSettled(gameId, winner);
    }

    function _refund(uint256 gameId) internal {
        Game storage g = games[gameId];
        g.settled = true;

        IERC20(g.stakeToken).safeTransfer(g.player1, g.stakeAmount);
        IERC20(g.stakeToken).safeTransfer(g.player2, g.stakeAmount);

        emit GameSettled(gameId, address(0));
    }
}
