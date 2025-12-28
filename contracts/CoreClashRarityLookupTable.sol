// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title CoreClashRarityLookupTable
 * @notice Admin-configurable rarity restriction table
 *
 * Restricted rarities may appear at most once per team.
 * Unrestricted rarities may be duplicated.
 */
abstract contract CoreClashRarityLookupTable {
    // =============================================================
    //                           ERRORS
    // =============================================================

    error NotOwner();
    error EmptyRarity();
    error LengthMismatch();

    // =============================================================
    //                           EVENTS
    // =============================================================

    event RarityRestrictionSet(string rarity, bool restricted);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // =============================================================
    //                           STORAGE
    // =============================================================

    /// keccak256(rarity string) => restricted?
    mapping(bytes32 => bool) internal restrictedRarity;

    address public owner;

    // =============================================================
    //                         MODIFIERS
    // =============================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // =============================================================
    //                       INITIALIZATION
    // =============================================================

    constructor() {
        owner = msg.sender;
        _initDefaultRarities();
    }

    function _initDefaultRarities() internal {
        _setRestrictedInternal("Gold", true);
        _setRestrictedInternal("Silver", true);
        _setRestrictedInternal("Verdant Green", true);
        _setRestrictedInternal("Rose Gold", true);
        // Forest of Globes intentionally NOT restricted
    }

    // =============================================================
    //                    INTERNAL SETTER (FIX)
    // =============================================================

    function _setRestrictedInternal(
        string memory rarity,
        bool restricted
    ) internal {
        bytes32 hash = keccak256(bytes(rarity));
        restrictedRarity[hash] = restricted;
        emit RarityRestrictionSet(rarity, restricted);
    }

    // =============================================================
    //                      ADMIN FUNCTIONS
    // =============================================================

    function setRestrictedRarity(
        string calldata rarity,
        bool restricted
    ) external onlyOwner {
        if (bytes(rarity).length == 0) revert EmptyRarity();
        _setRestrictedInternal(rarity, restricted);
    }

    function setRestrictedRarities(
        string[] calldata rarities,
        bool[] calldata restricted
    ) external onlyOwner {
        if (rarities.length != restricted.length) revert LengthMismatch();

        for (uint256 i = 0; i < rarities.length; i++) {
            if (bytes(rarities[i]).length == 0) revert EmptyRarity();
            _setRestrictedInternal(rarities[i], restricted[i]);
        }
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // =============================================================
    //                      PUBLIC READ HELPERS
    // =============================================================

    function isRestrictedRarity(
        string memory rarity
    ) public view returns (bool) {
        return restrictedRarity[keccak256(bytes(rarity))];
    }

    // =============================================================
    //                        VALIDATION
    // =============================================================

    /**
     * @dev Validates that restricted rarities appear at most once
     * Expects exactly 3 backgrounds
     */
function _validateRarity(
    string[3] calldata bgs
) internal view {
    bytes32[3] memory hashes;

    for (uint256 i = 0; i < 3; i++) {
        hashes[i] = keccak256(bytes(bgs[i]));
    }

    for (uint256 i = 0; i < 3; i++) {
        if (!restrictedRarity[hashes[i]]) continue;

        uint256 count;
        for (uint256 j = 0; j < 3; j++) {
            if (hashes[j] == hashes[i]) count++;
        }

        require(count <= 1, "Rarity dup");
    }
}
}