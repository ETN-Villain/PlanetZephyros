// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

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

contract VerdantKin is ERC721Enumerable, ERC2981, Ownable, ReentrancyGuard, IMintable {

    uint256 public constant MAX_SUPPLY = 474;
    uint256 public constant PRICE = 1000000000000000000000; // 1,000 ETN, ETN uses 18 decimals like ether
    address public constant WETN = 0x138DAFbDA0CCB3d8E39C19edb0510Fc31b7C1c77;
    // baseURI = ipfs://bafybeiegzlv2v4v2xtrklhdfeklbxcsaw3qp5ptqevvds27qguioausj7a/
    // feeReceiver = 0x90f2d252d56AE6655cDD2e466a0b95daE97b911D
    // owner = 0x3Fd2e5B4AC0efF6DFDF2446abddAB3f66B425099

    bool public isMintable;
    address public feeReceiver;
    string private _baseTokenURI;
    uint96 public royaltyBps = 1000; // Track royalty basis points for easy updates

    // Mapping from tokenId to metadata index (1 to 474)
    mapping(uint256 => uint256) private tokenToMetadataIndex;
    // Tracks available metadata indices
    uint256[] private availableMetadataIndices;
    uint256 private availableMetadataCount;
    bool public paused;

    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);

    constructor(
        string memory baseURI_,
        address feeReceiver_,
        address owner_
    ) ERC721("Verdant Kin", "VKIN") Ownable(owner_) {
        require(bytes(baseURI_).length > 0, "BaseURI required");
        require(feeReceiver_ != address(0), "Bad fee receiver");

        _baseTokenURI = baseURI_;
        feeReceiver = feeReceiver_;

        _setDefaultRoyalty(feeReceiver_, royaltyBps);

        isMintable = false;

        // Initialize available metadata indices (1 to 474)
        availableMetadataIndices = new uint256[](MAX_SUPPLY);
        for (uint256 i = 0; i < MAX_SUPPLY; i++) {
            availableMetadataIndices[i] = i + 1;
        }
        availableMetadataCount = MAX_SUPPLY;

        _safeMint(owner_, 1);
        uint256 randomIndex1 = _getRandomMetadataIndex();
        tokenToMetadataIndex[1] = availableMetadataIndices[randomIndex1];
        availableMetadataIndices[randomIndex1] = availableMetadataIndices[availableMetadataCount - 1];
        availableMetadataIndices.pop();
        availableMetadataCount--;

        _safeMint(owner_, 2);
        uint256 randomIndex2 = _getRandomMetadataIndex();
        tokenToMetadataIndex[2] = availableMetadataIndices[randomIndex2];
        availableMetadataIndices[randomIndex2] = availableMetadataIndices[availableMetadataCount - 1];
        availableMetadataIndices.pop();
        availableMetadataCount--;
    }

    // ===== Admin =====
    function setBaseURI(string memory uri) external onlyOwner {
        require(bytes(uri).length > 0, "Empty URI");
        _baseTokenURI = uri;
        
        if (totalSupply() > 0) {
            emit BatchMetadataUpdate(1, totalSupply());
        }
    }

    function setMintable(bool _isMintable) external onlyOwner {
        isMintable = _isMintable;
    }

    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        require(receiver != address(0), "Bad royalty receiver");
        feeReceiver = receiver;
        royaltyBps = bps;
        _setDefaultRoyalty(receiver, bps);
    }

    // New function: Update feeReceiver while keeping current royalty bps
    function setFeeReceiver(address newReceiver) external onlyOwner {
        require(newReceiver != address(0), "Invalid receiver address");
        feeReceiver = newReceiver;
        _setDefaultRoyalty(newReceiver, royaltyBps);
    }

    /// @notice Withdraw ETN from the contract
    function withdraw(address to) external onlyOwner {
        require(to != address(0), "Invalid address");
        (bool sent, ) = to.call{value: address(this).balance}("");
        require(sent, "Withdraw failed");
    }

    // ===== IMintable required methods =====
    function mintPrice() external pure override returns (uint256) {
        return PRICE;
    }

    function mintableCount(address) external view override returns (uint256) {
        uint256 remaining = MAX_SUPPLY - totalSupply();
        return remaining;
    }

    // Mint (buy+burn enabled)
    function mint(uint256 mintCount) external payable override nonReentrant {
        require(isMintable, "Sale not active");
        require(mintCount > 0, "Quantity zero");
        require(totalSupply() + mintCount <= MAX_SUPPLY, "Exceeds supply");
        uint256 totalPrice = PRICE * mintCount;
        require(msg.value >= totalPrice, "Insufficient payment");
        
        // Refund excess ETH if overpaid
        if (msg.value > totalPrice) {
            payable(msg.sender).transfer(msg.value - totalPrice);
        }
        
        for (uint256 i = 0; i < mintCount; i++) {
            uint256 tokenId = totalSupply() + 1;
            _safeMint(msg.sender, tokenId);
            uint256 randomIndex = _getRandomMetadataIndex();
            tokenToMetadataIndex[tokenId] = availableMetadataIndices[randomIndex];
            availableMetadataIndices[randomIndex] = availableMetadataIndices[availableMetadataCount - 1];
            availableMetadataIndices.pop();
            availableMetadataCount--;
        }

        // 💰 Buy + burn logic (enabled)
        uint256 amount = totalPrice;
        IWETN(WETN).deposit{value: amount}();
        require(IWETN(WETN).transfer(feeReceiver, amount), "Transfer failed");

        try IFeeReflection(feeReceiver).processIncomingTokens() {
            // success
        } catch {
            // ignore (e.g., if reflection contract reverts for any reason)
        }
    }

    function _getRandomMetadataIndex() internal view returns (uint256) {
        require(availableMetadataCount > 0, "No metadata indices available");
        uint256 random = uint256(
            keccak256(abi.encodePacked(block.timestamp, blockhash(block.number - 1), msg.sender, availableMetadataCount))
        );
        return random % availableMetadataCount;
    }

    // ===== Metadata =====
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(tokenId >= 1 && tokenId <= MAX_SUPPLY, "ERC721Metadata: URI query for nonexistent token");
        require(tokenToMetadataIndex[tokenId] != 0, "Metadata not assigned");
        return string(abi.encodePacked(_baseTokenURI, "/", Strings.toString(tokenToMetadataIndex[tokenId]), ".json"));
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Enumerable, ERC2981) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }
}