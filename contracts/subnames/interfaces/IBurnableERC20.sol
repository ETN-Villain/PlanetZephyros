// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev CORE token must expose a public burn(uint256) that burns the caller's own balance,
/// matching PlanetZephyrosV1.sol / TestCore.sol in this repo.
interface IBurnableERC20 is IERC20 {
    function burn(uint256 amount) external;
}
