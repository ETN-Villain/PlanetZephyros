// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @dev Trimmed to the functions this marketplace calls on BaseRegistrarImplementation, as
/// deployed on Electroneum testnet at
/// NEXT_PUBLIC_ETN_TESTNET_DEPLOYMENT_ADDRESSES.BaseRegistrarImplementation. IERC721 gives
/// approve/ownerOf/transferFrom; nameExpires is BaseRegistrarImplementation's own addition.
interface IBaseRegistrarLite is IERC721 {
    function nameExpires(uint256 id) external view returns (uint256);
}
