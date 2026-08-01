// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @dev Stand-in for the real CORE token (PlanetZephyrosV1.sol / TestCore.sol): a plain
/// burnable ERC20 with an open mint for test setup.
contract MockCoreToken is ERC20, ERC20Burnable {
    constructor() ERC20("Mock Core", "MCORE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
