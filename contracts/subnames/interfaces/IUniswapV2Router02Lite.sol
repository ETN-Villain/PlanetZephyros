// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Trimmed Uniswap V2 router interface, same shape used elsewhere in this repo
/// (see TestCore.sol / ErevosFeeReflection.sol) for buy-and-burn swaps.
interface IUniswapV2Router02Lite {
    function WETH() external pure returns (address);

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
}
