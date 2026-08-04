// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "./MockBaseRegistrar.sol";

/// @dev Minimal stand-in for ENS NameWrapper: wraps a MockBaseRegistrar-owned ETH2LD into an
/// ERC1155 token, and supports creating child (sub)names the same way the real contract does,
/// gated by canModifyName. Each wrapped node is single-supply (amount == 1), so ERC1155 balance
/// ownership and the owner/fuses/expiry record are kept in sync via _update.
contract MockNameWrapper is ERC1155 {
    struct Data {
        address owner;
        uint32 fuses;
        uint64 expiry;
    }

    // Same constant used by the real ETHRegistrarController/NameWrapper as the .eth root node;
    // reused here purely as a fixed root so wrapETH2LD produces a realistic full-namehash token
    // id (keccak256(ROOT_NODE, labelhash)) instead of a bare labelhash, matching how the real
    // NameWrapper's _wrapETH2LD/_makeNode derives its ERC1155 id.
    bytes32 public constant ROOT_NODE = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;

    MockBaseRegistrar public immutable base;
    mapping(uint256 => Data) private _data;
    mapping(uint256 => bytes) private _names;

    constructor(MockBaseRegistrar _base) ERC1155("") {
        base = _base;
    }

    function wrapETH2LD(
        string calldata label,
        address wrappedOwner,
        uint16 ownerControlledFuses,
        address /* resolver */
    ) external returns (uint64 expiry) {
        uint256 registrarId = uint256(keccak256(bytes(label)));
        address registrant = base.ownerOf(registrarId);
        require(registrant == msg.sender, "Not registrant");

        base.transferFrom(registrant, address(this), registrarId);

        expiry = uint64(base.nameExpires(registrarId));

        uint256 tokenId = uint256(keccak256(abi.encodePacked(ROOT_NODE, bytes32(registrarId))));
        _mint(wrappedOwner, tokenId, 1, "");
        _data[tokenId] = Data({owner: wrappedOwner, fuses: ownerControlledFuses, expiry: expiry});
        _names[tokenId] = abi.encodePacked(uint8(bytes(label).length), label, bytes1(0));
    }

    function setSubnodeRecord(
        bytes32 parentNode,
        string calldata label,
        address owner,
        address /* resolver */,
        uint64 /* ttl */,
        uint32 fuses,
        uint64 expiry
    ) external returns (bytes32 node) {
        require(canModifyName(parentNode, msg.sender), "Unauthorised");

        bytes32 labelhash = keccak256(bytes(label));
        node = keccak256(abi.encodePacked(parentNode, labelhash));
        uint256 tokenId = uint256(node);

        address previousOwner = _data[tokenId].owner;
        if (previousOwner != address(0)) {
            _burn(previousOwner, tokenId, 1);
        }
        _mint(owner, tokenId, 1, "");
        _data[tokenId] = Data({owner: owner, fuses: fuses, expiry: expiry});
        _names[tokenId] = abi.encodePacked(uint8(bytes(label).length), label, bytes1(0));
    }

    function names(bytes32 node) external view returns (bytes memory) {
        return _names[uint256(node)];
    }

    function ownerOf(uint256 id) public view returns (address) {
        return _data[id].owner;
    }

    function getData(uint256 id) external view returns (address owner, uint32 fuses, uint64 expiry) {
        Data memory d = _data[id];
        return (d.owner, d.fuses, d.expiry);
    }

    function canModifyName(bytes32 node, address addr) public view returns (bool) {
        address nodeOwner = _data[uint256(node)].owner;
        return nodeOwner != address(0) && (nodeOwner == addr || isApprovedForAll(nodeOwner, addr));
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        super._update(from, to, ids, values);
        for (uint256 i = 0; i < ids.length; i++) {
            if (to != address(0)) {
                _data[ids[i]].owner = to;
            }
        }
    }
}
