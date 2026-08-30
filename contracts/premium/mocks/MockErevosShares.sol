// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev Stand-in for the real ErevosShares (mainnet-only, 9/9 minted, no testnet deployment —
/// confirmed live via Blockscout) for testing PremiumSubscription's free-access-for-holders check.
/// Open mint for test setup, unlike the real 9-max-supply contract.
contract MockErevosShares is ERC721 {
    uint256 private _nextTokenId = 1;

    constructor() ERC721("Mock Erevos Shares", "MEREVOS") {}

    function mint(address to) external returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _mint(to, tokenId);
    }
}
