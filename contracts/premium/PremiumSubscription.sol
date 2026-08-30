// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
/**
 * Premium Subscription
 *
 * Premium Feature #1 for the Electroneum dashboard (dashboard.planetzephyros.xyz — see
 * ETNSubdomainService repo). Pure payment/pricing/membership-gate/execution layer: this contract
 * does NOT track the PnL statement request lifecycle (PAID/PENDING_GENERATION/GENERATED/
 * FINALIZED) — that state machine lives in the dashboard backend's own database, driven by the
 * events this contract emits. This contract only ever escrows funds and, once told to by the
 * trusted operator, executes the buy-and-burn split or a refund.
 *
 *  1) Premium membership: subscribe() sells time-boxed membership at an owner-adjustable monthly
 *     price. Membership currently unlocks nothing on its own — it exists so future premium
 *     features can gate on isMembershipActive() — but it already does one thing today: an active
 *     member gets every PnL statement period for free (see purchasePnlPeriods).
 *
 *  2) PnL statement periods: purchasePnlPeriods() is open to any caller, not gated on membership.
 *     Non-members pay pnlPricePerPeriod per 12-month period (supports buying several periods for
 *     a wallet in one transaction); active members pay nothing. Funds stay escrowed in this
 *     contract until the dashboard backend's operator wallet later calls executeSplitForPeriod
 *     (on FINALIZED) or refundPnlPeriod (on a pre-finalize refund) — this contract trusts the
 *     operator to pass the right amount, since it doesn't itself track per-request bookkeeping.
 *
 *  3) Buy-and-burn: executeSplitForPeriod copies, unmodified, the proven swap-and-burn pattern
 *     already live in this repo's PlanetZephyrosSubdomainNameServiceV3.buyBackAndBurn() — half of
 *     whatever's released goes straight to splitDestination, the other half is swapped ETN->CORE
 *     via a Uniswap-V2-style router and burned via CORE's own burn().
 *
 * Website: https://planetzephyros.xyz/
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../subnames/interfaces/IUniswapV2Router02Lite.sol";
import "../subnames/interfaces/IBurnableERC20.sol";

contract PremiumSubscription is Ownable, ReentrancyGuard {
    // ========================
    // Roles
    // ========================
    /// @notice The dashboard backend's trusted wallet. Can only move already-escrowed PnL-period
    /// funds through the two narrow, logged paths below (executeSplitForPeriod/refundPnlPeriod) —
    /// cannot touch pricing, wiring addresses, or the pause switch. Deliberately a role separate
    /// from owner (unlike PlanetZephyrosSubdomainNameServiceV3's single-owner model) so a leaked
    /// backend key is contained to those two paths.
    address public operator;

    // ========================
    // Pricing
    // ========================
    uint256 public constant SECONDS_PER_MONTH = 30 days;

    /// @notice Owner-adjustable ETN price per 30-day membership period. Starts at 5,000 ETN/mo.
    uint256 public membershipPricePerMonth = 5_000 ether;

    /// @notice Owner-adjustable ETN price per 12-month PnL statement period, charged only to
    /// callers without an active membership. Starts at 10,000 ETN/period.
    uint256 public pnlPricePerPeriod = 10_000 ether;

    /// @notice Membership expiry (unix timestamp) per address. 0 / in the past = no active
    /// membership.
    mapping(address => uint256) public membershipExpiry;

    // ========================
    // Buy-and-burn wiring
    // ========================
    address public coreToken;
    address public swapRouter;

    /// @notice Receives the non-burn half of every executed split. Set to the same wallet as
    /// operator per this feature's confirmed design (no separate treasury address).
    address payable public splitDestination;

    uint256 public totalCoreBurned;

    bool public paused;

    // ========================
    // Events
    // ========================
    event MembershipPurchased(address indexed subscriber, uint256 numMonths, uint256 paid, uint256 newExpiry);
    event PnlPeriodsPurchased(address indexed payer, address indexed trackedWallet, uint256 numPeriods, uint256 amountPaid);
    event MembershipPricePerMonthUpdated(uint256 membershipPricePerMonth);
    event PnlPricePerPeriodUpdated(uint256 pnlPricePerPeriod);
    event CoreTokenUpdated(address coreToken);
    event SwapRouterUpdated(address swapRouter);
    event SplitDestinationUpdated(address splitDestination);
    event OperatorUpdated(address operator);
    event PausedUpdated(bool paused);
    event PnlPeriodSplitExecuted(address indexed operator, uint256 amountSplit, address splitWallet, uint256 coreReceived, uint256 coreBurned);
    event PnlPeriodRefunded(address indexed operator, address indexed to, uint256 amount);

    // ========================
    // Modifiers
    // ========================
    modifier whenNotPaused() {
        require(!paused, "Premium subscription paused");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    constructor(address _owner, address _operator, address payable _splitDestination) Ownable(_owner) {
        require(_operator != address(0), "Zero operator");
        require(_splitDestination != address(0), "Zero split destination");
        operator = _operator;
        splitDestination = _splitDestination;
    }

    // ========================================================
    // Membership
    // ========================================================

    /// @notice Extends msg.sender's membership by numMonths 30-day periods, from whichever is
    /// later of their current expiry or now (so buying more time before expiry doesn't waste the
    /// remainder). Excess msg.value beyond the exact price is refunded, same convention as
    /// PlanetZephyrosSubdomainNameServiceV3's registerName/activateDomain.
    function subscribe(uint256 numMonths) external payable whenNotPaused nonReentrant {
        require(numMonths >= 1, "numMonths must be >= 1");

        uint256 required = membershipPricePerMonth * numMonths;
        require(msg.value >= required, "Insufficient payment");

        uint256 base = membershipExpiry[msg.sender] > block.timestamp ? membershipExpiry[msg.sender] : block.timestamp;
        uint256 newExpiry = base + (numMonths * SECONDS_PER_MONTH);
        membershipExpiry[msg.sender] = newExpiry;

        uint256 refund = msg.value - required;
        if (refund > 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            require(ok, "Refund failed");
        }

        emit MembershipPurchased(msg.sender, numMonths, required, newExpiry);
    }

    function isMembershipActive(address who) public view returns (bool) {
        return membershipExpiry[who] > block.timestamp;
    }

    // ========================================================
    // PnL statement periods
    // ========================================================

    /// @notice Purchases numPeriods 12-month PnL statement periods for trackedWallet. Open to any
    /// caller — NOT gated on membership. An active member (isMembershipActive(msg.sender)) pays
    /// nothing; everyone else pays pnlPricePerPeriod * numPeriods. Funds (when non-zero) stay
    /// escrowed in this contract; nothing is split here — the dashboard backend's watcher reads
    /// this event to create statement requests, and later calls executeSplitForPeriod once its
    /// own state machine reaches FINALIZED (see contract header). A free member purchase still
    /// emits this event with amountPaid = 0 so the request pipeline is identical either way.
    function purchasePnlPeriods(address trackedWallet, uint256 numPeriods) external payable whenNotPaused nonReentrant {
        require(trackedWallet != address(0), "Zero tracked wallet");
        require(numPeriods >= 1, "numPeriods must be >= 1");

        uint256 required = isMembershipActive(msg.sender) ? 0 : pnlPricePerPeriod * numPeriods;
        require(msg.value >= required, "Insufficient payment");

        uint256 refund = msg.value - required;
        if (refund > 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            require(ok, "Refund failed");
        }

        emit PnlPeriodsPurchased(msg.sender, trackedWallet, numPeriods, required);
    }

    // ========================================================
    // Operator-triggered execution (backend-driven, off-chain state machine)
    // ========================================================

    /// @notice Releases `amount` of this contract's escrowed balance: half to splitDestination,
    /// half swapped ETN->CORE and burned. Copies PlanetZephyrosSubdomainNameServiceV3's
    /// buyBackAndBurn() swap logic unmodified. The operator (dashboard backend) calls this exactly
    /// once per statement request, when its own database transitions that request to FINALIZED —
    /// this contract has no visibility into that state machine and trusts the operator's `amount`.
    function executeSplitForPeriod(uint256 amount, uint256 minCoreOut, uint256 deadline) external onlyOperator whenNotPaused nonReentrant {
        require(coreToken != address(0) && swapRouter != address(0), "Buyback not configured");
        require(amount > 0, "Nothing to split");
        require(address(this).balance >= amount, "Insufficient balance");

        uint256 toSplitWallet = amount / 2;
        uint256 toSwap = amount - toSplitWallet;

        if (toSplitWallet > 0) {
            (bool ok, ) = splitDestination.call{value: toSplitWallet}("");
            require(ok, "Split transfer failed");
        }

        address[] memory path = new address[](2);
        path[0] = IUniswapV2Router02Lite(swapRouter).WETH();
        path[1] = coreToken;

        uint256 balanceBefore = IERC20(coreToken).balanceOf(address(this));

        IUniswapV2Router02Lite(swapRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: toSwap}(
            minCoreOut,
            path,
            address(this),
            deadline
        );

        uint256 received = IERC20(coreToken).balanceOf(address(this)) - balanceBefore;
        require(received > 0, "Swap failed");

        IBurnableERC20(coreToken).burn(received);
        totalCoreBurned += received;

        emit PnlPeriodSplitExecuted(msg.sender, amount, splitDestination, received, received);
    }

    /// @notice Refunds `amount` of this contract's escrowed balance to `to`. The operator calls
    /// this when the backend's state machine allows a refund (before either finalize trigger) —
    /// same trust boundary as executeSplitForPeriod.
    function refundPnlPeriod(address payable to, uint256 amount) external onlyOperator whenNotPaused nonReentrant {
        require(to != address(0), "Zero refund destination");
        require(amount > 0, "Nothing to refund");
        require(address(this).balance >= amount, "Insufficient balance");

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "Refund transfer failed");

        emit PnlPeriodRefunded(msg.sender, to, amount);
    }

    // ========================================================
    // Admin
    // ========================================================

    function setMembershipPricePerMonth(uint256 _membershipPricePerMonth) external onlyOwner {
        membershipPricePerMonth = _membershipPricePerMonth;
        emit MembershipPricePerMonthUpdated(_membershipPricePerMonth);
    }

    function setPnlPricePerPeriod(uint256 _pnlPricePerPeriod) external onlyOwner {
        pnlPricePerPeriod = _pnlPricePerPeriod;
        emit PnlPricePerPeriodUpdated(_pnlPricePerPeriod);
    }

    function setCoreToken(address _coreToken) external onlyOwner {
        coreToken = _coreToken;
        emit CoreTokenUpdated(_coreToken);
    }

    function setSwapRouter(address _swapRouter) external onlyOwner {
        swapRouter = _swapRouter;
        emit SwapRouterUpdated(_swapRouter);
    }

    function setSplitDestination(address payable _splitDestination) external onlyOwner {
        require(_splitDestination != address(0), "Zero split destination");
        splitDestination = _splitDestination;
        emit SplitDestinationUpdated(_splitDestination);
    }

    function setOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "Zero operator");
        operator = _operator;
        emit OperatorUpdated(_operator);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedUpdated(_paused);
    }
}
