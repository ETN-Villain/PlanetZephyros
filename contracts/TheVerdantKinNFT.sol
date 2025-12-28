// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// ElectroSwap mint interface
interface IMintable {
    function mintPrice() external view returns (uint256);
    function mintableCount(address account) external view returns (uint256);
    function mint(uint256 mintCount) external payable;
}

interface IWETN {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IFeeReflection {
    function processIncomingTokens() external;
}

contract VerdantKinTest is ERC721Enumerable, Ownable, IMintable, ReentrancyGuard {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 474;
    uint256 public mintPriceVar = 100000000000000000; // 0.1 ETN / $4 (18 decimals, assuming Wei-like unit)
    string public tokenBaseURI; // ipfs://QmZMPmh6qg31NqH5tFKoQ5k3uMDBNMxkQUS7tyqCZstUNv

    address public constant PROJECT_WALLET = 0x3Fd2e5B4AC0efF6DFDF2446abddAB3f66B425099;

    // Mapping from tokenId to metadata index (1 to 1010)
    mapping(uint256 => uint256) private tokenToMetadataIndex;
    // Tracks available metadata indices
    uint256[] private availableMetadataIndices;
    uint256 private availableMetadataCount;
    bool public paused;

    uint256 public currentTokenId = 0; // Start at 0, increment to 1 for first mint

    event Mint(address indexed minter, uint256 count, uint256 value);
    event MintingToggled(bool paused);

    constructor(string memory name, string memory symbol, string memory baseURI)
        ERC721(name, symbol)
        Ownable(msg.sender)
    {
        tokenBaseURI = baseURI;

        // Initialize available metadata indices (1 to 1010)
        availableMetadataIndices = new uint256[](MAX_SUPPLY);
        for (uint256 i = 0; i < MAX_SUPPLY; i++) {
            availableMetadataIndices[i] = i + 1; // Indices 1 to 1010
        }
        availableMetadataCount = MAX_SUPPLY;
    }

    function mintableCount(address) external view override returns (uint256) {
        if (paused) {
            return 0; // Return 0 when paused
        }
        return availableMetadataCount;
    }

    function mintPrice() external view override returns (uint256) {
        return mintPriceVar;
    }

    function toggleMinting() external onlyOwner {
        paused = !paused;
        emit MintingToggled(paused);
    }

    function mint(uint256 mintCount) external payable override nonReentrant {
        require(!paused, "Minting is paused");
        require(mintCount > 0, "Mint count must be > 0");
        require(availableMetadataCount >= mintCount, "Exceeds available NFTs");
        require(currentTokenId + mintCount <= MAX_SUPPLY, "Exceeds max supply");
        require(msg.value >= mintCount * mintPriceVar, "Insufficient payment");

        for (uint256 i = 0; i < mintCount; i++) {
            // Mint new token
            uint256 tokenId = ++currentTokenId; // Increment to start at 1
            _safeMint(msg.sender, tokenId);

            // Assign random metadata index
            uint256 randomIndex = _getRandomMetadataIndex();
            tokenToMetadataIndex[tokenId] = availableMetadataIndices[randomIndex];
            // Remove used index by swapping with the last one
            availableMetadataIndices[randomIndex] = availableMetadataIndices[availableMetadataCount - 1];
            availableMetadataIndices.pop();
            availableMetadataCount--;
        }

        (bool successProject, ) = PROJECT_WALLET.call{value: address(this).balance}("");
        require(successProject, "Transfer to project wallet failed");

        emit Mint(msg.sender, mintCount, msg.value);
    }

    function _getRandomMetadataIndex() internal view returns (uint256) {
        require(availableMetadataCount > 0, "No metadata indices available");
        uint256 random = uint256(
            keccak256(abi.encodePacked(block.timestamp, blockhash(block.number - 1), msg.sender, availableMetadataCount))
        );
        return random % availableMetadataCount;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(tokenId >= 1 && tokenId <= MAX_SUPPLY, "ERC721Metadata: URI query for nonexistent token");
        require(tokenToMetadataIndex[tokenId] != 0, "Metadata not assigned");
        return string(abi.encodePacked(tokenBaseURI, "/", tokenToMetadataIndex[tokenId].toString(), ".json"));
    }

    function setTokenBaseURI(string memory newBaseURI) external onlyOwner {
        tokenBaseURI = newBaseURI;
    }

    // Required for compatibility, though unused
    function onERC721Received(
        address, address, uint256, bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}