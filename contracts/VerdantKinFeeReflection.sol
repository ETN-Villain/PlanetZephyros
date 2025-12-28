// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract VerdantKinFeeReflection is ReentrancyGuard, Ownable {

    // ========================
    // 🔸 Immutable Addresses
    // ========================
    address payable public immutable coreWallet; // 0x3Fd2e5B4AC0efF6DFDF2446abddAB3f66B425099 
    address payable public immutable teamWallet; // 0x4Eb4b9Ce208711A0EA1BefF57C83BD66BC563378 
    address public immutable club;               // 0x94e8718354557079aD0eD6fD7000EBbE84Fa9E4E 
    address public immutable coreToken;          // 0x1DeCBFcE31cA0633504a22Fd1D95D783b94d1128 
    address public immutable WETN;               // 0x138DAFbDA0CCB3d8E39C19edb0510Fc31b7C1c77 
    address public immutable DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD; 
    address public immutable BURN_ADDRESS = address(0); // Add: For true supply reduction
    uint24 private immutable poolFee = 3000;     // For V3 club swap

    V3Router internal v3Router; // 0x5A3AB7e9f405250B36e7e0a4654c1052EADC1F07
    UniswapV2Router internal v2Router; // 0x5410F10a5E214AF03EA601Ca8C76b665A786BCe1

    // ========================
    // 🔸 Whitelist for NFT Contracts
    // ========================
    mapping(address => bool) public whitelistedNFTs;

    // ========================
    // 🔸 Balances
    // ========================
    uint256 public clubBalance;
    uint256 public coreBalance;
    uint256 public teamBalance;

    bool public autoBuyAndBurn;
    bool public autoBuyAndBurnCore; // Add: Flag for auto-burning core

    // ========================
    // 🔸 Events
    // ========================
    event ClubBuyAndBurn(uint256 clubBurned);
    event CoreBuyAndBurn(uint256 coreBurned); // Add: Event for core burn
    event FeeProcessed(uint256 amountIn, uint256 coreShare, uint256 teamShare, uint256 clubShare);
    event TokensRescued(address token, uint256 amount, address to);
    event ETHRescued(uint256 amount, address to);
    event NFTWhitelisted(address nftContract);
    event NFTUnwhitelisted(address nftContract);

    // ========================
    // 🔸 Constructor
    // ========================
    constructor(
        address v3RouterAddr, 
        address v2RouterAddr, // Add: V2 router param
        address _club, 
        address _coreToken, // Add: Core token param
        address _wetn, 
        address _owner,
        address payable _coreWallet,
        address payable _teamWallet
    ) Ownable(_owner) {
        v3Router = V3Router(v3RouterAddr);
        v2Router = UniswapV2Router(v2RouterAddr); // Add: Set V2 router
        club = _club;
        coreToken = _coreToken; // Add: Set core token
        WETN = _wetn;
        coreWallet = _coreWallet;
        teamWallet = _teamWallet;
        autoBuyAndBurn = true;
        autoBuyAndBurnCore = true; // Add: Default to true
    }

    // ========================
    // 🔸 Whitelist Management
    // ========================
    modifier onlyOwnerOrWhitelistedNFT() {
        require(
            msg.sender == owner() || whitelistedNFTs[msg.sender],
            "Unauthorized: Only owner or whitelisted NFT"
        );
        _;
    }

    function addWhitelistedNFT(address nftContract) external onlyOwner {
        require(nftContract != address(0), "Invalid NFT contract address");
        require(!whitelistedNFTs[nftContract], "Already whitelisted");
        whitelistedNFTs[nftContract] = true;
        emit NFTWhitelisted(nftContract);
    }

    function removeWhitelistedNFT(address nftContract) external onlyOwner {
        require(whitelistedNFTs[nftContract], "Not whitelisted");
        whitelistedNFTs[nftContract] = false;
        emit NFTUnwhitelisted(nftContract);
    }

    function isWhitelistedNFT(address nftContract) external view returns (bool) {
        return whitelistedNFTs[nftContract];
    }

    // ========================
    // 🔸 Withdraw
    // ========================
    function teamWithdraw() external onlyOwner nonReentrant {
        _processIncomingFee(0);

        uint256 totalToWithdraw = coreBalance + teamBalance;
        if (totalToWithdraw > 0) {
            IWETN(WETN).withdraw(totalToWithdraw);
        }

        if (coreBalance > 0) {
            (bool s1, ) = coreWallet.call{value: coreBalance}("");
            require(s1, "Core wallet transfer failed");
            coreBalance = 0;
        }

        if (teamBalance > 0) {
            (bool s2, ) = teamWallet.call{value: teamBalance}("");
            require(s2, "Team wallet transfer failed");
            teamBalance = 0;
        }
    }

    // ========================
    // 🔸 Settings
    // ========================
    function setAutoBuyAndBurn(bool _autoBuyAndBurn) external onlyOwner nonReentrant {
        autoBuyAndBurn = _autoBuyAndBurn;
    }

    function setAutoBuyAndBurnCore(bool _autoBuyAndBurnCore) external onlyOwner nonReentrant { // Add: Setter for core auto-burn
        autoBuyAndBurnCore = _autoBuyAndBurnCore;
    }

    // ========================
    // 🔸 Manual Triggers
    // ========================
    function processIncomingTokens() external onlyOwnerOrWhitelistedNFT {
        _processIncomingFee(0);
    }

    function manualBuyAndBurn() external onlyOwner nonReentrant { // Updated: Now handles both club and core
        require(clubBalance > 0 || coreBalance > 0, "No balances to burn");
        _buyAndBurn();
        _buyAndBurnCore(); // Add: Also burn core manually
    }

    function manualBuyAndBurnCore() external onlyOwner nonReentrant { // Add: Separate manual for core only
        require(coreBalance > 0, "No core balance to burn");
        _buyAndBurnCore();
    }

    // ========================
    // 🔸 Core Processing
    // ========================
    function _processIncomingFee(uint256 amount) internal {
        if(amount > 0){
            IWETN(WETN).deposit{value: amount}();
        }
                
        uint256 currentWetn = IWETN(WETN).balanceOf(address(this));
        uint256 expected = coreBalance + teamBalance + clubBalance;
        require(currentWetn >= expected, "Balance error");
        
        uint256 incoming = currentWetn - expected;

        if(incoming > 0){
            uint256 corePortion = (incoming * 60) / 100;
            uint256 clubPortion = (incoming * 10) / 100;
            uint256 teamPortion = incoming - corePortion - clubPortion;

            coreBalance += corePortion;
            teamBalance += teamPortion;
            clubBalance += clubPortion;

            emit FeeProcessed(incoming, corePortion, teamPortion, clubPortion);
            
            if(autoBuyAndBurn){
                _buyAndBurn();
            }
            if(autoBuyAndBurnCore){ // Add: Trigger core auto-burn
                _buyAndBurnCore();
            }
        }
    }

    function _buyAndBurn() internal {
        if (clubBalance > 0) {
            IWETN(WETN).approve(address(v3Router), clubBalance); 

            V3Router.ExactInputParams memory clubParams = V3Router.ExactInputParams({
                path: abi.encodePacked(WETN, poolFee, club),
                recipient: DEAD_ADDRESS,
                amountIn: clubBalance,
                amountOutMinimum: 0
            });
            uint clubBurned = v3Router.exactInput(clubParams);
            clubBalance = 0;

            if (clubBurned > 0) {
                emit ClubBuyAndBurn(clubBurned);
            }
        }
    }

    function _buyAndBurnCore() internal { // Add: New function for core V2 burn
        if (coreBalance > 0) {
            address[] memory path = new address[](2);
            path[0] = WETN;
            path[1] = coreToken;

            uint[] memory amounts = v2Router.getAmountsOut(coreBalance, path);
            uint expectedOut = amounts[1];
            uint amountOutMin = (expectedOut * 80) / 100; // 20% slippage tolerance

            IWETN(WETN).approve(address(v2Router), coreBalance); 

            uint[] memory amountsOut = v2Router.swapExactTokensForTokens(
                coreBalance,
                amountOutMin,
                path,
                BURN_ADDRESS, // Send to address(0) for true supply burn
                block.timestamp + 300 // Deadline: 5 min
            );
            uint coreBurned = amountsOut[amountsOut.length - 1]; // Last amount is CORE received
            coreBalance = 0;

            if (coreBurned > 0) {
                emit CoreBuyAndBurn(coreBurned);
            }
        }
    }

    // ========================
    // 🔸 Rescue Functions
    // ========================

    /// @notice Rescue any ETH accidentally sent to the contract
    function rescueETH(uint256 amount, address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "Invalid recipient");
        uint256 contractETH = address(this).balance;
        require(amount <= contractETH, "Not enough ETH");
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
        emit ETHRescued(amount, to);
    }

    /// @notice Rescue any ERC20 tokens (including WETN if not part of tracked balances)
    function rescueTokens(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        require(to != address(0), "Invalid recipient");
        IERC20 erc20 = IERC20(token);
        uint256 balance = erc20.balanceOf(address(this));
        require(amount <= balance, "Not enough token balance");

        // 🚨 Protect against accidentally rescuing tracked WETN
        if (token == WETN) {
            uint256 protectedAmount = coreBalance + teamBalance + clubBalance;
            require(balance > protectedAmount, "No excess WETN to rescue");
            require(amount <= balance - protectedAmount, "Amount exceeds excess WETN");
        }

        bool sent = erc20.transfer(to, amount);
        require(sent, "Token transfer failed");
        emit TokensRescued(token, amount, to);
    }

    // ========================
    // 🔸 Receive / Fallback
    // ========================
    receive() external payable {
        if(msg.sender != address(WETN)){
            _processIncomingFee(msg.value);
        }
    }

    fallback() external payable {
        if(msg.sender != address(WETN)){
            _processIncomingFee(msg.value);
        }
    }
}

// ========================
// 🔸 Interfaces
// ========================
interface IWETN {
    function withdraw(uint256) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function deposit() external payable;
    function balanceOf(address addr) external view returns (uint256);
}

interface V3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface UniswapV2Router { // Add: V2 Router interface
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}