// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @dev Trimmed to the functions this marketplace calls on NameWrapper, as deployed on
/// Electroneum testnet at NEXT_PUBLIC_ETN_TESTNET_DEPLOYMENT_ADDRESSES.NameWrapper. Matches
/// ens-contracts (ensdomains) INameWrapper signatures exactly so ABI encoding lines up with the
/// deployed contract; IERC1155 gives safeTransferFrom / setApprovalForAll / isApprovedForAll.
interface INameWrapperLite is IERC1155 {
    function wrapETH2LD(
        string calldata label,
        address wrappedOwner,
        uint16 ownerControlledFuses,
        address resolver
    ) external returns (uint64 expires);

    function setSubnodeRecord(
        bytes32 node,
        string calldata label,
        address owner,
        address resolver,
        uint64 ttl,
        uint32 fuses,
        uint64 expiry
    ) external returns (bytes32);

    function ownerOf(uint256 id) external view returns (address owner);

    function getData(uint256 id) external view returns (address owner, uint32 fuses, uint64 expiry);

    function canModifyName(bytes32 node, address addr) external view returns (bool);

    /// @dev DNS wire-format encoded name for `node` (e.g. "\x05alice\x03etn\x00"). Used to
    /// verify a caller-supplied label against a caller-supplied node without this contract ever
    /// needing to know or assume the chain's actual TLD/root node.
    function names(bytes32 node) external view returns (bytes memory);
}
