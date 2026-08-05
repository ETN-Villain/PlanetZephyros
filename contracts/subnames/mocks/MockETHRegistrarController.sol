// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IETHRegistrarController.sol";
import "../interfaces/IPriceOracle.sol";
import "./MockBaseRegistrar.sol";

/// @dev Minimal stand-in for ENS ETHRegistrarController: fixed price-per-second, real
/// commit-reveal timing, and the same "register directly to registration.owner" behaviour the
/// marketplace relies on (since it always passes resolver = address(0)).
contract MockETHRegistrarController is IETHRegistrarController {
    MockBaseRegistrar public immutable base;
    uint256 public immutable pricePerSecond;
    uint256 public constant MIN_COMMITMENT_AGE = 60;
    uint256 public constant MAX_COMMITMENT_AGE = 1 days;

    mapping(bytes32 => uint256) public commitments;

    error InsufficientValue();
    error NameNotAvailable(string label);
    error CommitmentNotFound(bytes32 commitment);
    error CommitmentTooNew(bytes32 commitment, uint256 minAge, uint256 nowTs);
    error CommitmentTooOld(bytes32 commitment, uint256 maxAge, uint256 nowTs);

    constructor(MockBaseRegistrar _base, uint256 _pricePerSecond) {
        base = _base;
        pricePerSecond = _pricePerSecond;
    }

    function rentPrice(
        string memory /* label */,
        uint256 duration
    ) public view override returns (IPriceOracle.Price memory price) {
        price = IPriceOracle.Price({base: duration * pricePerSecond, premium: 0});
    }

    function available(string memory label) public view override returns (bool) {
        uint256 id = uint256(keccak256(bytes(label)));
        return base.available(id);
    }

    function makeCommitment(Registration memory registration) public pure override returns (bytes32) {
        return keccak256(abi.encode(registration));
    }

    function commit(bytes32 commitment) external override {
        commitments[commitment] = block.timestamp;
    }

    function register(Registration memory registration) external payable override {
        bytes32 labelhash = keccak256(bytes(registration.label));
        IPriceOracle.Price memory price = rentPrice(registration.label, registration.duration);
        uint256 totalPrice = price.base + price.premium;
        if (msg.value < totalPrice) revert InsufficientValue();
        if (!available(registration.label)) revert NameNotAvailable(registration.label);

        bytes32 commitment = makeCommitment(registration);
        uint256 commitmentTimestamp = commitments[commitment];

        if (commitmentTimestamp == 0) revert CommitmentNotFound(commitment);
        if (commitmentTimestamp + MIN_COMMITMENT_AGE > block.timestamp)
            revert CommitmentTooNew(commitment, commitmentTimestamp + MIN_COMMITMENT_AGE, block.timestamp);
        if (commitmentTimestamp + MAX_COMMITMENT_AGE <= block.timestamp)
            revert CommitmentTooOld(commitment, commitmentTimestamp + MAX_COMMITMENT_AGE, block.timestamp);

        delete commitments[commitment];

        base.register(uint256(labelhash), registration.owner, registration.duration);

        if (msg.value > totalPrice) {
            payable(msg.sender).transfer(msg.value - totalPrice);
        }
    }

    function renew(string calldata label, uint256 duration, bytes32 /* referrer */) external payable override {
        IPriceOracle.Price memory price = rentPrice(label, duration);
        if (msg.value < price.base) revert InsufficientValue();

        bytes32 labelhash = keccak256(bytes(label));
        base.renew(uint256(labelhash), duration);

        if (msg.value > price.base) {
            payable(msg.sender).transfer(msg.value - price.base);
        }
    }
}
