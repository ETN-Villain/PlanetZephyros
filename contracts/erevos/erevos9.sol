// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IMintable.sol";

/**
  ███████╗██████╗ ███████╗██╗   ██╗ ██████╗ ███████╗
  ██╔════╝██╔══██╗██╔════╝██║   ██║██╔═══██╗██╔════╝
  █████╗  ██████╔╝█████╗  ██║   ██║██║   ██║███████╗
  ██╔══╝  ██╔══██╗██╔══╝  ╚██╗ ██╔╝██║   ██║╚════██║
  ███████╗██║  ██║███████╗ ╚████╔╝ ╚██████╔╝███████║
  ╚══════╝╚═╝  ╚═╝╚══════╝  ╚═══╝   ╚═════╝ ╚══════╝

           ███████╗██╗  ██╗ █████╗ ██████╗ ███████╗███████╗
           ██╔════╝██║  ██║██╔══██╗██╔══██╗██╔════╝██╔════╝
           ███████╗███████║███████║██████╔╝█████╗  ███████╗
           ╚════██║██╔══██║██╔══██║██╔══██╗██╔══╝  ╚════██║
           ███████║██║  ██║██║  ██║██║  ██║███████╗███████║
           ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝ 

 * In the Aether Scions saga, the nine Erevos NFTs stand as primordial guardians — 
 * each bearing equal dominion over the revenue streams of the 198 Aether Scions collection. 
 * Their holders inherit 1/9th of all primary mint proceeds and secondary royalties (10%), 
 * channeled through the reflection mechanism: 50% to Erevos wallets, 40% to CORE buy & burns, 10% to Club Watch Holders. 
 * Only 9 will ever exist. Claim your share of the silent world's legacy.
 * Wallet minting limits have been removed.
 * @dev An NFT contract compatible with the ElectroSwap minting platform.
 */
contract ErevosShares is ERC721Enumerable, Ownable, IMintable {
    // --- State Variables ---

    string public tokenBaseURI; // ipfs://bafybeigialscusgbck22lxgnoaycgcabmsc7tgrzo32lx2yp4n3wb75leu/

    uint256 public immutable maxSupply;
    uint256 internal _mintPrice;
    bool public isMintable;

    uint256 private _nextTokenId;

    // --- Events ---

    event MintPriceChanged(uint256 newPrice);
    event MintableStatusChanged(bool isMintable);

    // --- Constructor ---

constructor(
    uint256 _initialMintPrice,
    uint256 _maxSupply,
    address initialOwner,
    string memory baseURI

) ERC721("Erevos Shares", "EREVOS") Ownable(initialOwner) {
    require(_maxSupply > 0, "Max supply must be greater than 0");

    _mintPrice = _initialMintPrice;
    maxSupply = _maxSupply;
    _nextTokenId = 1;
    tokenBaseURI = baseURI;
}

    // --- Public Minting Function ---

    function mint(uint256 quantity) public payable override {
        require(isMintable, "Minting is not active");
        require(quantity > 0, "Quantity must be greater than 0");
        require(totalSupply() + quantity <= maxSupply, "Exceeds max supply");
        require(msg.value >= _mintPrice * quantity, "Incorrect ETN amount sent");

        for (uint256 i = 0; i < quantity; i++) {
            _safeMint(msg.sender, _nextTokenId);
            _nextTokenId++;
        }
    }

    // --- Owner-Only Functions ---

    function safeMint(address to) public onlyOwner {
        require(totalSupply() < maxSupply, "Exceeds max supply");
        _safeMint(to, _nextTokenId);
        _nextTokenId++;
    }

    function setMintable(bool _isMintable) public onlyOwner {
        isMintable = _isMintable;
        emit MintableStatusChanged(_isMintable);
    }

    function setMintPrice(uint256 _newMintPrice) public onlyOwner {
        _mintPrice = _newMintPrice;
        emit MintPriceChanged(_newMintPrice);
    }

    function updateBaseURI(string memory newBaseURI) public onlyOwner {
        tokenBaseURI = newBaseURI;
    }

    function withdraw() public onlyOwner {
        (bool success, ) = payable(owner()).call{value: address(this).balance}("");
        require(success, "Withdrawal failed");
    }

    // --- View Functions (for ElectroSwap compatibility) ---

    function mintPrice() external view override returns (uint256) {
        return _mintPrice;
    }

    /**
     * @dev Returns the total remaining supply if minting is active, otherwise 0.
     * The 'account' parameter is unused but required by the IMintable interface.
     */
    function mintableCount(address /*account*/) public view override returns (uint256) {
        if (!isMintable) {
            return 0;
        }
        return remainingSupply();
    }

    function remainingSupply() public view returns (uint256) {
        return maxSupply - totalSupply();
    }

    /**
     * @dev A pre-flight check to see if a mint is possible.
     * The 'account' parameter is unused as there are no per-wallet limits.
     */
    function canMint(address /*account*/, uint256 quantity) public view returns (bool) {
        return
            isMintable &&
            quantity > 0 &&
            totalSupply() + quantity <= maxSupply;
    }

    // --- Internal Overrides ---

    function _baseURI() internal view override returns (string memory) {
        return tokenBaseURI;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}