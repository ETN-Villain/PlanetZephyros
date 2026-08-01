// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.4.0/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.4.0/contracts/token/common/ERC2981.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.4.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.4.0/contracts/utils/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.4.0/contracts/utils/Strings.sol";

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

contract AetherScions is ERC721Enumerable, ERC2981, Ownable, IMintable, ReentrancyGuard {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 198;
    uint256 public PRICE; // 545555000000000000; 5,455.55 ETN (18 decimals, assuming Wei-like unit)
    address public constant WETN = 0x138DAFbDA0CCB3d8E39C19edb0510Fc31b7C1c77;
    string public tokenBaseURI; // ipfs://bafybeigialscusgbck22lxgnoaycgcabmsc7tgrzo32lx2yp4n3wb75leu/

    bool public isMintable;
    address public feeReceiver;
    string private _baseTokenURI;
    uint96 public royaltyBps = 1000; // Track royalty basis points for easy updates

    address public constant PROJECT_WALLET = 0x3Fd2e5B4AC0efF6DFDF2446abddAB3f66B425099;

    // Mapping from tokenId to metadata index (1 to 1010)
    mapping(uint256 => uint256) private tokenToMetadataIndex;
    // Tracks available metadata indices
    uint256[] private availableMetadataIndices;
    uint256 private availableMetadataCount;
    bool public paused;

    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);
    event MintingToggled(bool paused);


    constructor(
        string memory baseURI_,
        address feeReceiver_,
        address owner_
    ) ERC721("Aether Scions", "SCIONS") Ownable(owner_) {
        require(bytes(baseURI_).length > 0, "BaseURI required");
        require(feeReceiver_ != address(0), "Bad fee receiver");

        _baseTokenURI = baseURI_;
        feeReceiver = feeReceiver_;

        _setDefaultRoyalty(feeReceiver_, royaltyBps);

        isMintable = false;

        // Initialize available metadata indices (1 to 1010)
        availableMetadataIndices = new uint256[](MAX_SUPPLY);
        for (uint256 i = 0; i < MAX_SUPPLY; i++) {
            availableMetadataIndices[i] = i + 1; // Indices 1 to 1010
        }
        availableMetadataCount = MAX_SUPPLY;
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
function setPrice(uint256 _price) external onlyOwner {
    PRICE = _price;
}
function mintPrice() external view override returns (uint256) {
    return PRICE;
}


    function mintableCount(address) external view override returns (uint256) {
        uint256 remaining = MAX_SUPPLY - totalSupply();
        return remaining;
    }

    function toggleMinting() external onlyOwner {
        paused = !paused;
        emit MintingToggled(paused);
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
