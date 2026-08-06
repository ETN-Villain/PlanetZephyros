// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.4.0/contracts/utils/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.4.0/contracts/access/Ownable.sol";

contract AetherScionsFeeReflectionV3 is ReentrancyGuard, Ownable {

    // ========================
    // 🔸 Immutable Addresses
    // ========================
    address payable public immutable coreWallet; // 0x3Fd2e5B4AC0efF6DFDF2446abddAB3f66B425099 
    address public immutable coreToken;          // 0x309B916b3A90cb3E071697Ea9680e9217A30066f 
    address public immutable WETN;               // 0x138DAFbDA0CCB3d8E39C19edb0510Fc31b7C1c77 
    address public immutable BURN_ADDRESS = address(0); // Add: For true supply reduction
    address public immutable erevosNFT;         // 0x120E438b5A79E447F78C7857c8E55C3674349f05

    UniswapV2Router internal v2Router; // 0x072D4706f9A383D5608BD14B09b41683cb95fFd7

    // ========================
    // 🔸 Whitelist for NFT Contracts
    // ========================
    mapping(address => bool) public whitelistedNFTs;

    // ========================
    // 🔸 Balances
    // ========================
    uint256 public coreBalance;
    uint256 public nftBalance;

    bool public autoBuyAndBurnCore; // Add: Flag for auto-burning core

    // ========================
    // 🔸 Events
    // ========================
    event CoreBuyAndBurn(uint256 coreBurned); // Add: Event for core burn
    event FeeProcessed(uint256 amountIn, uint256 coreShare, uint256 nftShare);
    event TokensRescued(address token, uint256 amount, address to);
    event ETHRescued(uint256 amount, address to);
    event NFTWhitelisted(address nftContract);
    event NFTUnwhitelisted(address nftContract);

    // ========================
    // 🔸 Constructor
    // ========================
    constructor(
        address v2RouterAddr, // Add: V2 router param
        address _coreToken, // Add: Core token param
        address _wetn, 
        address _owner,
        address payable _coreWallet,
        address _erevosNFT
    ) Ownable(_owner) {
        v2Router = UniswapV2Router(v2RouterAddr); // Add: Set V2 router
        coreToken = _coreToken; // Add: Set core token
        WETN = _wetn;
        coreWallet = _coreWallet;
        autoBuyAndBurnCore = true; // Add: Default to true
        erevosNFT = _erevosNFT;
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
    function withdrawCore() external onlyOwner nonReentrant {
        _processIncomingFee(0);

        uint256 totalToWithdraw = coreBalance;
        if (totalToWithdraw > 0) {
            IWETN(WETN).withdraw(totalToWithdraw);
        }

        if (coreBalance > 0) {
            (bool s1, ) = coreWallet.call{value: coreBalance}("");
            require(s1, "Core wallet transfer failed");
            coreBalance = 0;
        }
    }

    // ========================
    // 🔸 Settings
    // ========================
    function setAutoBuyAndBurnCore(bool _autoBuyAndBurnCore) external onlyOwner nonReentrant { // Add: Setter for core auto-burn
        autoBuyAndBurnCore = _autoBuyAndBurnCore;
    }

    // ========================
    // 🔸 Manual Triggers
    // ========================
    function processIncomingTokens() external onlyOwnerOrWhitelistedNFT {
        _processIncomingFee(0);
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
        uint256 expected = coreBalance + nftBalance;
        require(currentWetn >= expected, "Balance error");
        
        uint256 incoming = currentWetn - expected;

        if(incoming > 0){
            uint256 corePortion = (incoming * 50) / 100;
            uint256 nftPortion = incoming - corePortion;

            coreBalance += corePortion;
            nftBalance += nftPortion;

            emit FeeProcessed(incoming, corePortion, nftPortion);

            _distributeToNFTs();
            
            if(autoBuyAndBurnCore){ // Add: Trigger core auto-burn
                _buyAndBurnCore();
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

function _distributeToNFTs() internal {
    if (nftBalance == 0) return;

    uint256 sharePerNFT = nftBalance / 9;

    for (uint256 i = 1; i <= 9; i++) {
        try IERC721(erevosNFT).ownerOf(i) returns (address owner) {
            if (owner != address(0)) {
                IWETN(WETN).transfer(owner, sharePerNFT);
            }
        } catch {
            // skip if token doesn't exist
        }
    }

    nftBalance = 0;
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
            uint256 protectedAmount = coreBalance + nftBalance;
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
    function transfer(address to, uint256 amount) external returns (bool); // ADD THIS
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
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