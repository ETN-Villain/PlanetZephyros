// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Minimal stand-in for ENS BaseRegistrarImplementation, for unit-testing the marketplace
/// against realistic register/approve/ownerOf/nameExpires behaviour without a live testnet.
contract MockBaseRegistrar is ERC721, Ownable {
    address public controller;
    mapping(uint256 => uint256) public nameExpires;

    constructor() ERC721("Mock Base Registrar", "MOCKBASE") Ownable(msg.sender) {}

    modifier onlyController() {
        require(msg.sender == controller, "Not controller");
        _;
    }

    function setController(address _controller) external onlyOwner {
        controller = _controller;
    }

    function register(uint256 id, address owner, uint256 duration) external onlyController returns (uint256) {
        _mint(owner, id);
        nameExpires[id] = block.timestamp + duration;
        return nameExpires[id];
    }

    function available(uint256 id) external view returns (bool) {
        return nameExpires[id] < block.timestamp;
    }
}
