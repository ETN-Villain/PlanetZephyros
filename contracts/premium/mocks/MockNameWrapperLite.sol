// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal test double for the ownerOf() slice of INameWrapperLite that
/// PremiumSubscription.isActivatedDomainOwner actually calls — a directly-settable owner mapping,
/// rather than reusing the real NameWrapper mock's full ERC1155 wrap flow (see
/// MockMarketplaceLite.sol's own comment for the same reasoning).
contract MockNameWrapperLite {
    mapping(uint256 => address) private _owners;

    function setOwner(uint256 id, address owner) external {
        _owners[id] = owner;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _owners[id];
    }
}
