// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Trimmed to the one function PremiumSubscription needs from the marketplace: whether a
/// domain has been activated — used by the free-premium-access-for-activated-domain-owners check
/// (see PremiumSubscription.isActivatedDomainOwner). domainActivated is keyed by node, not by
/// wallet, which is why that check also needs INameWrapperLite.ownerOf to confirm the caller
/// actually owns the node they're claiming.
interface IMarketplaceLite {
    function domainActivated(bytes32 node) external view returns (bool);
}
