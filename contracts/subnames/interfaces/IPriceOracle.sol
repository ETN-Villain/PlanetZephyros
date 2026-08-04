// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Matches ens-contracts (ensdomains) IPriceOracle, as deployed on Electroneum.
interface IPriceOracle {
    struct Price {
        uint256 base;
        uint256 premium;
    }
}
