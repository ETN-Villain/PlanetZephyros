// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICoreToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ICoreAscensionV2 {
    function fundRewards(uint256 amount, uint256 durationBlocks) external;
}

contract CoreDripFunderV2 {
    address public owner;
    ICoreToken public coreToken;
    ICoreAscensionV2 public stakingContract;

    uint256 public constant DRIP_AMOUNT = 500 ether;     // 500 CORE
    uint256 public constant DRIP_INTERVAL = 7 days;

    uint256 public lastDripTime;
    uint256 public totalDripped;
    uint256 public totalToDrip;

    uint256 public endTimestamp;   // 27 Sep 2027

    event Dripped(uint256 amount, uint256 remainingToDrip, uint256 dripCount);
    event EmergencyWithdraw(address token, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        address _coreToken,
        address _stakingContract,
        uint256 _totalToDrip,
        uint256 _endTimestamp
    ) {
        owner = msg.sender;
        coreToken = ICoreToken(_coreToken);
        stakingContract = ICoreAscensionV2(_stakingContract);
        totalToDrip = _totalToDrip;
        endTimestamp = _endTimestamp;
        lastDripTime = block.timestamp;
    }

    function deposit(uint256 amount) external onlyOwner {
        require(coreToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
    }

function drip() external {
    require(block.timestamp >= lastDripTime + DRIP_INTERVAL, "Too soon");
    require(totalDripped < totalToDrip, "All dripped");

    uint256 amount = DRIP_AMOUNT;
    if (totalDripped + amount > totalToDrip) {
        amount = totalToDrip - totalDripped;
    }

    uint256 remainingSeconds = endTimestamp > block.timestamp ? endTimestamp - block.timestamp : 0;
    uint256 durationBlocks = remainingSeconds / 5;

    // Only approve + let staking contract handle the transfer (prevents double transfer)
    coreToken.approve(address(stakingContract), amount);
    stakingContract.fundRewards(amount, durationBlocks);

    lastDripTime = block.timestamp;
    totalDripped += amount;

    emit Dripped(amount, totalToDrip - totalDripped, totalDripped / DRIP_AMOUNT);
}

    function nextDripIn() external view returns (uint256) {
        if (block.timestamp >= lastDripTime + DRIP_INTERVAL) return 0;
        return lastDripTime + DRIP_INTERVAL - block.timestamp;
    }

    function remainingDrips() external view returns (uint256) {
        return (totalToDrip - totalDripped) / DRIP_AMOUNT;
    }

    // Emergency recovery
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 bal = ICoreToken(token).balanceOf(address(this));
        require(bal > 0, "Nothing to withdraw");
        ICoreToken(token).transfer(owner, bal);
        emit EmergencyWithdraw(token, bal);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }
}