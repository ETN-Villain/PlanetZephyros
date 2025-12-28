// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/**
 * Planet Zephyros (CORE) ERC-20 token contract
 * 
 * Website: https://planetzephyros.xyz/
 * X: https://x.com/PlanetZephyros
 * Telegram: https://t.me/PlanetZephyros
 */

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract PlanetZephyros {
    string public name = "TestCore";
    string public symbol = "TCORE";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    uint256 public constant initialSupply = 1_000_000 * 10**18;

    address public taxWallet = 0x4Eb4b9Ce208711A0EA1BefF57C83BD66BC563378;
    address public immutable routerAddress = 0x5410F10a5E214AF03EA601Ca8C76b665A786BCe1; // 0x072D4706f9A383D5608BD14B09b41683cb95fFd7; // Mainnet router
    uint256 public immutable burnRatio = 80;
    address public owner;
    address public pairAddress;

    uint256 private constant BPS_DENOM = 10000;
    bool public tradingEnabled;
    bool public taxesPaused;
    mapping(address => bool) public isExemptFromTax;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TaxWalletUpdated(address indexed previousTaxWallet, address indexed newTaxWallet);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TaxExemptionUpdated(address indexed account, bool isExempt);
    event TaxesPaused(bool paused);
    

    constructor() {
        owner = msg.sender;
        totalSupply = initialSupply;
        _balances[msg.sender] = initialSupply;
        isExemptFromTax[address(this)] = true;

        emit Transfer(address(0), msg.sender, initialSupply);
        emit TaxExemptionUpdated(address(this), true);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyTaxWallet() {
        require(msg.sender == taxWallet, "Not tax wallet");
        _;
    }

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
        
        // Auto-renounce on launch
        owner = address(0);
        emit OwnershipTransferred(owner, address(0));
    }

    function setUniswapPair(address _pair) external onlyOwner {
        require(pairAddress == address(0), "Pair already set");
        pairAddress = _pair;
    }

    function setTaxExemption(address account, bool isExempt) external onlyOwner {
        require(account != address(0), "Zero address");
        isExemptFromTax[account] = isExempt;
        emit TaxExemptionUpdated(account, isExempt);
    }

    function transferTaxWallet(address _newTaxWallet) external onlyTaxWallet {
        _balances[_newTaxWallet] = _balances[taxWallet];
        _balances[taxWallet] = 0;
        taxWallet = _newTaxWallet;
        emit TaxWalletUpdated(taxWallet, _newTaxWallet);
    }
    
    function toggleTaxesPaused() external onlyTaxWallet {
        taxesPaused = !taxesPaused;
        emit TaxesPaused(taxesPaused);
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner_, address spender) public view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public returns (bool) {
        require(_allowances[sender][msg.sender] >= amount, "Insufficient allowance");
        _approve(sender, msg.sender, _allowances[sender][msg.sender] - amount);
        _transfer(sender, recipient, amount);
        return true;
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        require(owner_ != address(0) && spender != address(0), "Zero address");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "Sender zero address");
        require(_balances[sender] >= amount, "Insufficient balance");

        if (recipient == address(0)) {
            _balances[sender] -= amount;
            totalSupply -= amount;
            emit Transfer(sender, address(0), amount);
            return;
        }

        if (!tradingEnabled && sender != owner && recipient != owner) {
            revert("Trading not enabled");
        }

        uint256 taxBps = (sender == pairAddress) ? currentBuyBps() : currentSellBps();

        if (taxBps == 0 || isExemptFromTax[sender] || isExemptFromTax[recipient] || (sender != pairAddress && recipient != pairAddress)) {
            _balances[sender] -= amount;
            _balances[recipient] += amount;
            emit Transfer(sender, recipient, amount);
            return;
        }
        
        uint256 taxAmount = (amount * taxBps) / BPS_DENOM;
        uint256 transferAmount = amount - taxAmount;

        uint256 burnAmount = (taxAmount * burnRatio) / 100;
        uint256 taxWalletAmount = taxAmount - burnAmount;

        _balances[sender] -= amount;
        if (taxWalletAmount > 0) {
            _balances[taxWallet] += taxWalletAmount;
            emit Transfer(sender, taxWallet, taxWalletAmount);
        }
        if (burnAmount > 0) {
            totalSupply -= burnAmount;
            emit Transfer(sender, address(0), burnAmount);
        }
        _balances[recipient] += transferAmount;
        emit Transfer(sender, recipient, transferAmount);
    }

    function currentBuyBps() public view returns (uint256) {
        if (taxesPaused) return 0;
        uint256 supplyPercent = (totalSupply * 100) / initialSupply;
        if (supplyPercent <= 75) return 0;
        uint256 reductionSteps = ((100 - supplyPercent) * 10) / 25;
        uint256 tax = 500 - (reductionSteps * 50);
        return tax > 0 ? tax : 0;
    }

    function currentSellBps() public view returns (uint256) {
        if (taxesPaused) return 0;
        uint256 supplyPercent = (totalSupply * 100) / initialSupply;
        if (supplyPercent <= 50) return 200;
        uint256 reductionSteps = ((100 - supplyPercent) * 10) / 25;
        uint256 tax = 1000 - (reductionSteps * 40);
        return tax > 200 ? tax : 200;
    }

    function sellWithTax(uint256 amount, uint256 minOut, address to) external {
        require(tradingEnabled, "trading not enabled");

        _transfer(msg.sender, address(this), amount);

        uint256 taxBps = currentSellBps();
        uint256 taxAmount = (amount * taxBps) / BPS_DENOM;
        uint256 sellAmount = amount - taxAmount;

        uint256 burnAmount = (taxAmount * burnRatio) / 100;
        uint256 taxWalletAmount = taxAmount - burnAmount;

        if (taxWalletAmount > 0) {
            _transfer(address(this), taxWallet, taxWalletAmount);
        }
        if (burnAmount > 0) {
            totalSupply -= burnAmount;
            _balances[address(this)] -= burnAmount;
            emit Transfer(address(this), address(0), burnAmount);
        }

        _approve(address(this), routerAddress, sellAmount);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = IUniswapV2Router02(routerAddress).WETH();

        IUniswapV2Router02(routerAddress).swapExactTokensForETHSupportingFeeOnTransferTokens(
            sellAmount, minOut, path, to, block.timestamp
        );
    }

    function burn(uint256 amount) external {
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }
}