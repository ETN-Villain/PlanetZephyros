// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./MockCoreToken.sol";

/// @dev Stand-in DEX router for buy-and-burn tests: mints CORE to the recipient at a fixed
/// rate, honouring amountOutMin so slippage-protection tests can exercise a revert path.
contract MockRouter {
    MockCoreToken public immutable coreToken;
    address public immutable weth;
    uint256 public immutable rate; // CORE (wei) minted per 1 wei of ETN sent

    constructor(MockCoreToken _coreToken, address _weth, uint256 _rate) {
        coreToken = _coreToken;
        weth = _weth;
        rate = _rate;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable {
        require(block.timestamp <= deadline, "Expired");
        require(path[path.length - 1] == address(coreToken), "Bad path");

        uint256 amountOut = msg.value * rate;
        require(amountOut >= amountOutMin, "Insufficient output amount");

        coreToken.mint(to, amountOut);
    }
}
