// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal test double for IMarketplaceLite — a directly-settable domainActivated mapping,
/// rather than reusing the real marketplace mock's full registration/activation flow, which
/// PremiumSubscription never touches (it only ever reads domainActivated()).
contract MockMarketplaceLite {
    mapping(bytes32 => bool) public domainActivated;

    function setActivated(bytes32 node, bool activated) external {
        domainActivated[node] = activated;
    }
}
