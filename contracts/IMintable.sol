// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMintable {
    // Returns the price of a single mint in ETN
    function mintPrice() external view returns (uint256);
    // Returns the number of tokens that can be minted overall or by an account
    function mintableCount(address account) external view returns (uint256);
    // Mints the specified number of tokens
    function mint(uint256 mintCount) external payable;
}